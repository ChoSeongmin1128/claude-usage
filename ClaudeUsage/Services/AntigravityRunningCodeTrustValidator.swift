import Foundation
import Security

nonisolated protocol AntigravityDynamicCodeRequirementChecking:
    Sendable
{
    func process(
        _ processID: Int32,
        satisfies requirement: String
    ) -> Bool
}

/// Uses Security.framework's dynamic-code API. Unlike static path validation,
/// `SecCodeCheckValidity` asks the kernel code-signing host about the running
/// process and is explicitly secure against changes to its filesystem source.
nonisolated struct AntigravitySystemDynamicCodeRequirementChecker:
    AntigravityDynamicCodeRequirementChecking
{
    func process(
        _ processID: Int32,
        satisfies requirementSource: String
    ) -> Bool {
        guard processID > 0 else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementSource as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }

        let attributes = [
            kSecGuestAttributePid as String:
                NSNumber(value: processID)
        ] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode
        ) == errSecSuccess,
        let runningCode else {
            return false
        }

        return SecCodeCheckValidity(
            runningCode,
            SecCSFlags(),
            requirement
        ) == errSecSuccess
    }
}

nonisolated protocol AntigravityRunningCodeTrustValidating:
    Sendable
{
    func validatesRunningCode(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool
}

/// Applies the trust authority appropriate to each runtime role.
///
/// AGY is authorized by its reviewed SHA-256 plus mapped-vnode identity.
/// Antigravity.app's language server has no pinned release digest, so its
/// running process must additionally satisfy Google's exact Developer ID
/// designated requirement.
nonisolated struct AntigravityOfficialRunningCodeTrustValidator:
    AntigravityRunningCodeTrustValidating
{
    private let dynamicCodeChecker:
        any AntigravityDynamicCodeRequirementChecking

    init(
        dynamicCodeChecker:
            any AntigravityDynamicCodeRequirementChecking =
                AntigravitySystemDynamicCodeRequirementChecker()
    ) {
        self.dynamicCodeChecker = dynamicCodeChecker
    }

    func validatesRunningCode(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        switch executable.role {
        case .agyCLI:
            return executable.fileIdentity.map {
                AntigravityOfficialAGYBinaryDigestPolicy
                    .accepts($0.sha256Digest)
            } ?? false

        case .appLanguageServer:
            guard executable.appBundle?.bundleIdentifier
                    == AntigravityAppBundleIdentity
                        .requiredBundleIdentifier else {
                return false
            }
            return dynamicCodeChecker.process(
                processID,
                satisfies:
                    AntigravityOfficialExecutableTrustPolicy
                        .languageServerDesignatedRequirement
            )
        }
    }
}
