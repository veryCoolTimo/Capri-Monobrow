import Foundation

/// Что Capri видит в сессии, за которой смотрит из терминала. `tail` — последние строки экрана; nil — хост приватный
/// (`quiz`) или экрана нет: тогда реплики только по статусу. Хвост не логируется и никуда не уходит.
public struct WatchedSession: Equatable {
    public var name: String
    public var status: SessionStatus
    /// С какого момента в этом статусе (с 1970).
    public var since: Double
    public var tail: [String]?

    public init(name: String, status: SessionStatus, since: Double, tail: [String]? = nil) {
        self.name = name; self.status = status; self.since = since; self.tail = tail
    }
}

/// Реплики Capri в терминале — всегда про то, что правда происходит в сессии: сколько работает, что видно в хвосте
/// экрана (тесты, ошибка, коммит…), чем кончилось. Без повторов за сцену; короткие (пузырь у угла окна).
public enum SessionRemark {
    public static let maxChars = 34
    /// Имя длиннее — без имени.
    public static let maxName = 12

    /// Что делать сцене после реплики.
    public enum Mood: String, Equatable {
        /// Сказала и смотрит дальше.
        case say
        /// Злорадствует (ухмылка + дрожь) и уходит в notch.
        case gloat
        /// Просто уходит.
        case leave
    }

    public struct Remark: Equatable {
        public var text: String?
        public var mood: Mood
        public init(_ text: String?, _ mood: Mood = .say) { self.text = text; self.mood = mood }
    }

    /// Что видно в хвосте экрана. Порядок — приоритет (упало важнее, чем «тесты»).
    public enum Keyword: String, CaseIterable, Equatable {
        case failed, error, passed, commit, push, test, build, install
    }

    /// Слова (нижний регистр) для каждого вида. Ищем в последних строках экрана.
    static let words: [(Keyword, [String])] = [
        (.failed, ["failed", " failing", "✗", "fatal:", "panic:", "traceback"]),
        (.error, ["error:", "error[", " error ", "exception"]),
        (.passed, ["passed", "tests pass", "all green", "✓ ", "succeeded", "build succeeded", "0 failures"]),
        (.commit, ["git commit", "committed", "[main ", "[master "]),
        (.push, ["git push", "-> main", "-> master"]),
        (.test, ["npm test", "swift test", "pytest", "running tests", "test suite", "xctest", "jest", "vitest", "cargo test"]),
        (.build, ["npm run build", "swift build", "compiling", "building", "cargo build", "make "]),
        (.install, ["npm install", "pip install", "brew install", "installing", "yarn add"]),
    ]

    /// Сколько последних непустых строк смотреть.
    public static let tailLines = 12

    /// Главное слово хвоста (nil — ничего примечательного или хвоста нет).
    public static func keyword(_ tail: [String]?) -> Keyword? {
        guard let tail else { return nil }
        let text = " " + tail.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(tailLines)
            .joined(separator: " \n ").lowercased() + " "
        return words.first { _, list in list.contains { text.contains($0) } }?.0
    }

    /// Имя для реплики (длинное — без имени).
    static func who(_ s: WatchedSession) -> String? {
        let n = s.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n.count > maxName ? nil : n
    }

    static func minutes(_ s: WatchedSession, _ now: Double) -> Int { max(0, Int((now - s.since) / 60)) }

    /// Первая реплика, когда вылезла из терминала. `others` — сколько ещё сессий под этим окном.
    public static func opening(_ s: WatchedSession, others: Int = 0, now: Double, seed: Int = 0) -> String {
        let name = who(s)
        let m = minutes(s, now)
        var options: [String] = []
        if others > 0 { options.append("Тут \(others + 1) сессии. Слежу за всеми.") }
        if let k = keyword(s.tail) { options += keywordLines(k, name: name) }
        if options.isEmpty {
            let n = name ?? "Он"
            switch m {
            case 0: options = ["\(n) только начал. Смотрю.", "\(n) взялся за дело. Я тут."]
            case 1..<10: options = ["\(n) пыхтит \(m) мин. Смотрю.", "\(m) мин работы. Посмотрим."]
            default: options = ["\(n) пыхтит \(m) мин. Долго.", "\(m) мин?! Я бы быстрее."]
            }
        }
        return fit(options[abs(seed) % options.count]) ?? "Смотрю. ^^"
    }

