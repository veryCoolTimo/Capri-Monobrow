import Foundation

/// Что видно на экране tmux-панели агента. Это фолбэк к хукам (`confidence: inferred`):
/// отказ в разрешении и Esc у Claude хуков не дают, а сессии без хуков видны только так.
public enum ScreenState: Equatable {
    case running
    /// Диалог разрешения или вопрос с вариантами.
    case dialog(DialogInfo)
    /// Ждёт ввода; `typed` — текст, который человек уже набрал (серая подсказка не считается).
    case idle(typed: String?)
    case unknown
}

public struct DialogInfo: Equatable {
    public enum Kind: String, Equatable { case permission, question }
    public var kind: Kind
    public var title: String?
    public var options: [DialogOption]
}

public struct DialogOption: Equatable {
    public var key: String
    public var label: String
}

/// Строка экрана: видимый текст и признак dim/серого для каждого символа.
struct StyledLine {
    var text: [Character] = []
    var dim: [Bool] = []
    var plain: String { String(text) }
}

public enum ScreenClassifier {
    /// Сколько нижних непустых строк смотрим: диалоги и строка ввода всегда внизу.
    static let tail = 22

    public static func classify(lines: [String], agent: Agent?) -> ScreenState {
        let styled = lines.map(parseANSI)
        var rows = styled.filter { !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty }
        if rows.count > tail { rows = Array(rows.suffix(tail)) }
        guard !rows.isEmpty else { return .unknown }
        let plain = rows.map(\.plain)
        let bottom = plain.suffix(4).joined(separator: "\n").lowercased()

        if let dialog = detectDialog(plain, bottom: bottom) { return .dialog(dialog) }
        // У Codex строка «Working (… esc to interrupt)» стоит над строкой ввода, и очередь сообщений
        // или многострочный черновик сдвигают её выше — смотрим шире, чем 4 строки.
        if plain.suffix(8).joined(separator: "\n").lowercased().contains("esc to interrupt") { return .running }
        if let typed = promptInput(rows, agent: agent) { return .idle(typed: typed.isEmpty ? nil : typed) }
        return .unknown
    }

    static func detectDialog(_ plain: [String], bottom: String) -> DialogInfo? {
        let claudeDialog = bottom.contains("esc to cancel") && plain.contains(where: { isOption($0) })
        // Меню без номеров (доверие к папке при первом запуске): «❯ No, exit / Yes, I trust…».
        let claudeMenu = bottom.contains("enter to confirm") && bottom.contains("esc to cancel")
        let codexDialog = bottom.contains("press enter to confirm or esc to cancel")
        guard claudeDialog || claudeMenu || codexDialog else { return nil }
        let kind: DialogInfo.Kind = bottom.contains("enter to select") ? .question : .permission
        var options = plain.compactMap(option)
        if options.isEmpty { options = menuOptions(plain) }
        let titleMarkers = ["Do you want", "Would you like", "?"]
        let title = plain.last(where: { line in titleMarkers.contains(where: { line.contains($0) }) && !isOption(line) })?
            .trimmingCharacters(in: .whitespaces)
        return DialogInfo(kind: kind, title: title, options: options)
    }

    /// Пункты меню без номеров: строка с курсором `❯` и соседние строки с тем же отступом до подсказки «Enter to confirm».
    static func menuOptions(_ plain: [String]) -> [DialogOption] {
        guard let end = plain.lastIndex(where: { $0.lowercased().contains("enter to confirm") }),
              let cursor = plain[..<end].lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })
        else { return [] }
        func label(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces).drop { $0 == "❯" || $0.isWhitespace }.description
        }
        let indent = { (l: String) in l.prefix { $0 == " " }.count }
        let column = indent(plain[cursor]) + 2          // «❯ » — два символа
        var first = cursor
        while first > 0, indent(plain[first - 1]) == column { first -= 1 }
        var last = cursor
        while last + 1 < end, indent(plain[last + 1]) == column { last += 1 }
        return (first...last).enumerated().map { DialogOption(key: String($0.offset + 1), label: label(plain[$0.element])) }
    }

    static let optionRegex = try! NSRegularExpression(pattern: #"^\s*(?:[❯›>]\s*)?(\d)\.\s+(.+?)\s*$"#)

    static func isOption(_ line: String) -> Bool { option(line) != nil }

    static func option(_ line: String) -> DialogOption? {
        let ns = line as NSString
        guard let m = optionRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return DialogOption(key: ns.substring(with: m.range(at: 1)), label: ns.substring(with: m.range(at: 2)))
    }

    /// Текст в строке ввода без серой подсказки. nil — строки ввода не нашли.
    static func promptInput(_ rows: [StyledLine], agent: Agent?) -> String? {
        let markers: [Character] = agent == .codex ? ["›"] : agent == .claude ? ["❯"] : ["❯", "›"]
        // Строка ввода — последняя строка, начинающаяся с маркера (выше — история с теми же маркерами).
        guard let row = rows.last(where: { r in
            guard let first = r.text.first(where: { !$0.isWhitespace }) else { return false }
            return markers.contains(first)
        }) else { return nil }
        guard let start = row.text.firstIndex(where: { markers.contains($0) }) else { return nil }
        var typed = ""
        for i in row.text.indices where i > start && !row.dim[i] {
            typed.append(row.text[i])
        }
        return typed.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}")))
    }

    /// Разбор SGR: dim (2), серые цвета 90/37 и 256-цветные 240–250 считаем «подсказкой».
    static func parseANSI(_ s: String) -> StyledLine {
        var out = StyledLine()
        var dim = false
        var grey = false
        var it = Array(s.unicodeScalars)[...]
        var pending = String.UnicodeScalarView()
        func flush() {
            for ch in String(pending) { out.text.append(ch); out.dim.append(dim || grey) }
            pending.removeAll()
        }
        while let c = it.popFirst() {
            guard c == "\u{1B}" else { pending.append(c); continue }
            flush()
            guard it.first == "[" else { _ = it.popFirst(); continue }
            _ = it.popFirst()
            var params = ""
            while let p = it.popFirst() {
                if (0x40...0x7E).contains(p.value) {
                    if p == "m" { apply(params, dim: &dim, grey: &grey) }
                    break
                }
                params.unicodeScalars.append(p)
            }
        }
        flush()
        return out
    }

    static func apply(_ params: String, dim: inout Bool, grey: inout Bool) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";").map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0: dim = false; grey = false
            case 2: dim = true
            case 22: dim = false
            case 39: grey = false
            case 90: grey = true
            case 30...37, 91...97: grey = false
            case 38:
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    grey = (240...250).contains(codes[i + 2]); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    i += 4
                }
            case 48, 58:
                // Фон и цвет подчёркивания: их параметры не должны читаться как dim/серый.
                if i + 2 < codes.count, codes[i + 1] == 5 { i += 2 }
                else if i + 4 < codes.count, codes[i + 1] == 2 { i += 4 }
            default: break
            }
            i += 1
        }
    }
}
