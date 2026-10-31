import Foundation
import Security

/// Ключи Spotify Web API в Связке ключей (обычный пароль, service `capri.spotify`). В UserDefaults — ничего.
/// Подпись ad-hoc меняется с каждой сборкой: после переустановки macOS может спросить доступ к паролю при первом
/// чтении — читаем только по действию человека (поиск, «Проверить»), есть ли ключи — без чтения секрета.
enum Keychain {
    static let service = "capri.spotify"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Есть ли запись — только атрибуты, без секрета (не спрашивает доступ).
    static func exists(_ account: String) -> Bool {
        var q = base(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> OSStatus {
        // Сначала обновить на месте (не теряем запись между delete и add), нет записи — добавить.
        let data = Data(value.utf8)
        let st = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st != errSecItemNotFound { return st }
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Capri — Spotify \(account)"
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