    static func keywordLines(_ k: Keyword, name: String?) -> [String] {
        let n = name.map { "\($0): " } ?? ""
        switch k {
        case .failed: return ["\(n)что-то упало ^^", "Упало! Ха."]
        case .error: return ["\(n)ошибка. Не моя.", "Ошибка в логе. Хи."]
        case .passed: return ["\(n)зелёное. Пока что.", "Зелёное. Скучно ^^"]
        case .commit: return ["\(n)коммитит. Без меня?", "Коммит. Ну наконец."]
        case .push: return ["\(n)пушит. Смело.", "Пушит. Держись, main."]
        case .test: return ["\(n)опять тесты.", "Тесты. Смотрю, как падают."]
        case .build: return ["\(n)собирает. Ну-ну.", "Собирает… Жду."]
        case .install: return ["\(n)качает пакеты.", "Ставит пакеты. Жду."]
        }
    }

    /// Реплика на перемену в сессии (статус или новое слово в хвосте). nil — говорить нечего. `said` — уже
    /// сказанное в этой сцене (не повторять), `lastKeyword` — слово прошлой реплики.
    public static func change(from a: WatchedSession, to b: WatchedSession, now: Double, said: [String] = [],
                              lastKeyword: Keyword? = nil, seed: Int = 0) -> Remark? {
        let name = who(b)
        if a.status != b.status {
            switch b.status {
            case .needsInput:
                // Дальше обычный alert notch — молча домой.
                return Remark(nil, .leave)
            case .idle:
                let m = max(0, Int((now - a.since) / 60))
                let lines = m >= 3 ? ["\(m) мин — и готово. Ну ок ^^", "\(name ?? "Он") закончил. Наконец."]
                    : ["Готово. Без тебя справился ^^", "\(name ?? "Он") закончил. Скукота."]
                return Remark(pick(lines, said, seed), .gloat)
            case .error:
                return Remark(pick(["\(name ?? "Он") упал. Хи-хи.", "Сломался. Не я!"], said, seed), .gloat)
            case .rateLimited:
                return Remark(pick(["Упёрся в лимит. Ха.", "Лимит. Отдыхай, бедный."], said, seed), .gloat)
            case .ended, .unknown:
                return Remark(pick(["\(name ?? "Сессию") закрыли. Пока.", "Всё, ушёл. И я."], said, seed), .leave)
            case .running:
                return Remark(pick(["О, снова за работу.", "\(name ?? "Он") опять пыхтит."], said, seed))
            }
        }
        guard b.status == .running, let k = keyword(b.tail), k != lastKeyword else { return nil }
        guard let text = pick(keywordLines(k, name: name), said, seed) else { return nil }
        return Remark(text)
    }

    /// Долго ничего не происходит — одна реплика про то, сколько уже идёт. nil — уже говорила или нечего.
    public static func nudge(_ s: WatchedSession, now: Double, said: [String] = [], seed: Int = 0) -> String? {
        guard s.status == .running else { return nil }
        let m = minutes(s, now)
        let n = who(s) ?? "Он"
        let lines = m >= 1 ? ["Уже \(m) мин пыхтит.", "\(n) всё думает. \(m) мин."] : ["Думает. Я тоже умею.", "\(n) думает. Молча."]
        return pick(lines, said, seed)
    }

    /// Первая из подходящих (со сдвигом по зерну), которой ещё не было; влезает в пузырь.
    static func pick(_ lines: [String], _ said: [String], _ seed: Int) -> String? {
        let fitted = lines.compactMap(fit)
        guard !fitted.isEmpty else { return nil }
        for k in 0..<fitted.count {
            let s = fitted[(abs(seed) + k) % fitted.count]
            if !said.contains(s) { return s }
        }
        return nil
    }

    /// Влезает ли в пузырь (`maxChars`) и проходит ли тот же валидатор, что реплики «на окне».
    static func fit(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= maxChars && PerchLines.valid(t) ? t : nil
    }
}
