import Foundation
import CapriKit

/// Поиск трека по названию через Spotify Web API (client credentials) — по желанию: ключи бесплатного
/// приложения developer.spotify.com в Связке ключей. Без ключей «включи X» по названию не ищется — Capri просит ссылку (поиск в Spotify крадёт фокус и не включает).
/// Токен — только в памяти, до `expiresIn − 60`. Ключи читаются только по действию человека.
final class SpotifySearch: ObservableObject {
    static let idAccount = "client-id"
    static let secretAccount = "client-secret"

    /// Ключи сохранены (по атрибутам Связки, без чтения секрета).
    @Published private(set) var hasKeys = false
    /// Итог «Проверить» для настроек.
    @Published var status: String?
    private var token: (value: String, until: Date)?
    private var keys: (id: String, secret: String)?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    init() { refresh() }

    func refresh() {
        let has = Keychain.exists(Self.idAccount) && Keychain.exists(Self.secretAccount)
        if hasKeys != has { hasKeys = has }
    }

    func save(id: String, secret: String) {
        let i = id.trimmingCharacters(in: .whitespacesAndNewlines), s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !i.isEmpty, !s.isEmpty else { status = "нужны оба ключа"; return }
        let a = Keychain.set(Self.idAccount, i), b = Keychain.set(Self.secretAccount, s)
        token = nil
        keys = a == errSecSuccess && b == errSecSuccess ? (i, s) : nil
        status = keys == nil ? "не сохранилось в Связке ключей (\(a), \(b))" : "сохранено"
        refresh()
    }

    func erase() {
        Keychain.delete(Self.idAccount)
        Keychain.delete(Self.secretAccount)
        token = nil
        keys = nil
        status = "ключи стёрты"
        refresh()
    }

    /// «Проверить»: запросить токен.
    func check() {
        status = "проверяю…"
        withToken { [weak self] r in
            switch r {
            case .success: self?.status = "ключи работают ✓"
            case .failure(let e): self?.status = e.text
            }
        }
    }

    enum Failure: Error {
        case noKeys, badKeys, network(String)
        var text: String {
            switch self {
            case .noKeys: "ключей нет"
            case .badKeys: "Spotify не принял ключи"
            case .network(let m): "нет связи со Spotify: \(m)"
            }
        }
    }

    /// Найти и вернуть ссылку (nil — ничего не нашлось). Колбэк — на главном потоке.
    func find(_ query: String, completion: @escaping (Result<SpotifyURI?, Failure>) -> Void) {
        withToken { [weak self] r in
            guard let self else { return }
            switch r {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                self.session.dataTask(with: SpotifyAPI.searchRequest(query: query, token: token)) { data, resp, err in
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let out: Result<SpotifyURI?, Failure>
                    if let err { out = .failure(.network(err.localizedDescription)) }
                    else if code == 401 { out = .failure(.badKeys) }
                    else if code != 200 { out = .failure(.network("HTTP \(code)")) }
                    else { out = .success(data.flatMap { SpotifyAPI.parseSearch($0, query: query) }) }
                    DispatchQueue.main.async {
                        if case .failure(.badKeys) = out { self.token = nil }
                        completion(out)
                    }
                }.resume()
            }
        }
    }

    private func withToken(_ completion: @escaping (Result<String, Failure>) -> Void) {
        if let t = token, t.until > Date() { completion(.success(t.value)); return }
        guard let keys else {
            // Чтение секрета — не на главном потоке: после переустановки macOS может спросить доступ к паролю,
            // и notch со сценами не должны замирать, пока человек отвечает.
            Self.keychainQueue.async { [weak self] in
                let i = Keychain.get(Self.idAccount), s = Keychain.get(Self.secretAccount)
                DispatchQueue.main.async {
                    guard let self, let i, let s else { completion(.failure(.noKeys)); return }
                    if self.keys == nil { self.keys = (i, s) }
                    self.requestToken(completion)
                }
            }
            return
        }
        requestToken(keys, completion)
    }

    private static let keychainQueue = DispatchQueue(label: "capri.spotify.keychain", qos: .userInitiated)

    private func requestToken(_ completion: @escaping (Result<String, Failure>) -> Void) {
        guard let keys else { completion(.failure(.noKeys)); return }
        requestToken(keys, completion)
    }

    private func requestToken(_ keys: (id: String, secret: String), _ completion: @escaping (Result<String, Failure>) -> Void) {
        session.dataTask(with: SpotifyAPI.tokenRequest(clientID: keys.id, secret: keys.secret)) { [weak self] data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = data.flatMap(SpotifyAPI.parseToken)
            DispatchQueue.main.async {
                if let err { completion(.failure(.network(err.localizedDescription))); return }
                guard code == 200, let p = parsed else { completion(.failure(code == 400 || code == 401 ? .badKeys : .network("HTTP \(code)"))); return }
                self?.token = (p.token, Date().addingTimeInterval(max(60, p.expiresIn - 60)))
                completion(.success(p.token))
            }
        }.resume()
    }
}
