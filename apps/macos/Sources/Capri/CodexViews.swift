import SwiftUI
import CapriKit

/// Блок Codex в сайдбаре окна: вход, лимиты аккаунта, кнопка чата.
struct CodexPanel: View {
    @ObservedObject var codex: CodexService
    @ObservedObject var ui: WindowUI

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Rectangle().fill(dot).frame(width: 5, height: 5)
                Caps("codex", size: 8.5, color: Palette.codex, weight: .bold)
                Spacer()
                Caps(stateText, size: 7.5)
            }
            switch codex.state {
            case .signedOut:
                panelButton("войти через chatgpt") { codex.signIn() }
            case .signingIn:
                Text("Откройте браузер и завершите вход.").font(.system(size: 10)).foregroundColor(Palette.dim)
                panelButton("отменить вход") { codex.cancelSignIn() }
            case .noBinary:
                Text("codex не найден. Путь можно указать в настройках.").font(.system(size: 10)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let m):
                Text(m).font(.system(size: 9.5)).foregroundColor(Palette.crimson).lineLimit(3)
                panelButton("перезапустить") { codex.stop(); codex.start() }
            case .ready:
                if let l = codex.limits { LimitsView(limits: l) }
                panelButton(ui.chatOpen ? "к сессиям" : "что ждёт меня? ✦") { ui.chatOpen.toggle() }
            case .starting, .off:
                EmptyView()
            }
        }
        .padding(8)
        .hud(stroke: Palette.codex.opacity(0.45), fill: Palette.codex.opacity(0.05), cut: 6)
    }

    private var dot: Color {
        switch codex.state {
        case .ready: return Palette.acid
        case .failed, .noBinary: return Palette.crimson
        default: return Palette.dim
        }
    }

    private var stateText: String {
        switch codex.state {
        case .off: return "выключен"
        case .noBinary: return "нет codex"
        case .starting: return "запуск…"
        case .signedOut: return "не вошли"
        case .signingIn: return "вход…"
        case .ready(let a): return a.plan ?? a.type
        case .failed: return "ошибка"
        }
    }

    private func panelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Caps(title, size: 8.5, color: Palette.text, weight: .bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .hud(stroke: Palette.codex.opacity(0.7), fill: Palette.codex.opacity(0.1), cut: 5)
        }
        .buttonStyle(.plain)
    }
}

/// Лимиты аккаунта: окно 5 ч и неделя, сегментные полоски.
struct LimitsView: View {
    var limits: CodexLimits
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = limits.primary { row(Self.title(p, fallback: "5 ч"), p) }
            if let s = limits.secondary { row(Self.title(s, fallback: "неделя"), s) }
            if limits.reached { Caps("лимит исчерпан", size: 7.5, color: Palette.crimson, weight: .bold) }
        }
    }

    private func row(_ title: String, _ w: CodexLimits.Window) -> some View {
        let color = w.usedPercent >= 90 ? Palette.crimson : w.usedPercent >= 70 ? Palette.acid : Palette.codex
        return HStack(spacing: 5) {
            Caps(title, size: 7.5).frame(width: 44, alignment: .leading)
            SegmentBar(fraction: w.usedPercent / 100, color: color)
            Caps("\(Int(w.usedPercent.rounded()))%", size: 7.5, color: color)
        }
        .help(w.resetsAt.map { "Сброс: " + Self.reset.string(from: Date(timeIntervalSince1970: $0)) } ?? "")
    }

    static func title(_ w: CodexLimits.Window, fallback: String) -> String {
        switch w.windowMinutes {
        case 300: return "5 ч"
        case 10080: return "неделя"
        case let m where m > 0 && m % 60 == 0: return "\(m / 60) ч"
        default: return fallback
        }
    }

    static let reset: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()
}

/// Чат «что ждёт меня?»: к каждому вопросу Codex получает свежую картину по всем сессиям
/// (статусы, запросы, низ экранов ждущих — с вырезанными секретами).
struct CodexChatView: View {
    @ObservedObject var codex: CodexService
    @ObservedObject var store: SessionStore
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caps("спросить codex", size: 13, color: Palette.text, weight: .heavy)
                Caps("видит все сессии · секреты вырезаны", size: 8)
                Spacer()
                Button("очистить") { codex.clearChat() }.buttonStyle(.plain).font(.mono(9.5))
                    .foregroundColor(Palette.dim).disabled(codex.chatBusy || codex.chat.isEmpty)
            }
            HStack(spacing: 0) {
                Rectangle().fill(Palette.codex).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if codex.chat.isEmpty { suggestions }
                        ForEach(codex.chat) { m in bubble(m).id(m.id) }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: codex.chat) { chat in
                    if let last = chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("?").font(.mono(13, .bold)).foregroundColor(Palette.codex)
                    TextField(codex.isReady ? "например: что ждёт меня и с чего начать?" : "Codex не подключён", text: $question, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(send)
                        .disabled(!codex.isReady)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .hud(stroke: Palette.codex.opacity(0.6), fill: Color.black.opacity(0.5), cut: 7)
                Button(action: send) {
                    Caps(codex.chatBusy ? "думает…" : "спросить ⏎", size: 9, color: Palette.text, weight: .bold)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .hud(stroke: Palette.codex.opacity(0.7), fill: Palette.codex.opacity(0.1), cut: 5)
                }
                .buttonStyle(.plain)
                .disabled(!codex.isReady || codex.chatBusy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 14)
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex получает список сессий, их запросы и низ экранов тех, что ждут. Ничего не запускает.")
                .font(.system(size: 11)).foregroundColor(Palette.dim)
            ForEach(["Что сейчас ждёт меня и что ответить первым?", "Есть ли среди запросов рискованные команды?",
                     "Какие сессии давно простаивают?"], id: \.self) { q in
                Button { question = q; send() } label: {
                    Text(q).font(.system(size: 11.5)).foregroundColor(Palette.text.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .hud(stroke: Palette.codex.opacity(0.35), fill: Color.clear, cut: 5)
                }
                .buttonStyle(.plain)
                .disabled(!codex.isReady || codex.chatBusy)
            }
        }
    }

    private func bubble(_ m: CodexService.ChatMessage) -> some View {
        let user = m.role == .user
        return VStack(alignment: .leading, spacing: 3) {
            Caps(user ? "вы" : m.role == .error ? "ошибка" : "codex", size: 7.5,
                 color: user ? Palette.dim : m.role == .error ? Palette.crimson : Palette.codex, weight: .bold)
            Text(m.text).font(.system(size: 12)).foregroundColor(m.role == .error ? Palette.crimson : Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(user ? Color.white.opacity(0.04) : Palette.codex.opacity(0.06))
        .overlay(alignment: .leading) { Rectangle().fill(user ? Palette.dim.opacity(0.5) : Palette.codex).frame(width: 2) }
    }

    private func send() {
        let q = question
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, codex.isReady, !codex.chatBusy else { return }
        question = ""
        codex.ask(q)
    }
}
