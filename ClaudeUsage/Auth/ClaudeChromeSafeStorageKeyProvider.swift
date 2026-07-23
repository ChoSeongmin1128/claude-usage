import CommonCrypto
import Foundation

struct ClaudeChromeSafeStorageLabel: Equatable, Sendable {
    let service: String
    let account: String
}

enum ClaudeChromeSafeStorageKeyError: LocalizedError, Equatable, Sendable {
    case cancelled
    case invalidData
    case unavailable

    nonisolated var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Chrome Safe Storage 인증을 취소했습니다."
        case .invalidData:
            return "Chrome Safe Storage 데이터가 유효하지 않습니다."
        case .unavailable:
            return "Chrome Safe Storage 키를 읽지 못했습니다."
        }
    }
}

/// Chrome의 모든 프로필은 같은 Safe Storage secret을 사용한다.
/// 사용자 주도 가져오기 한 번에 secret을 한 번만 해석해 파생 키를 공유한다.
struct ClaudeChromeSafeStorageKeyProvider: Sendable {
    typealias PayloadReader = @Sendable (
        _ service: String,
        _ account: String?
    ) -> KeychainAccessPreflight.ReadOutcome
    typealias InteractivePayloadReader = @Sendable (
        _ service: String,
        _ account: String?,
        _ localizedReason: String
    ) -> KeychainAccessPreflight.ReadOutcome

    nonisolated static let defaultLabels = [
        ClaudeChromeSafeStorageLabel(service: "Chrome Safe Storage", account: "Chrome"),
        ClaudeChromeSafeStorageLabel(service: "Google Chrome Safe Storage", account: "Chrome"),
        ClaudeChromeSafeStorageLabel(service: "Chromium Safe Storage", account: "Chromium"),
    ]

    private let labels: [ClaudeChromeSafeStorageLabel]
    private let payloadReader: PayloadReader
    private let interactivePayloadReader: InteractivePayloadReader

    nonisolated init(
        labels: [ClaudeChromeSafeStorageLabel] = Self.defaultLabels,
        payloadReader: @escaping PayloadReader = { service, account in
            KeychainAccessPreflight.readGenericPasswordWithoutUI(
                service: service,
                account: account
            )
        },
        interactivePayloadReader: @escaping InteractivePayloadReader = { service, account, reason in
            KeychainAccessPreflight.readGenericPasswordInteractively(
                service: service,
                account: account,
                localizedReason: reason
            )
        }
    ) {
        self.labels = labels
        self.payloadReader = payloadReader
        self.interactivePayloadReader = interactivePayloadReader
    }

    /// 먼저 UI 금지 조회로 이미 허용된 항목을 찾는다. 인증이 필요한 정확한 항목을
    /// 만나면 그 항목에만 대화형 조회를 한 번 수행하고 다른 후보로 재시도하지 않는다.
    nonisolated func loadDerivedKeysForUserInitiatedImport() throws -> [Data] {
        for label in labels {
            switch payloadReader(label.service, label.account) {
            case .value(let password):
                return [Self.deriveKey(from: password)]
            case .notFound:
                continue
            case .interactionRequired:
                return try loadInteractively(label)
            case .cancelled:
                throw ClaudeChromeSafeStorageKeyError.cancelled
            case .invalidData:
                throw ClaudeChromeSafeStorageKeyError.invalidData
            case .failure:
                continue
            }
        }
        return []
    }

    private nonisolated func loadInteractively(
        _ label: ClaudeChromeSafeStorageLabel
    ) throws -> [Data] {
        switch interactivePayloadReader(
            label.service,
            label.account,
            "Chrome에 저장된 Claude 로그인을 가져옵니다."
        ) {
        case .value(let password):
            return [Self.deriveKey(from: password)]
        case .cancelled:
            throw ClaudeChromeSafeStorageKeyError.cancelled
        case .invalidData:
            throw ClaudeChromeSafeStorageKeyError.invalidData
        case .notFound, .interactionRequired, .failure:
            throw ClaudeChromeSafeStorageKeyError.unavailable
        }
    }

    private nonisolated static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyBytes.count
                    )
                }
            }
        }
        return key
    }
}
