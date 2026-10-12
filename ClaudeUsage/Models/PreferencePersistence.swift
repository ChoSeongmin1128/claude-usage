import Foundation
import CoreFoundation

nonisolated enum PreferenceChangeIntent { case automatic, user }

nonisolated enum PreferenceSaveResult: Equatable, Sendable {
    case saved, unchanged, blocked(String), failed(String)
    var accepted: Bool { self == .saved || self == .unchanged }
    var message: String? {
        switch self {
        case .saved, .unchanged: nil
        case .blocked(let message), .failed(let message): message
        }
    }
}

/// Private value state for the existing preference owners, never part of their business equality.
/// Foundation JSON objects are captured as immutable values; mutations always produce a new tree.
nonisolated struct PreferencePersistenceContext: @unchecked Sendable {
    var object: Any?
    var raw: [String: Any] = [:]
    var baseline: [String: Any] = [:]
    var unreadable: Set<[String]> = []
    var writable = true

    init() {}
    init(object: Any?) {
        self.object = object
        guard let object else { return }
        guard let data = object as? Data,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            writable = false
            return
        }
        raw = value
    }
    init(from decoder: Decoder) throws {
        let value = try PreferenceJSONValue(from: decoder)
        guard let root = value.object as? [String: Any] else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Preference root must be an object"))
        }
        raw = root
    }

    func canChange(_ path: [String]) -> Bool {
        writable && !unreadable.contains { path.starts(with: $0) || $0.starts(with: path) }
    }

    mutating func read<T: Decodable>(_ type: T.Type, at path: [String], fallback: T) -> T {
        guard let value = Self.value(in: raw, at: path) else { return fallback }
        do {
            return try JSONDecoder().decode(
                type,
                from: JSONSerialization.data(
                    withJSONObject: value, options: [.fragmentsAllowed]))
        } catch {
            unreadable.insert(path)
            return fallback
        }
    }

    mutating func dictionary<T: Decodable>(_ type: T.Type, at key: String) -> [String: T] {
        guard let value = raw[key] else { return [:] }
        guard let entries = value as? [String: Any] else { unreadable.insert([key]); return [:] }
        var result: [String: T] = [:]
        for id in entries.keys {
            let decoded: T? = read(Optional<T>.self, at: [key, id], fallback: nil)
            if let decoded { result[id] = decoded } else { unreadable.insert([key, id]) }
        }
        return result
    }

    mutating func checkVersion(required: Bool) {
        guard let version = raw["version"] else { if required { writable = false }; return }
        guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.intValue == 1, number.doubleValue == 1
        else { writable = false; return }
    }

    func merged(_ known: [String: Any]) -> [String: Any] {
        if object == nil && raw.isEmpty { return known }
        var result = raw
        for path in Self.changedPaths(baseline, known) {
            Self.replace(Self.value(in: known, at: path), at: path, in: &result)
        }
        return result
    }

    mutating func save(
        _ known: [String: Any], to defaults: UserDefaults, key: String,
        preparedRaw: [String: Any]? = nil
    ) -> PreferenceSaveResult {
        guard writable else { return .blocked("저장된 설정을 읽을 수 없어 변경하지 않았습니다.") }
        let changed = Self.changedPaths(baseline, known)
        guard changed.allSatisfy(canChange) else {
            return .blocked("읽을 수 없는 설정 항목은 변경하지 않았습니다.")
        }
        let current = defaults.object(forKey: key)
        guard Self.equal(current, object) else {
            return .blocked("설정이 다른 곳에서 변경되었습니다. 다시 확인해 주세요.")
        }
        guard !changed.isEmpty || object == nil else { return .unchanged }
        do {
            let updated = preparedRaw ?? merged(known)
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else {
                Self.restore(object, to: defaults, key: key)
                return .failed("설정을 저장하지 못했습니다. 다시 시도해 주세요.")
            }
            object = data
            raw = updated
            baseline = known
            return .saved
        } catch { return .failed("설정을 저장하지 못했습니다. 다시 시도해 주세요.") }
    }

    static func restore(_ object: Any?, to defaults: UserDefaults, key: String) {
        if let object { defaults.set(object, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        return (lhs as? NSObject)?.isEqual(rhs) == true
    }

    static func value(in root: [String: Any], at path: [String]) -> Any? {
        var value: Any = root
        for key in path { guard let next = (value as? [String: Any])?[key] else { return nil }; value = next }
        return value
    }

    private static func replace(_ value: Any?, at path: [String], in root: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 { root[key] = value; return }
        var child = root[key] as? [String: Any] ?? [:]
        replace(value, at: Array(path.dropFirst()), in: &child)
        root[key] = child
    }

    private static func changedPaths(_ before: [String: Any], _ after: [String: Any], prefix: [String] = [])
        -> [[String]]
    {
        Set(before.keys).union(after.keys).flatMap { key -> [[String]] in
            guard !equal(before[key], after[key]) else { return [] }
            if let old = before[key] as? [String: Any], let new = after[key] as? [String: Any] {
                return changedPaths(old, new, prefix: prefix + [key])
            }
            return [prefix + [key]]
        }
    }
}

/// Codable bridge used only to capture/emit the original JSON of these preference values.
nonisolated enum PreferenceJSONValue: Codable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([Self]), object([String: Self])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }
    var object: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.object)
        case .object(let value): value.mapValues(\.object)
        }
    }
    static func encode(_ object: Any, to encoder: Encoder) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        try JSONDecoder().decode(Self.self, from: data).encode(to: encoder)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
