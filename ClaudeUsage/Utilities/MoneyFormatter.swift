import Foundation

nonisolated enum MoneyFormatter {
    /// 최소 단위(센트 등) 금액을 그 통화의 기호와 소수 자릿수로 쓴다. 서버가 자릿수를 주면 그 값을 따른다.
    static func string(minorUnits: Double, currency: String, decimalPlaces: Int? = nil) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = code.isEmpty ? "USD" : code
        let digits = max(0, min(4, decimalPlaces ?? formatter.maximumFractionDigits))
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let value = minorUnits / pow(10, Double(digits))
        return formatter.string(from: NSNumber(value: value)) ?? "\(formatter.currencyCode ?? code) \(value)"
    }

    /// Codex 크레딧은 금액이 아니라 개수다. 천 단위 구분, 소수는 있을 때만 두 자리까지.
    static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + " 크레딧"
    }
}
