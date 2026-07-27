import Foundation

protocol AntigravitySettingsMigrationStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String)
    func removeObject(forKey key: String)
}

final class UserDefaultsAntigravitySettingsMigrationStore:
    AntigravitySettingsMigrationStore
{
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
