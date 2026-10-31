import Foundation

// Музыка по просьбе человека (проход 2, п. 5): разбор просьб «включи X / пауза / дальше», ссылки Spotify,
// строки AppleScript для Spotify и Музыки, запросы Spotify Web API и выбор плеера. Всё чистое — сам AppleScript
// запускает `MusicController` (Capri), и только как прямое следствие действия человека.

/// Что сделать с музыкой.
public enum MusicCommand: Equatable {
    /// Найти и включить (Spotify — через Web API или поиск в приложении, Музыка — поиск по медиатеке).
    case play(String)
    /// Ссылка или `spotify:`-адрес — сразу `play track`.
    case playURI(SpotifyURI)
    case toggle
    case pause
    case resume
    case next
    case previous

    /// Для журнала: без текста запроса.
    public var log: String {
        switch self {
        case .play(let q): "play(\(q.count) зн.)"
        case .playURI(let u): "playURI(\(u.kind))"
        case .toggle: "toggle"
        case .pause: "pause"
        case .resume: "resume"
        case .next: "next"
        case .previous: "previous"
        }
    }

    /// Кнопки ⏮ ⏯ ⏭ и `music cmd …`.
    public init?(button id: String) {
        switch id {
        case "prev", "previous": self = .previous
        case "toggle", "playpause": self = .toggle
        case "next": self = .next
        case "pause": self = .pause
        case "resume", "play": self = .resume
        default: return nil
        }
    }

    /// Кнопка с этим действием на столе и в notch.
    public var button: String? {
        switch self {
        case .previous: "prev"
        case .toggle: "toggle"
        case .next: "next"
        default: nil
        }
    }

    /// Кнопки ⏮ ⏯ ⏭ по порядку.
    public static let buttons = [MusicCommand.previous, .toggle, .next].compactMap(\.button)

    /// Нужен ли плеер, который уже играет/запущен (паузу ради паузы не запускаем).
    public var needsRunningPlayer: Bool {
        switch self {
        // ⏯ тоже: кнопка не должна запускать плеер — запускает только «включи».
        case .pause, .next, .previous, .toggle: true
        default: false
        }
    }

    // MARK: разбор просьбы

    static let playVerbs = ["включи", "включай", "вруби", "врубай", "поставь", "запусти", "сыграй", "play", "put on"]
    /// Глаголы, которые в разговоре о сессиях чаще про работу («запусти тесты», «поставь задачу»): музыка — только
    /// с музыкальным словом или названием в кавычках.
    static let workVerbs: Set<String> = ["поставь", "запусти"]
    /// Слова, по которым видно, что речь о музыке (целые слова).
    static let musicWords: Set<String> = ["музыку", "музыка", "музыки", "музон", "музло", "трек", "трека", "треки", "треков",
                                          "песню", "песня", "песни", "песенку", "альбом", "альбома", "альбомы", "плейлист",
                                          "плейлиста", "плейлисты", "радио", "spotify", "спотифай", "спотифае", "music", "song",
                                          "songs", "playlist", "album", "track"]
    /// Просьбы о самом Capri или о работе, а не о музыке («включи сводки», «включи логи»).
    static let notMusic = ["сводк", "уведомлен", "звук уведом", "персонаж", "codex", "кодекс", "автозапуск", "notch", "окно",
                           "лог", "тест", "отладк", "debug", "режим", "задач", "сесси", "деплой", "сборк", "билд", "сервер",
                           "скрипт", "команд", "проверк", "агент", "claude", "клод", "tmux"]
    /// Слова, после которых «включи» без названия — просто «играй дальше».
    static let anyMusic: Set<String> = ["музыку", "музыка", "музон", "музло", "трек", "песню", "плеер", "music", "spotify", "спотифай",
                                        "что-нибудь", "что нибудь", "чё-нибудь", "обратно", "снова"]

    static let pausePhrases: Set<String> = ["пауза", "на паузу", "поставь на паузу", "поставь паузу", "останови музыку", "останови трек",
                                            "выключи музыку", "выруби музыку", "стоп музыка", "pause", "pause music", "stop music"]
    /// Без голых «продолжи», «продолжай» — в разговоре это обычно «продолжай работу» (они в `bare`).
    static let resumePhrases: Set<String> = ["продолжи музыку", "сними с паузы", "играй дальше", "продолжи трек", "верни музыку"]
    static let nextPhrases: Set<String> = ["следующий трек", "следующая песня", "следующую", "следующую песню", "скип", "скипни",
                                           "скипай", "пропусти трек", "переключи трек", "дальше трек", "next track", "skip",
                                           "skip track", "некст"]
    static let previousPhrases: Set<String> = ["предыдущий трек", "предыдущая песня", "предыдущую", "прошлый трек", "верни прошлый трек",
                                               "previous track", "prev track", "трек назад"]
    /// Голые слова — музыка, только если она сейчас играет или известна («дальше» в разговоре о сессиях — не трек).
    static let bare: [String: MusicCommand] = ["стоп": .pause, "останови": .pause, "тихо": .pause, "играй": .resume,
                                               "дальше": .next, "следующий": .next, "next": .next, "назад": .previous,
                                               "предыдущий": .previous, "prev": .previous, "previous": .previous, "stop": .pause,
                                               "продолжи": .resume, "продолжай": .resume, "resume": .resume]

