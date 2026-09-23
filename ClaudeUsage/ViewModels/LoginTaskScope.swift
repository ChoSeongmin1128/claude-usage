import Foundation

/// A login window owns one active operation. Closing or going back prevents late UI transitions.
@MainActor
final class LoginTaskScope {
    private var revision: UUID?
    private var task: Task<Void, Never>?

    func run<Value: Sendable>(
        operation: @escaping @MainActor () async -> Value,
        apply: @escaping @MainActor (Value) -> Void
    ) {
        cancel()
        let current = UUID()
        revision = current
        task = Task { @MainActor [weak self] in
            let result = await operation()
            guard !Task.isCancelled, let self, self.revision == current else { return }
            self.task = nil
            apply(result)
        }
    }

    func cancel() {
        revision = nil
        task?.cancel()
        task = nil
    }
}
