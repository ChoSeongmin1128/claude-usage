import Foundation

/// Replace fields changed by a known model while retaining fields that model cannot read.
nonisolated enum PreservingJSONFields {
    static func replacing(in original: Any, previous: Any, updated: Any) -> Any {
        if (previous as? NSObject)?.isEqual(updated) == true { return original }
        guard var result = original as? [String: Any],
            let before = previous as? [String: Any], let after = updated as? [String: Any]
        else { return updated }
        for key in Set(before.keys).union(after.keys) {
            guard let new = after[key] else { result.removeValue(forKey: key); continue }
            if let old = before[key], let raw = result[key] {
                result[key] = replacing(in: raw, previous: old, updated: new)
            } else {
                result[key] = new
            }
        }
        return result
    }
}
