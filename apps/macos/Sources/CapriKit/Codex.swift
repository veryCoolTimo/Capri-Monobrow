import Foundation

// Codex для Capri: `codex app-server` по stdio JSON-RPC (одна строка — одно сообщение).
// Протокол проверен в спайке Этапа 0 (docs/VALIDATION.md) и по `codex app-server generate-json-schema`.
// Сырой auth.json не читаем: аккаунт, вход и лимиты — только через API сервера.

/// Входящее сообщение app-server.
public enum CodexMessage: Equatable {
    case response(id: Int, result: JSONValue?, error: String?)
    case notification(method: String, params: JSONValue)
    /// Запрос сервера к клиенту (одобрение команды и т.п.).
    case request(id: JSONValue, method: String, params: JSONValue)

    public static func decode(_ line: String) -> CodexMessage? {
        guard let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let o) = v else { return nil }
        let method = o["method"]?.string
        switch (o["id"], method) {
        case let (id?, m?): return .request(id: id, method: m, params: o["params"] ?? .null)
        case let (.number(n)?, nil):
            let err: String? = o["error"].map { e in e["message"]?.string ?? "ошибка app-server" }
            return .response(id: Int(n), result: o["result"], error: err)
        case let (nil, m?): return .notification(method: m, params: o["params"] ?? .null)
        default: return nil
        }
    }

    /// Запрос клиента. `id == nil` — уведомление.
    public static func encode(method: String, params: JSONValue?, id: Int?) -> Data {
        var o: [String: JSONValue] = ["method": .string(method)]
        if let params { o["params"] = params }
        if let id { o["id"] = .number(Double(id)) }
        var d = (try? JSONEncoder().encode(JSONValue.object(o))) ?? Data()
        d.append(0x0A)
        return d
    }

    public static func encodeError(id: JSONValue, code: Int, message: String) -> Data {
        let err: JSONValue = .object(["code": .number(Double(code)), "message": .string(message)])
        var d = (try? JSONEncoder().encode(JSONValue.object(["id": id, "error": err]))) ?? Data()
        d.append(0x0A)
        return d
    }

    public static func encodeResponse(id: JSONValue, result: JSONValue) -> Data {
        var d = (try? JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))) ?? Data()
        d.append(0x0A)
        return d
    }
}

/// Аккаунт Codex (`account/read`). Email показываем только владельцу на его Маке — в журналы не пишем.
public struct CodexAccount: Equatable {
    public var type: String
    public var email: String?
    public var plan: String?

    public static func parse(_ result: JSONValue?) -> CodexAccount? {
        guard let a = result?["account"], case .object = a, let type = a["type"]?.string else { return nil }
        return CodexAccount(type: type, email: a["email"]?.string, plan: a["planType"]?.string)
    }
}

/// Лимиты аккаунта: окно 5 ч и неделя.
public struct CodexLimits: Equatable {
    public struct Window: Equatable {
        public var usedPercent: Double
        public var windowMinutes: Int
        public var resetsAt: Double?
    }
    public var primary: Window?
    public var secondary: Window?
    public var reached: Bool

    /// Из ответа `account/rateLimits/read` (`{rateLimits:{…}}`) или уведомления `account/rateLimits/updated`.
    public static func parse(_ v: JSONValue?) -> CodexLimits? {
        guard let v else { return nil }
        let r = v["rateLimits"] ?? v
        func window(_ w: JSONValue?) -> Window? {
            guard let w, case .number(let used)? = w["usedPercent"] else { return nil }
            var mins = 0
            if case .number(let m)? = w["windowDurationMins"] { mins = Int(m) }
            var reset: Double?
            if case .number(let t)? = w["resetsAt"] { reset = t }
            return Window(usedPercent: used, windowMinutes: mins, resetsAt: reset)
        }
        let p = window(r["primary"]), s = window(r["secondary"])
        guard p != nil || s != nil else { return nil }
        let reachedType = r["rateLimitReachedType"]
        let reached = (reachedType != nil && reachedType != .null) || r["spendControlReached"]?.bool == true
        return CodexLimits(primary: p, secondary: s, reached: reached)
    }
}

