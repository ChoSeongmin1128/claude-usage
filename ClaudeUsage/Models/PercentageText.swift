import Foundation

/// 퍼센트 표시 반올림. 실제로 0이나 100이 아닌 값이 반올림 때문에 0%, 100%로 보이면
/// 다 쓴 것(또는 하나도 안 쓴 것)으로 오해하므로 1과 99에서 멈춘다.
nonisolated enum PercentageText {
    static func wholeNumber(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        if rounded == 0, value > 0 { return 1 }
        if rounded == 100, value < 100 { return 99 }
        return rounded
    }

    static func string(_ value: Double) -> String {
        "\(wholeNumber(value))%"
    }

    /// 소수 한 자리 표시용. 반올림이 100.0이 되면 99.9에서 멈추고 0.0이 되면 0.1로 올린다.
    static func tenths(_ value: Double) -> Double {
        let rounded = (value * 10).rounded() / 10
        if rounded >= 100, value < 100 { return 99.9 }
        if rounded <= 0, value > 0 { return 0.1 }
        return rounded
    }
}
