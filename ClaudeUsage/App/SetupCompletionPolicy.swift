import Foundation

enum SetupCompletionPolicy {
    static func isOrganizationReady(
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        let preferredID = preferredOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredID.isEmpty else { return true }
        return cachedMetadata?.organizationUUID == preferredID
    }

    static func shouldMarkCompleteAfterSuccessfulClaudeRefresh(
        preferredOrganizationID: String,
        cachedMetadata: ClaudeProfileMetadata?
    ) -> Bool {
        isOrganizationReady(
            preferredOrganizationID: preferredOrganizationID,
            cachedMetadata: cachedMetadata
        )
    }
}
