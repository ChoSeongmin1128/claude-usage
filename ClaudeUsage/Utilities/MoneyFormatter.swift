import Foundation

nonisolated enum MoneyFormatter {
    /// 최소 단위(센트 등) 금액을 그 통화의 기호와 소수 자릿수로 쓴다. 서버가 자릿수를 주면 그 값을 따른다.
    static func string(minorUnits: Double, currency: String, decimalPlaces: Int? = nil) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = code.isEmpty ? "USD" : code
        let scale = decimalPlaces ?? formatter.maximumFractionDigits
        let divisor = pow(10, Double(scale))
        guard minorUnits.isFinite, scale >= 0, divisor.isFinite, divisor > 0 else { return "금액 알 수 없음" }
        let digits = min(4, scale)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let value = minorUnits / divisor
        return formatter.string(from: NSNumber(value: value)) ?? "\(formatter.currencyCode ?? code) \(value)"
    }

    /// Codex 크레딧은 금액이 아니라 개수다. 천 단위 구분, 소수는 있을 때만 두 자리까지.
    static func credits(_ value: Double) -> String {
        guard value.isFinite else { return "크레딧 알 수 없음" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + " 크레딧"
    }
}
