import Foundation

enum RuntimeRefreshHandlerRegistry {
    static func makeHandlers(
        descriptors: [RuntimeProviderDescriptor] = RuntimeProviderRegistry.supportedDescriptors,
        refreshClaude: @escaping (Bool) -> Void,
        refreshCodex: @escaping (Bool) -> Void,
        refreshGemini: @escaping (Bool) -> Void
    ) -> [PopoverService: (Bool) -> Void] {
        var handlers: [PopoverService: (Bool) -> Void] = [:]

        for descriptor in descriptors {
            switch descriptor.refreshStrategy {
            case .claude:
                handlers[descriptor.service] = refreshClaude
            case .codex:
                handlers[descriptor.service] = refreshCodex
            case .gemini:
                handlers[descriptor.service] = refreshGemini
            }
        }

        return handlers
    }
}
