import AppKit

private enum ProviderActionSymbols {
    static let usage = resolve("chart.bar.xaxis", fallback: "chart.bar")
    static let status = resolve("waveform.path.ecg.rectangle", fallback: "waveform.path.ecg")

    private static func resolve(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }
}

extension ProviderExternalAction {
    /// Symbols are a presentation decision; the provider descriptor owns the destination.
    var systemImageName: String {
        switch kind {
        case .usage: ProviderActionSymbols.usage
        case .status: ProviderActionSymbols.status
        }
    }
}