/// Вырезание секретов из текста перед отправкой в Codex: экран сессии может содержать токены, ключи, пароли.
public enum Redactor {
    static let rules: [(NSRegularExpression, String)] = [
        // Приватные ключи целиком.
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[ключ]"),
        // Известные форматы токенов.
        (#"\b(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#, "[токен]"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "[токен]"),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "[токен]"),
        (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, "[токен]"),
        (#"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#, "[ключ]"),
        (#"\bAIza[0-9A-Za-z_\-]{30,}"#, "[ключ]"),
        (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "[jwt]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{12,}=*"#, "Bearer [токен]"),
        // Логин:пароль в URL.
        (#"(?i)([a-z][a-z0-9+.\-]*://)[^\s:/@]+:[^\s@/]+@"#, "$1[логин]@"),
        // key=value / key: value для подозрительных имён.
        (#"(?i)\b([A-Z0-9_]*(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization)[A-Z0-9_]*)(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)"#, "$1$3[скрыто]"),
        // Пароль флагом командной строки: --password X, --token X, -p'X'.
        (#"(?i)(--?(password|passwd|pass|token|secret|api-key)[= ])("[^"]*"|'[^']*'|\S+)"#, "$1[скрыто]"),
        (#"(\s-p)('[^']+'|"[^"]+"|\S{3,})"#, "$1[скрыто]"),
        // Cookie, ключи Stripe и боты Telegram, строки .netrc.
        (#"(?i)\b(set-)?cookie:\s*[^\n]+"#, "$1Cookie: [скрыто]"),
        (#"\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{10,}"#, "[ключ]"),
        (#"\b\d{8,10}:[A-Za-z0-9_\-]{35}\b"#, "[токен]"),
        (#"(?i)\b(machine\s+\S+\s+login\s+\S+\s+password)\s+\S+"#, "$1 [скрыто]"),
        // Email.
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
        // Длинные hex/base64-строки (хеши, ключи): 32+ hex или 40+ символов с буквами и цифрами.
        // Без «/», чтобы не резать пути к файлам.
        (#"\b[A-Fa-f0-9]{32,}\b"#, "[hex]"),
        // Нужны и заглавные, и строчные, и цифры — так не режутся длинные имена-kebab вроде capri-test-session-2.
        (#"\b(?=[A-Za-z0-9+_\-]*[0-9])(?=[A-Za-z0-9+_\-]*[a-z])(?=[A-Za-z0-9+_\-]*[A-Z])[A-Za-z0-9+_\-]{40,}={0,2}"#, "[blob]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        var s = text
        for (re, template) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}

/// Тексты запросов к Codex. Всё, что приходит с экранов и из хуков, проходит через `Redactor`.
public enum CodexPrompts {
    /// Инструкции служебного треда: коротко, по-русски, ничего не выполнять.
    public static let developer = """
    Ты — помощник в приложении Capri, которое показывает человеку сессии Claude Code и Codex на его машинах. \
    Ты только читаешь присланный текст и отвечаешь. Не запускай команды, не читай и не меняй файлы. \
    Отвечай по-русски, коротко и по делу. Секреты в тексте заменены метками вида [токен] — не пытайся их восстановить.
    """

    /// Сколько нижних строк экрана отдаём (без пустых).
    public static let screenTail = 30

    static func screenText(_ lines: [String], tail: Int = screenTail) -> String {
        let plain = unwrap(ScreenText.lines(lines).map(\.plain)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Redactor.redact(plain.suffix(tail).joined(separator: "\n"))
    }

    /// Склеить строки, перенесённые терминалом: строка во всю ширину панели продолжается следующей.
    /// Иначе длинный токен приходит кусками короче порогов `Redactor`. Ширину берём как самую длинную строку.
    static func unwrap(_ lines: [String]) -> [String] {
        let width = lines.map(\.count).max() ?? 0
        guard width >= 40 else { return lines }
        var out: [String] = []
        var carry = ""
        for line in lines {
            carry += line
            if line.count < width { out.append(carry); carry = "" }
        }
        if !carry.isEmpty { out.append(carry) }
        return out
    }

    /// «votek2 (папка votek)» — имя tmux-сессии и проект, если он другой.
    static func name(_ s: Session) -> String {
        s.title == s.project ? s.title : "\(s.title) (папка \(s.project))"
    }

    /// `label` — как назвать сессию (по умолчанию `name(s)`); без префикса «Сессия: » — для списков помощника.
    static func describe(_ s: Session, label: String? = nil, prefix: Bool = true) -> String {
        var out = (prefix ? "Сессия: " : "") + "\(label ?? name(s)) · хост \(s.key.host) · агент \(s.key.agent.rawValue) · статус \(s.status.rawValue)"
        if let r = s.request {
            out += "\nЗапрос (\(r.kind == .reply ? "вопрос текстом в конце ответа" : r.kind.rawValue)\(r.tool.map { ", \($0)" } ?? "")): \(Redactor.redact(r.summary))"
            if !r.options.isEmpty { out += "\nВарианты: " + r.choices.map { "\($0.index). \(Redactor.redact($0.label))" }.joined(separator: "; ") }
        }
        if let m = s.lastMessage, s.status != .running {
            out += "\nПоследнее сообщение агента: \(String(Redactor.redact(m).prefix(600)))"
        }
        return out
    }

    /// Однострочная сводка «что спрашивает сессия» для notch.
    public static func summary(_ s: Session, screen: [String]?) -> String {
        var p = """
        Сессия ждёт ответа человека. Одной строкой до 90 символов скажи, что именно она спрашивает или \
        какое действие просит разрешить и чем оно рискованно, если рискованно. Без вступлений и кавычек.

        \(describe(s))
        """
        if let screen, !screen.isEmpty { p += "\n\nНиз экрана сессии:\n```\n\(screenText(screen))\n```" }
        return p
    }

    /// Черновик ответа для поля ввода. Отправляет только человек.
    public static func draft(_ s: Session, screen: [String]?) -> String {
        var p = """
        Предложи черновик ответа, который человек может отправить этой сессии в строку ввода. \
        Только текст ответа, без пояснений и кавычек, до 3 строк. Если сессия ждёт выбора варианта — \
        назови номер и почему.

        \(describe(s))
        """
        if let screen, !screen.isEmpty { p += "\n\nНиз экрана сессии:\n```\n\(screenText(screen))\n```" }
        return p
    }

    /// Сводка из ответа модели: первая непустая строка, без кавычек и маркеров, не длиннее 120 символов.
    public static func cleanSummary(_ text: String) -> String? {
        guard var line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”'` "))
        if line.count > 120 { line = String(line.prefix(119)) + "…" }
        return line.isEmpty ? nil : line
    }
}

/// Какой `codex` запускать. Homebrew-версия — node-скрипт: GUI-приложению нужен PATH с /opt/homebrew/bin.
public enum CodexBinary {
    public static let pathForChild = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public static func candidates(home: String) -> [String] {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
         "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
    }

    /// Что выключаем в служебном app-server. Треды Capri получают текст с чужих экранов (в т.ч. с прода):
    /// у модели не должно быть ни одного инструмента — ни shell (read-only песочница всё равно читает весь диск),
    /// ни веба, ни браузера, ни MCP. Пользовательские хуки тоже не нужны (лишние события в журнале Capri).
    /// Через `-c features.X=false`, а не `--disable`: незнакомый старой версии ключ codex молча пропускает.
    public static let disabledFeatures = ["hooks", "apps", "shell_tool", "unified_exec", "browser_use", "browser_use_external",
                                          "computer_use", "image_generation", "in_app_browser", "view_image", "multi_agent",
                                          "plugins", "goals", "tool_suggest", "memories", "code_mode_host"]

    public static var serverArgs: [String] {
        ["app-server"] + disabledFeatures.flatMap { ["-c", "features.\($0)=false"] }
            + ["-c", "mcp_servers={}", "-c", #"web_search="disabled""#]
    }

    public static func find(override: String?, home: String, exists: (String) -> Bool) -> String? {
        if let o = override, !o.isEmpty { return exists(o) ? o : nil }
        return candidates(home: home).first(where: exists)
    }
}

/// Сбор ответа одного хода из уведомлений app-server.
public struct CodexTurnCollector {
    public enum Outcome: Equatable {
        case completed(String)
        case failed(String)
    }

    public let threadId: String
    /// Текст по мере генерации (из `item/agentMessage/delta`).
    public private(set) var streamed = ""
    private var final: String?
    private var lastMessage: String?

    public init(threadId: String) { self.threadId = threadId }

    /// Применить уведомление. Возвращает итог, когда ход закончился.
    public mutating func apply(method: String, params: JSONValue) -> Outcome? {
        guard params["threadId"]?.string == threadId else { return nil }
        switch method {
        case "item/started":
            // Инструменты выключены; если модель всё же что-то вызвала — ход прерываем, а не ждём.
            if let type = params["item"]?["type"]?.string, !Self.allowedItems.contains(type) {
                return .failed("Codex попытался вызвать инструмент (\(type)) — ход прерван")
            }
            // Новое сообщение агента — поток начинается заново, а не дописывается к предыдущему.
            if params["item"]?["type"]?.string == "agentMessage" { streamed = "" }
        case "item/agentMessage/delta":
            streamed += params["delta"]?.string ?? ""
        case "item/completed":
            let item = params["item"]
            if item?["type"]?.string == "agentMessage", let text = item?["text"]?.string {
                lastMessage = text
                if item?["phase"]?.string == "final_answer" { final = text }
                streamed = text
            }
        case "error":
            if params["willRetry"]?.bool != true {
                return .failed(params["error"]?["message"]?.string ?? "ошибка хода")
            }
        case "turn/completed":
            let turn = params["turn"]
            if turn?["status"]?.string == "failed" {
                return .failed(turn?["error"]?["message"]?.string ?? "ход не удался")
            }
            if let text = final ?? lastMessage ?? Self.agentText(turn?["items"]) { return .completed(text) }
            return .failed(turn?["status"]?.string == "interrupted" ? "ход прерван" : "пустой ответ")
        default:
            break
        }
        return nil
    }

    /// Что может появиться в ходе Capri. Всё остальное — вызов инструмента.
    static let allowedItems: Set<String> = ["userMessage", "agentMessage", "reasoning", "plan"]

    static func agentText(_ items: JSONValue?) -> String? {
        items?.array?.last(where: { $0["type"]?.string == "agentMessage" })?["text"]?.string
    }
}

/// Модель для служебных ходов: по умолчанию из `model/list`, усилие — самое низкое из поддерживаемых.
public struct CodexModel: Equatable {
    public var id: String
    public var effort: String?

    public static func pick(_ result: JSONValue?) -> CodexModel? {
        guard let data = result?["data"]?.array, !data.isEmpty else { return nil }
        let m = data.first { $0["isDefault"]?.bool == true } ?? data[0]
        guard let id = m["model"]?.string ?? m["id"]?.string else { return nil }
        let efforts = m["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string } ?? []
        let effort = ["minimal", "low", "medium"].first { efforts.contains($0) }
        return CodexModel(id: id, effort: effort)
    }
}

extension Session {
    /// Отпечаток текущего запроса: сводка Codex действует, пока он не изменился.
    public var requestFingerprint: String {
        "\(key)|\(request?.summary ?? "")|\(request?.options.joined(separator: "|") ?? "")"
    }
}
