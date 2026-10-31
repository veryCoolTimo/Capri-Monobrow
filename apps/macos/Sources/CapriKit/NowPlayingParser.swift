import Foundation

/// Что играет в Spotify или Музыке — из их распределённых уведомлений (без разрешений macOS).
/// Уведомления приходят только при изменении: до первого события Capri ничего не знает.
public enum MusicSource: String, CaseIterable, Codable {
    case spotify, music

    /// Имя распределённого уведомления плеера.
    public var notification: String {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }

    public var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }
}

public struct Track: Equatable, Codable {
    public enum Kind: String, Codable { case song, ad, podcast }

    public var source: MusicSource
    public var id: String
    public var name: String
    public var artist: String
    public var album: String
    /// Длительность (с), 0 — неизвестна.
    public var duration: Double
    public var kind: Kind

    public init(source: MusicSource, id: String = "", name: String, artist: String, album: String = "", duration: Double = 0, kind: Kind = .song) {
        self.source = source; self.id = id; self.name = name; self.artist = artist; self.album = album
        self.duration = duration; self.kind = kind
    }

    /// Строка для notch: «Artist — Track», реклама и подкасты — словом.
    public var line: String {
        switch kind {
        case .ad: return "реклама"
        case .podcast: return name.isEmpty ? "подкаст" : "подкаст · \(name)"
        case .song: return artist.isEmpty ? name : name.isEmpty ? artist : "\(artist) — \(name)"
        }
    }

    /// Тот же трек (смена — новый id или название).
    public func same(_ o: Track) -> Bool {
        source == o.source && (id.isEmpty || o.id.isEmpty ? name == o.name && artist == o.artist : id == o.id)
    }
}

public enum NowPlayingEvent: Equatable {
    case playing(Track)
    case paused(Track)
    case stopped
}

public enum NowPlayingParser {
    /// Разбор `userInfo` уведомления плеера. Пустой или непонятный — `.stopped`.
    public static func parse(source: MusicSource, userInfo: [AnyHashable: Any]) -> NowPlayingEvent {
        func string(_ k: String) -> String {
            (userInfo[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func number(_ k: String) -> Double? {
            switch userInfo[k] {
            case let n as NSNumber: return n.doubleValue
            case let d as Double: return d
            case let i as Int: return Double(i)
            case let s as String: return Double(s)
            default: return nil
            }
        }
        let state = string("Player State").lowercased()
        guard !state.isEmpty, state != "stopped" else { return .stopped }
        let id: String
        var duration: Double
        switch source {
        case .spotify:
            id = string("Track ID")
            duration = number("Duration") ?? 0
        case .music:
            id = (userInfo["PersistentID"] ?? userInfo["Persistent ID"]).map { "\($0)" } ?? ""
            duration = number("Total Time") ?? 0
        }
        // Spotify отдаёт мс, Музыка — мс в «Total Time»; больше 10 ч в секундах не бывает.
        if duration > 36000 { duration /= 1000 }
        var kind = Track.Kind.song
        let artist = string("Artist")
        if id.hasPrefix("spotify:ad:") || (source == .spotify && artist.isEmpty && string("Name").isEmpty) { kind = .ad }
        else if id.hasPrefix("spotify:episode:") || id.hasPrefix("spotify:local:episode") { kind = .podcast }
        let track = Track(source: source, id: id, name: string("Name"), artist: artist, album: string("Album"),
                          duration: duration, kind: kind)
        switch state {
        case "playing": return .playing(track)
        case "paused": return .paused(track)
        default: return .stopped
        }
    }
}

/// Что играет и что из этого следует для персонажа. Чистая: время — входом.
public struct NowPlayingState: Equatable {
    public enum Change: Equatable {
        /// Начал играть после паузы/тишины; `afterSilence` — тишина была ≥ 10 мин.
        case started(afterSilence: Bool)
        /// Сменился трек во время игры.
        case changed
        case paused
        case stopped
        case none
    }

    public static let longSilence = 10.0 * 60
    /// После паузы строка ♪ ещё видна столько секунд.
    public static let pauseGrace = 5.0
    /// Строка трека в раскрытом notch видна столько секунд после старта или смены трека (потом — по наведению).
    public static let revealSeconds = 4.0

    public private(set) var track: Track?
    public private(set) var playing = false
    /// С какого момента тишина (nil — играет).
    public private(set) var silentSince: Double?
    public private(set) var changedAt: Double?
    /// До какого момента строку трека показывать без наведения (старт или смена трека); nil — не показывать.
    public private(set) var revealUntil: Double?

    /// `now` — запуск Capri: до первого события считаем, что тишина с запуска.
    public init(now: Double) { silentSince = now }

    public mutating func apply(_ e: NowPlayingEvent, now: Double) -> Change {
        switch e {
        case .playing(let t):
            let wasPlaying = playing, old = track
            track = t; playing = true; changedAt = now
            if !wasPlaying {
                let silence = silentSince.map { now - $0 } ?? .infinity
                silentSince = nil
                revealUntil = now + Self.revealSeconds
                return .started(afterSilence: silence >= Self.longSilence)
            }
            if old.map({ $0.same(t) }) == true { return .none }
            revealUntil = now + Self.revealSeconds
            return .changed
        case .paused(let t):
            track = t
            guard playing else { return .none }
            playing = false; silentSince = now; changedAt = now
            return .paused
        case .stopped:
            let was = playing || track != nil
            if playing { silentSince = now }
            playing = false; track = nil; changedAt = now; revealUntil = nil
            return was ? .stopped : .none
        }
    }

    /// Строку трека показывать сама по себе (без наведения): прошло меньше 4 с после старта или смены трека.
    public func revealed(now: Double) -> Bool {
        guard let revealUntil, track != nil else { return false }
        return now < revealUntil
    }

    /// Трек для строки ♪: играет или на паузе меньше 5 с.
    public func display(now: Double) -> Track? {
        guard let track else { return nil }
        if playing { return track }
        if let s = silentSince, now - s < Self.pauseGrace { return track }
        return nil
    }
}