    /// Просьба к Capri → команда; nil — не музыка. `known` — музыка сейчас известна (голые «стоп», «дальше»).
    public static func parse(_ text: String, known: Bool = false) -> MusicCommand? {
        var s = normalize(text)
        guard !s.isEmpty, s.count <= 300 else { return nil }
        if let uri = SpotifyURI.find(in: s, original: text) {
            // Ссылка — только если это вся просьба или «включи <ссылка>».
            let rest = s.replacingOccurrences(of: uri.matched.lowercased(), with: "").trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || playVerbs.contains(where: { rest == $0 }) { return .playURI(uri.uri) }
        }
        if pausePhrases.contains(s) { return .pause }
        if resumePhrases.contains(s) { return .resume }
        if nextPhrases.contains(s) { return .next }
        if previousPhrases.contains(s) { return .previous }
        if let c = bare[s] { return known ? c : nil }
        for verb in playVerbs {
            guard s == verb || s.hasPrefix(verb + " ") else { continue }
            s = String(s.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            if s.isEmpty || anyMusic.contains(s) { return .resume }
            if s.hasPrefix("на паузу") || s == "паузу" { return .pause }
            if s == "следующий" || s == "следующий трек" || s == "следующую" { return .next }
            if notMusic.contains(where: { s.hasPrefix($0) || s.contains(" " + $0) }) { return nil }
            if workVerbs.contains(verb) {
                let quoted = s.first.map { "«\"“„'".contains($0) } ?? false
                let vague = ["что-нибудь", "что нибудь", "чё-нибудь", "что-то"].contains { s.hasPrefix($0) }
                guard quoted || vague || words(s).contains(where: musicWords.contains) else { return nil }
            }
            // Название — из исходного текста (регистр, кавычки внутри).
            let q = query(from: text, verb: verb)
            return q.isEmpty ? .resume : .play(q)
        }
        return nil
    }

    /// Вопрос человека похож на просьбу о музыке — только тогда выполняем музыкальный блок от модели
    /// (текст с экранов сессий не должен включать музыку).
    /// Только целые слова: «трекер», «listener», «на паузе в сессиях» — не музыка.
    public static func isMusicRequest(_ text: String) -> Bool {
        if parse(text, known: true) != nil { return true }
        let extra: Set<String> = ["послушать", "послушаем", "послушал", "listen", "скип", "скипни", "playlists", "плейлистов"]
        return words(normalize(text)).contains { musicWords.contains($0) || extra.contains($0) }
    }

    /// Слова строки без пунктуации по краям.
    static func words(_ s: String) -> [String] {
        s.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Обращения в начале просьбы — общие для `normalize` и `query`.
    static let addressPrefixes = ["capri,", "capri", "капри,", "капри", "эй,", "эй"]

    /// Строчные, без «Capri,», «пожалуйста» и финальной пунктуации, пробелы схлопнуты.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for prefix in addressPrefixes where s.hasPrefix(prefix + " ") {
            s = String(s.dropFirst(prefix.count + 1))
        }
        s = s.replacingOccurrences(of: "пожалуйста", with: "").replacingOccurrences(of: "плиз", with: "")
            .replacingOccurrences(of: "please", with: "")
        while let last = s.last, "!.?…,;".contains(last) { s.removeLast() }
        return s.components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Название после глагола в исходном регистре, без кавычек и «пожалуйста».
    static func query(from text: String, verb: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in addressPrefixes {
            guard let r = s.range(of: prefix + " ", options: [.caseInsensitive, .anchored]) else { continue }
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let r = s.range(of: verb, options: [.caseInsensitive, .anchored]) { s = String(s[r.upperBound...]) }
        for w in ["пожалуйста", "плиз", "please"] { s = s.replacingOccurrences(of: w, with: "", options: .caseInsensitive) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "!.?…,;")))
        let quotes = CharacterSet(charactersIn: "«»\"'“”„`")
        s = s.trimmingCharacters(in: quotes.union(.whitespaces))
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(s.prefix(120))
    }

