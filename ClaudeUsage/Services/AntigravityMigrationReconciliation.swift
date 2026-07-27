import CryptoKit
import Foundation
import LocalAuthentication

nonisolated enum AntigravityMigrationFingerprint {
    static func refresh(
        _ credentials: AntigravityOAuthCredentials
    ) -> String? {
        guard let refresh = credentials.refreshToken,
              refresh.reconciliationTrimmedNonEmpty != nil
        else {
            return nil
        }
        return digest([refresh])
    }

    static func digest(_ components: [String]) -> String {
        let data = Data(components.joined(separator: "\n").utf8)
        return self.data(data)
    }

    static func data(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// Secret- and PII-free binding for an explicit canonical remove-all
    /// intent. Revision alone is not unique because a newly recreated
    /// repository starts its revision sequence again.
    static func removalCanonicalState(
        _ state: AntigravityAccountRepositoryState
    ) -> String {
        let accountBindings = state.accounts.map {
            [
                $0.id.rawValue,
                $0.credentialReference.rawValue,
                $0.lifecycle.rawValue,
            ].joined(separator: "|")
        }.sorted()
        return digest(
            [
                "antigravity-remove-all-v2",
                "schema:\(state.schemaVersion)",
                "revision:\(state.revision)",
                "active:\(state.activeAccountID?.rawValue ?? "-")",
            ] + accountBindings
        )
    }
}

/// Pure-ish legacy inventory and reconciliation boundary. It can read injected
/// source adapters, but it neither mutates the vault nor writes canonical
/// metadata, migration journals or completion markers.
nonisolated struct AntigravityMigrationReconciler: Sendable {
    nonisolated struct Inventory: Sendable {
        var outcomes:
            [AntigravityLegacySourceID: AntigravityLegacySourceOutcome]
        fileprivate var payloadFingerprints:
            [AntigravityLegacySourceID: String]
        fileprivate var candidates: [Candidate]
        fileprivate var metadata: LegacyMetadata?
        var authorizationWasCancelled: Bool
        fileprivate var externalIdentityConflictDetected: Bool

        var requiresInteraction: Bool {
            outcomes.values.contains(.interactionRequired)
        }

        var hasFileCredentialCandidate: Bool {
            candidates.contains {
                $0.source == .accountFile || $0.source == .activeCredentialFile
            }
        }

        var hasCandidates: Bool {
            !candidates.isEmpty
        }

        private var hasAuthoritativeAccountFile: Bool {
            let accounts = candidates.filter { $0.source == .accountFile }
            let activeCount = accounts.filter(\.isActiveSignal).count
            return outcomes[.accountFile] == .readable
                && !accounts.isEmpty
                && accounts.allSatisfy {
                    $0.credentials.refreshToken?.reconciliationTrimmedNonEmpty != nil
                }
                && (accounts.count == 1 || activeCount == 1)
        }

        private var hasSelfContainedActiveCredentialFile: Bool {
            guard outcomes[.activeCredentialFile] == .readable,
                  let credentials = candidates.first(where: {
                      $0.source == .activeCredentialFile
                  })?.credentials
            else {
                return false
            }
            return credentials.accessToken?.reconciliationTrimmedNonEmpty != nil
                && credentials.refreshToken?.reconciliationTrimmedNonEmpty != nil
                && credentials.email?.reconciliationTrimmedNonEmpty != nil
                && credentials.projectID?.reconciliationTrimmedNonEmpty != nil
                && credentials.clientID?.reconciliationTrimmedNonEmpty != nil
                && credentials.expiryDateMilliseconds.map {
                    $0.isFinite && $0 >= 0
                } == true
        }

        /// Recovery is source-specific. A valid account collection can replace
        /// every redundant mirror, while a self-contained active credential can
        /// replace only corrupt metadata because it carries those fields itself.
        fileprivate func canRecover(unreadable source: AntigravityLegacySourceID)
            -> Bool
        {
            if hasAuthoritativeAccountFile, source != .accountFile {
                return true
            }
            return source == .metadataFile
                && hasSelfContainedActiveCredentialFile
        }
    }

    nonisolated struct Prepared: Sendable {
        let repositoryPlan: AntigravityMigrationRepositoryPlan
        let credentialsByReference:
            [AntigravityCredentialReference: AntigravityOAuthCredentials]
        let sourceInventoryFingerprint: String
        let sourceFingerprints: [AntigravityLegacySourceID: String]
        let sourcePayloadFingerprints: [AntigravityLegacySourceID: String]
        let journalAccounts: [AntigravityMigrationJournalAccount]
    }

    private nonisolated struct LegacyTokenSecrets: Decodable, Sendable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case refreshTokenSnake = "refresh_token"
            case refreshTokenCamel = "refreshToken"
            case idTokenSnake = "id_token"
            case idTokenCamel = "idToken"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken =
                try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            refreshToken =
                try container.decodeIfPresent(String.self, forKey: .refreshTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .refreshTokenCamel)
            idToken =
                try container.decodeIfPresent(String.self, forKey: .idTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .idTokenCamel)
        }
    }

    fileprivate nonisolated struct LegacyMetadata: Decodable, Sendable {
        let expiryDateMilliseconds: Double?
        let email: String?
        let projectID: String?
        let clientID: String?

        enum CodingKeys: String, CodingKey {
            case expiryDateMilliseconds = "expiry_date"
            case email
            case projectID = "project_id"
            case clientID = "client_id"
        }
    }

    fileprivate nonisolated struct Candidate: Sendable {
        let source: AntigravityLegacySourceID
        let alias: String?
        let label: String?
        let credentials: AntigravityOAuthCredentials
        let createdAtMilliseconds: Double?
        let updatedAtMilliseconds: Double?
        let isActiveSignal: Bool
    }

    private nonisolated struct CandidateGroup {
        let fingerprint: String
        let candidates: [Candidate]
    }

    private let fileAccess: any AntigravityLegacyFileAccessing
    private let keychainAccess: any AntigravityLegacyKeychainAccessing
    private let uuidGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        fileAccess: any AntigravityLegacyFileAccessing,
        keychainAccess: any AntigravityLegacyKeychainAccessing,
        uuidGenerator: @escaping @Sendable () -> UUID,
        now: @escaping @Sendable () -> Date
    ) {
        self.fileAccess = fileAccess
        self.keychainAccess = keychainAccess
        self.uuidGenerator = uuidGenerator
        self.now = now
    }

    func inventory(
        authenticationContext: LAContext?
    ) -> Inventory {
        var result = Inventory(
            outcomes: Dictionary(
                uniqueKeysWithValues: AntigravityLegacySourceID.allCases.map {
                    ($0, .notFound)
                }
            ),
            payloadFingerprints: [:],
            candidates: [],
            metadata: nil,
            authorizationWasCancelled: false,
            externalIdentityConflictDetected: false
        )

        switch fileAccess.read(.metadataFile) {
        case .notFound:
            break
        case let .readable(data):
            result.payloadFingerprints[.metadataFile] =
                AntigravityMigrationFingerprint.data(data)
            guard let metadata = try? JSONDecoder().decode(
                LegacyMetadata.self,
                from: data
            ), metadata.expiryDateMilliseconds?.isFinite != false else {
                result.outcomes[.metadataFile] = .invalid
                break
            }
            result.metadata = metadata
            result.outcomes[.metadataFile] = .readable
        case .invalid:
            result.outcomes[.metadataFile] = .invalid
        case let .failure(code):
            result.outcomes[.metadataFile] = .failure(code)
        case .interactionRequired, .cancelled:
            result.outcomes[.metadataFile] = .failure(-1)
        }

        decodeAccountFile(into: &result)
        decodeActiveCredentialFile(into: &result)
        for source in [
            AntigravityLegacySourceID.bundleIdentifierKeychain,
            .claudeUsageKeychain,
        ] {
            decodeKeychain(
                source,
                authenticationContext: authenticationContext,
                into: &result
            )
        }
        return result
    }

    func validateSources(_ inventory: Inventory) throws {
        if inventory.externalIdentityConflictDetected {
            throw AntigravityMigrationFlowError.blocked(
                .externalIdentityConflict
            )
        }
        for source in AntigravityLegacySourceID.allCases {
            switch inventory.outcomes[source] ?? .notFound {
            case .invalid:
                if inventory.canRecover(unreadable: source) {
                    continue
                }
                throw AntigravityMigrationFlowError.blocked(
                    .invalidLegacySource(source)
                )
            case let .failure(code):
                if inventory.canRecover(unreadable: source) {
                    continue
                }
                throw AntigravityMigrationFlowError.blocked(
                    .legacySourceFailure(source, code)
                )
            case .notFound, .readable, .interactionRequired:
                continue
            }
        }
    }

    func prepareMigration(from inventory: Inventory) throws -> Prepared {
        var candidatesByFingerprint: [String: [Candidate]] = [:]
        var emailLineages: [String: Set<String>] = [:]
        var aliasLineages: [String: Set<String>] = [:]
        var activeFingerprints: Set<String> = []

        for candidate in inventory.candidates {
            guard let fingerprint = AntigravityMigrationFingerprint.refresh(
                candidate.credentials
            ) else {
                throw AntigravityMigrationFlowError.blocked(.missingRefreshCredential)
            }
            candidatesByFingerprint[fingerprint, default: []].append(candidate)
            if let email = normalizedEmail(candidate.credentials.email) {
                emailLineages[email, default: []].insert(fingerprint)
            }
            if let alias = candidate.alias?.reconciliationTrimmedNonEmpty {
                aliasLineages[alias, default: []].insert(fingerprint)
            }
            if candidate.isActiveSignal {
                activeFingerprints.insert(fingerprint)
            }
        }

        guard !emailLineages.values.contains(where: { $0.count > 1 }),
              !aliasLineages.values.contains(where: { $0.count > 1 })
        else {
            throw AntigravityMigrationFlowError.blocked(.tokenLineageConflict)
        }

        let groups = candidatesByFingerprint.keys.sorted().map {
            CandidateGroup(
                fingerprint: $0,
                candidates: candidatesByFingerprint[$0] ?? []
            )
        }
        for group in groups {
            let emails = Set(group.candidates.compactMap {
                normalizedEmail($0.credentials.email)
            })
            guard emails.count <= 1 else {
                throw AntigravityMigrationFlowError.blocked(
                    .externalIdentityConflict
                )
            }
        }

        let activeFingerprint: String
        if groups.count == 1 {
            activeFingerprint = groups[0].fingerprint
        } else {
            guard activeFingerprints.count == 1,
                  let resolved = activeFingerprints.first
            else {
                throw AntigravityMigrationFlowError.blocked(
                    .activeAccountAmbiguous
                )
            }
            activeFingerprint = resolved
        }

        let timestamp = max(0, now().timeIntervalSince1970 * 1_000)
        var plannedAccounts: [AntigravityMigrationPlannedAccount] = []
        var credentialsByReference:
            [AntigravityCredentialReference: AntigravityOAuthCredentials] = [:]
        var journalAccounts: [AntigravityMigrationJournalAccount] = []
        var activeAccountID: AntigravityAccountID?

        for group in groups {
            let ordered = group.candidates.sorted(by: candidatePreferred)
            guard let preferred = ordered.first else {
                throw AntigravityMigrationFlowError.blocked(
                    .invalidLegacySource(.accountFile)
                )
            }
            var merged = preferred.credentials
            for candidate in ordered.dropFirst() {
                mergeMissing(candidate.credentials, into: &merged)
            }
            let accountID = AntigravityAccountID(uuid: uuidGenerator())
            let reference = AntigravityCredentialReference(uuid: uuidGenerator())
            let aliases = Array(Set(group.candidates.compactMap {
                $0.alias?.reconciliationTrimmedNonEmpty
            })).sorted()
            let created = group.candidates.compactMap(\.createdAtMilliseconds).min()
                ?? timestamp
            let updated = max(
                created,
                group.candidates.compactMap(\.updatedAtMilliseconds).max()
                    ?? timestamp
            )
            let email = normalizedEmail(merged.email)
            let label = preferred.label?.reconciliationTrimmedNonEmpty
                ?? email
                ?? "Google 계정"
            plannedAccounts.append(AntigravityMigrationPlannedAccount(
                id: accountID,
                label: label,
                externalIdentity: .init(email: email),
                migrationAliases: aliases,
                credentialReference: reference,
                createdAtMilliseconds: created,
                updatedAtMilliseconds: updated
            ))
            credentialsByReference[reference] = merged
            journalAccounts.append(AntigravityMigrationJournalAccount(
                accountID: accountID,
                credentialReference: reference,
                refreshTokenFingerprint: group.fingerprint
            ))
            if group.fingerprint == activeFingerprint {
                activeAccountID = accountID
            }
        }
        guard let activeAccountID else {
            throw AntigravityMigrationFlowError.blocked(.activeAccountAmbiguous)
        }
        return Prepared(
            repositoryPlan: AntigravityMigrationRepositoryPlan(
                expectedRevision: 0,
                activeAccountID: activeAccountID,
                accounts: plannedAccounts
            ),
            credentialsByReference: credentialsByReference,
            sourceInventoryFingerprint: sourceInventoryFingerprint(inventory),
            sourceFingerprints: sourceFingerprints(inventory),
            sourcePayloadFingerprints: payloadFingerprints(inventory),
            journalAccounts: journalAccounts
        )
    }

    func sourceInventoryFingerprint(_ inventory: Inventory) -> String {
        AntigravityMigrationFingerprint.digest(
            sourceFingerprints(inventory)
                .map { "\($0.key.rawValue):\($0.value)" }
                .sorted()
        )
    }

    func sourceFingerprints(
        _ inventory: Inventory
    ) -> [AntigravityLegacySourceID: String] {
        Dictionary(
            uniqueKeysWithValues: AntigravityLegacySourceID.allCases.map {
                source in
                (
                    source,
                    AntigravityMigrationFingerprint.digest([
                        source.rawValue,
                        outcomeCode(inventory.outcomes[source] ?? .notFound),
                        inventory.payloadFingerprints[source] ?? "",
                    ])
                )
            }
        )
    }

    func payloadFingerprints(
        _ inventory: Inventory
    ) -> [AntigravityLegacySourceID: String] {
        inventory.payloadFingerprints
    }

    func interactionRequiredFingerprint(
        for source: AntigravityLegacySourceID
    ) -> String {
        AntigravityMigrationFingerprint.digest([
            source.rawValue,
            outcomeCode(.interactionRequired),
            "",
        ])
    }

    func credentialFingerprints(
        for source: AntigravityLegacySourceID,
        in inventory: Inventory
    ) -> Set<String> {
        Set(inventory.candidates.compactMap {
            guard $0.source == source else { return nil }
            return AntigravityMigrationFingerprint.refresh($0.credentials)
        })
    }

    private func decodeAccountFile(into inventory: inout Inventory) {
        switch fileAccess.read(.accountFile) {
        case .notFound:
            return
        case let .readable(data):
            inventory.payloadFingerprints[.accountFile] =
                AntigravityMigrationFingerprint.data(data)
            guard let state = try? JSONDecoder().decode(
                AntigravityOAuthAccountState.self,
                from: data
            ), isValidLegacyAccountState(state) else {
                inventory.outcomes[.accountFile] = .invalid
                return
            }
            inventory.outcomes[.accountFile] = .readable
            if state.accounts.contains(where: { account in
                guard let outer = normalizedEmail(account.email),
                      let inner = normalizedEmail(account.credentials.email)
                else {
                    return false
                }
                return outer != inner
            }) {
                inventory.externalIdentityConflictDetected = true
            }
            inventory.candidates.append(contentsOf: state.accounts.map { account in
                Candidate(
                    source: .accountFile,
                    alias: account.id,
                    label: account.label,
                    credentials: credentials(
                        account.credentials,
                        fillingMissingEmail: account.email
                    ),
                    createdAtMilliseconds: account.createdAtMilliseconds,
                    updatedAtMilliseconds: account.updatedAtMilliseconds,
                    isActiveSignal: account.id == state.activeAccountID
                )
            })
        case .invalid:
            inventory.outcomes[.accountFile] = .invalid
        case let .failure(code):
            inventory.outcomes[.accountFile] = .failure(code)
        case .interactionRequired, .cancelled:
            inventory.outcomes[.accountFile] = .failure(-1)
        }
    }

    private func decodeActiveCredentialFile(into inventory: inout Inventory) {
        switch fileAccess.read(.activeCredentialFile) {
        case .notFound:
            return
        case let .readable(data):
            inventory.payloadFingerprints[.activeCredentialFile] =
                AntigravityMigrationFingerprint.data(data)
            guard let decoded = decodeLegacyCredentials(
                data,
                metadata: inventory.metadata
            ) else {
                inventory.outcomes[.activeCredentialFile] = .invalid
                return
            }
            inventory.outcomes[.activeCredentialFile] = .readable
            inventory.candidates.append(Candidate(
                source: .activeCredentialFile,
                alias: nil,
                label: decoded.email,
                credentials: decoded,
                createdAtMilliseconds: nil,
                updatedAtMilliseconds: nil,
                isActiveSignal: true
            ))
        case .invalid:
            inventory.outcomes[.activeCredentialFile] = .invalid
        case let .failure(code):
            inventory.outcomes[.activeCredentialFile] = .failure(code)
        case .interactionRequired, .cancelled:
            inventory.outcomes[.activeCredentialFile] = .failure(-1)
        }
    }

    private func decodeKeychain(
        _ source: AntigravityLegacySourceID,
        authenticationContext: LAContext?,
        into inventory: inout Inventory
    ) {
        switch keychainAccess.read(
            source,
            authenticationContext: authenticationContext
        ) {
        case .notFound:
            return
        case let .readable(data):
            inventory.payloadFingerprints[source] =
                AntigravityMigrationFingerprint.data(data)
            guard let decoded = decodeLegacyCredentials(
                data,
                metadata: inventory.metadata
            ) else {
                inventory.outcomes[source] = .invalid
                return
            }
            inventory.outcomes[source] = .readable
            inventory.candidates.append(Candidate(
                source: source,
                alias: nil,
                label: decoded.email,
                credentials: decoded,
                createdAtMilliseconds: nil,
                updatedAtMilliseconds: nil,
                isActiveSignal: true
            ))
        case .interactionRequired:
            inventory.outcomes[source] = .interactionRequired
        case .cancelled:
            inventory.outcomes[source] = .interactionRequired
            inventory.authorizationWasCancelled = true
        case .invalid:
            inventory.outcomes[source] = .invalid
        case let .failure(code):
            inventory.outcomes[source] = .failure(code)
        }
    }

    private func isValidLegacyAccountState(
        _ state: AntigravityOAuthAccountState
    ) -> Bool {
        guard Set(state.accounts.map(\.id)).count == state.accounts.count,
              state.accounts.allSatisfy({
                  $0.id.reconciliationTrimmedNonEmpty != nil
                      && $0.label.reconciliationTrimmedNonEmpty != nil
                      && $0.credentials.hasTokenMaterial
                      && $0.createdAtMilliseconds.isFinite
                      && $0.createdAtMilliseconds >= 0
                      && $0.updatedAtMilliseconds.isFinite
                      && $0.updatedAtMilliseconds >= $0.createdAtMilliseconds
              })
        else {
            return false
        }
        return true
    }

    private func decodeLegacyCredentials(
        _ data: Data,
        metadata: LegacyMetadata?
    ) -> AntigravityOAuthCredentials? {
        if var credentials = try? JSONDecoder().decode(
            AntigravityOAuthCredentials.self,
            from: data
        ), credentials.hasTokenMaterial {
            merge(metadata: metadata, into: &credentials)
            return credentials
        }
        guard let secrets = try? JSONDecoder().decode(
            LegacyTokenSecrets.self,
            from: data
        ), secrets.accessToken?.reconciliationTrimmedNonEmpty != nil
            || secrets.refreshToken?.reconciliationTrimmedNonEmpty != nil
        else {
            return nil
        }
        return AntigravityOAuthCredentials(
            accessToken: secrets.accessToken,
            refreshToken: secrets.refreshToken,
            expiryDate: metadata?.expiryDateMilliseconds.map {
                Date(timeIntervalSince1970: $0 / 1_000)
            },
            idToken: secrets.idToken,
            email: metadata?.email,
            projectID: metadata?.projectID,
            clientID: metadata?.clientID,
            clientSecret: nil
        )
    }

    private func merge(
        metadata: LegacyMetadata?,
        into credentials: inout AntigravityOAuthCredentials
    ) {
        guard let metadata else { return }
        credentials.expiryDateMilliseconds =
            credentials.expiryDateMilliseconds ?? metadata.expiryDateMilliseconds
        credentials.email = credentials.email ?? metadata.email
        credentials.projectID = credentials.projectID ?? metadata.projectID
        credentials.clientID = credentials.clientID ?? metadata.clientID
    }

    private func credentials(
        _ credentials: AntigravityOAuthCredentials,
        fillingMissingEmail email: String?
    ) -> AntigravityOAuthCredentials {
        var result = credentials
        result.email = result.email ?? email
        return result
    }

    private func candidatePreferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = candidateRank(lhs)
        let right = candidateRank(rhs)
        if left != right { return left > right }
        return (lhs.updatedAtMilliseconds ?? 0) > (rhs.updatedAtMilliseconds ?? 0)
    }

    private func candidateRank(_ candidate: Candidate) -> Int {
        switch candidate.source {
        case .activeCredentialFile:
            return 4
        case .accountFile:
            return 3
        case .bundleIdentifierKeychain:
            return 2
        case .claudeUsageKeychain:
            return 1
        case .metadataFile:
            return 0
        }
    }

    private func mergeMissing(
        _ source: AntigravityOAuthCredentials,
        into target: inout AntigravityOAuthCredentials
    ) {
        target.accessToken = target.accessToken ?? source.accessToken
        target.refreshToken = target.refreshToken ?? source.refreshToken
        target.expiryDateMilliseconds =
            target.expiryDateMilliseconds ?? source.expiryDateMilliseconds
        target.idToken = target.idToken ?? source.idToken
        target.email = target.email ?? source.email
        target.projectID = target.projectID ?? source.projectID
        target.clientID = target.clientID ?? source.clientID
        target.clientSecret = target.clientSecret ?? source.clientSecret
    }

    private func outcomeCode(_ outcome: AntigravityLegacySourceOutcome) -> String {
        switch outcome {
        case .notFound:
            return "notFound"
        case .readable:
            return "readable"
        case .interactionRequired:
            return "interactionRequired"
        case .invalid:
            return "invalid"
        case let .failure(code):
            return "failure:\(code)"
        }
    }

    private func normalizedEmail(_ email: String?) -> String? {
        email?.reconciliationTrimmedNonEmpty?.lowercased()
    }
}

private extension String {
    nonisolated var reconciliationTrimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
