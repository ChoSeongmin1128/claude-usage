struct UsageWindowAlertPolicy {
    struct Decision: Equatable {
        let thresholdToAlert: Int?
        let alertedThresholds: Set<Int>
    }

    static let rearmMarginPercentagePoints = 5.0

    static func evaluate(
        previousPercentage: Double?,
        currentPercentage: Double,
        // resetAt is accepted for call-site context, but it must not re-arm alerts.
        resetAt: String?,
        thresholds: [Int],
        alertedThresholds: Set<Int>,
        isFirstCheck: Bool
    ) -> Decision {
        let activeThresholds = normalized(thresholds)
        var updatedAlerts = alertedThresholds.intersection(activeThresholds)

        if isFirstCheck {
            for threshold in activeThresholds where currentPercentage >= Double(threshold) {
                updatedAlerts.insert(threshold)
            }
            return Decision(thresholdToAlert: nil, alertedThresholds: updatedAlerts)
        }

        for threshold in activeThresholds {
            if currentPercentage < Double(threshold) - rearmMarginPercentagePoints {
                updatedAlerts.remove(threshold)
            }
        }

        let thresholdToAlert = activeThresholds.reversed().first { threshold in
            guard currentPercentage >= Double(threshold) else { return false }
            guard !updatedAlerts.contains(threshold) else { return false }
            guard let previousPercentage else { return true }
            return previousPercentage < Double(threshold)
        }

        if thresholdToAlert != nil {
            for threshold in activeThresholds where currentPercentage >= Double(threshold) {
                updatedAlerts.insert(threshold)
            }
        }

        return Decision(thresholdToAlert: thresholdToAlert, alertedThresholds: updatedAlerts)
    }

    private static func normalized(_ thresholds: [Int]) -> [Int] {
        Array(Set(thresholds))
            .filter { (1...100).contains($0) }
            .sorted()
    }
}