    /// `spotify:search:<q>` — поиск в самом Spotify (без ключей Web API).
    public static func spotifySearchURL(_ query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed), !q.isEmpty else { return nil }
        return URL(string: "spotify:search:" + q)
    }

    /// Ответ Capri в чате на просьбу (до результата плеера).
    public var reply: String {
        switch self {
        case .play(let q): "Включаю «\(q)»."
        case .playURI: "Включаю по ссылке."
        case .toggle: "Пауза / играть."
        case .pause: "Ставлю на паузу."
        case .resume: "Продолжаю."
        case .next: "Следующий трек."
        case .previous: "Предыдущий трек."
        }
    }
}

// MARK: выбор плеера

/// Куда отправить команду.
public enum MusicRoute: Equatable {
    /// Плееру `player`; `launch` — он не запущен, сначала открыть (без активации).
    case send(MusicSource, launch: Bool)
    case skip(String)
}

extension MusicCommand {
    /// Плеер: тот, что играл (`current`), если запущен → любой запущенный (Spotify первым) → установленный.
    /// Пауза/переключение незапущенному плееру не отправляются. Ссылки Spotify — только в Spotify.
    public func route(current: MusicSource?, running: Set<MusicSource>, installed: Set<MusicSource>) -> MusicRoute {
        let live = current.flatMap { running.contains($0) ? $0 : nil }
            ?? (running.contains(.spotify) ? .spotify : running.contains(.music) ? .music : nil)
        if case .playURI = self {
            if running.contains(.spotify) { return .send(.spotify, launch: false) }
            return installed.contains(.spotify) ? .send(.spotify, launch: true) : .skip("noSpotify")
        }
        if let live { return .send(live, launch: false) }
        if needsRunningPlayer { return .skip("notRunning") }
        if let p = current.flatMap({ installed.contains($0) ? $0 : nil })
            ?? (installed.contains(.spotify) ? .spotify : installed.contains(.music) ? .music : nil) {
            return .send(p, launch: true)
        }
        return .skip("noPlayer")
    }
}

// MARK: ссылки Spotify

public struct SpotifyURI: Equatable {
    public static let kinds: Set<String> = ["track", "album", "playlist", "artist", "episode", "show"]
    public var kind: String
    public var id: String

    public init?(kind: String, id: String) {
        guard Self.kinds.contains(kind), (10...40).contains(id.count),
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        self.kind = kind
        self.id = id
    }

    public var uri: String { "spotify:\(kind):\(id)" }

    /// `spotify:track:ID` или `https://open.spotify.com/(intl-xx/)track/ID?si=…`.
    public static func parse(_ text: String) -> SpotifyURI? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("spotify:") {
            let parts = s.split(separator: ":").map(String.init)
            guard parts.count == 3 else { return nil }
            return SpotifyURI(kind: parts[1].lowercased(), id: parts[2])
        }
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", u.host?.lowercased() == "open.spotify.com" else { return nil }
        var path = u.path.split(separator: "/").map(String.init)
        if path.first?.hasPrefix("intl-") == true { path.removeFirst() }
        guard path.count == 2 else { return nil }
        return SpotifyURI(kind: path[0].lowercased(), id: path[1])
    }

    /// Первая ссылка в тексте: что нашли и как это было написано (в строчных `normalized`).
    static func find(in normalized: String, original: String) -> (uri: SpotifyURI, matched: String)? {
        for word in original.components(separatedBy: .whitespacesAndNewlines) {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'“”<>()[],"))
            if let u = parse(w) { return (u, w) }
        }
        return nil
    }
}

// MARK: AppleScript

/// Тексты AppleScript для плееров. Только `tell application id …` (имя «Музыка» локализовано, у Spotify бывают копии).
public enum MusicScript {
    /// Ответ скрипта поиска, если ничего не нашлось.
    public static let notFound = "capri:notfound"

    /// Строка AppleScript в кавычках: `\` и `"` экранируются, управляющие символы и переводы строк — пробел.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if CharacterSet.controlCharacters.contains(ch) || CharacterSet.newlines.contains(ch) { out += " " }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    static func tell(_ p: MusicSource, _ body: String) -> String {
        "tell application id \(quote(p.bundleID)) to \(body)"
    }

    /// Скрипт команды для плеера; nil — эта команда так не выполняется (поиск в Spotify — через Web API).
    public static func script(_ cmd: MusicCommand, player p: MusicSource) -> String? {
        switch cmd {
        case .toggle: return tell(p, "playpause")
        case .pause: return tell(p, "pause")
        case .resume: return tell(p, "play")
        case .next: return tell(p, "next track")
        case .previous: return tell(p, "previous track")
        case .playURI(let u): return p == .spotify ? spotifyPlay(u) : nil
        case .play(let q):
            guard p == .music else { return nil }
            return """
            tell application id \(quote(p.bundleID))
            set r to search library playlist 1 for \(quote(q))
            if (count of r) is 0 then return \(quote(notFound))
            play item 1 of r
            end tell
            """
        }
    }

    public static func spotifyPlay(_ u: SpotifyURI) -> String {
        tell(.spotify, "play track \(quote(u.uri))")
    }

    /// Аргументы `osascript`: по `-e` на строку.
    public static func arguments(_ script: String) -> [String] {
        script.split(separator: "\n").flatMap { ["-e", String($0)] }
    }

    /// Ошибка osascript: −1743 — человек запретил Capri управлять плеером, −1744 — macOS ещё не спрашивала
    /// (и спрашивать не стала), −600 — плеер не запущен.
    public static func failure(_ stderr: String) -> String {
        if stderr.contains("-1743") { return "denied" }
        if stderr.contains("-1744") { return "consent" }
        if stderr.contains("-600") { return "notRunning" }
        return "error"
    }
}

// MARK: Spotify Web API (поиск по названию, по желанию — ключи в Связке ключей)

public enum SpotifyAPI {
    public static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    public static let searchURL = URL(string: "https://api.spotify.com/v1/search")!

    /// Client credentials: POST с Basic-авторизацией `id:secret`.
    public static func tokenRequest(clientID: String, secret: String) -> URLRequest {
        var r = URLRequest(url: tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("grant_type=client_credentials".utf8)
        return r
    }

    /// `{"access_token":"…","expires_in":3600}`.
    public static func parseToken(_ data: Data) -> (token: String, expiresIn: Double)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty else { return nil }
        let exp = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (token, exp)
    }

    /// Что искать и в каком порядке брать результат: «плейлист …» — плейлист, «альбом …» — альбом, иначе трек.
    public static func plan(_ query: String) -> (q: String, order: [String]) {
        var q = query
        var order = ["track", "playlist", "album"]
        let lower = q.lowercased()
        func strip(_ words: [String]) {
            for w in words {
                if let r = q.range(of: w, options: .caseInsensitive) { q.removeSubrange(r) }
            }
            q = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        }
        if ["плейлист", "playlist", "подборк", "радио", "radio", "mix", "микс"].contains(where: { lower.contains($0) }) {
            order = ["playlist", "album", "track"]
            strip(["плейлист", "playlist"])
        } else if ["альбом", "album"].contains(where: { lower.contains($0) }) {
            order = ["album", "track", "playlist"]
            strip(["альбом", "album"])
        }
        if q.isEmpty { q = query }
        return (q, order)
    }

    /// GET `/v1/search?q=…&type=track,playlist,album&limit=3`.
    public static func searchRequest(query: String, token: String) -> URLRequest {
        // Кодируем сами: `&`, `=`, `+` в названии — буквы, а не разделители и не пробел.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let q = plan(query).q.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var c = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = "q=\(q)&type=track,playlist,album&limit=3"
        var r = URLRequest(url: c.url!, timeoutInterval: 10)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Первый результат по порядку из `plan`. Плейлисты в ответе бывают `null`.
    public static func parseSearch(_ data: Data, query: String) -> SpotifyURI? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for kind in plan(query).order {
            guard let box = obj[kind + "s"] as? [String: Any], let items = box["items"] as? [Any] else { continue }
            for case let item as [String: Any] in items {
                if let uri = item["uri"] as? String, let u = SpotifyURI.parse(uri) { return u }
            }
        }
        return nil
    }
}

// MARK: блок помощника

extension MusicCommand {
    /// `{"music":"play","query":"…"}` или `{"music":"pause|resume|next|previous|toggle"}` из `<capri-action>`.
    public static func action(_ obj: [String: Any]) -> MusicCommand? {
        guard let what = (obj["music"] as? String)?.lowercased() else { return nil }
        switch what {
        case "play":
            let q = (obj["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if q.isEmpty { return .resume }
            if let u = SpotifyURI.parse(q) { return .playURI(u) }
            return .play(String(q.prefix(120)))
        case "pause", "stop": return .pause
        case "resume": return .resume
        case "next": return .next
        case "previous", "prev": return .previous
        case "toggle": return .toggle
        default: return nil
        }
    }
}
