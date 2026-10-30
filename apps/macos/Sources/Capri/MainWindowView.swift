import SwiftUI
import CapriKit

/// Состояние основного окна: выбор, фильтры, черновики ответов по сессиям.
final class WindowUI: ObservableObject {
    @Published var selected: SessionKey?
    @Published var filter: SessionFilter = .all
    /// nil — все хосты.
    @Published var host: String?
    @Published var drafts: [SessionKey: String] = [:]
    /// Почему черновик от Codex не получился.
    @Published var draftError: [SessionKey: String] = [:]
    /// Справа чат с Codex вместо выбранной сессии.
    @Published var chatOpen = false
}

/// Действия окна → AppDelegate (те же пути, что у notch).
struct WindowActions {
    var send: (SessionKey, ReplyAction) -> Void
    var open: (SessionKey) -> Void
    var settings: () -> Void
}

/// Основное окно: хосты слева, список сессий с фильтрами, справа выбранная сессия —
/// экран tmux, история событий, ответ.
struct MainWindowView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: WindowUI
    var codex: CodexService
    var actions: WindowActions

    var visible: [Session] {
        store.sessions.filter { ui.filter.matches($0) && (ui.host == nil || $0.key.host == ui.host) }
    }

    var selected: Session? {
        guard let k = ui.selected, let r = store.resolve(k) else { return nil }
        return store.sessions.first { $0.key == r }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            Rectangle().fill(Palette.line.opacity(0.5)).frame(width: 1)
            list.frame(width: 300)
            Rectangle().fill(Palette.line.opacity(0.5)).frame(width: 1)
            Group {
                if ui.chatOpen {
                    CodexChatView(codex: codex, store: store)
                } else if let s = selected {
                    SessionDetailView(store: store, details: store.details, codex: codex, ui: ui, session: s, actions: actions)
                        .id(s.key)
                } else {
                    VStack(spacing: 10) {
                        CapriGlyph(alert: false).scaleEffect(2.2)
                        Caps(ui.selected == nil ? "выберите сессию" : "сессия закрылась", size: 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundColor(Palette.text)
        .background(Color(red: 0.035, green: 0.03, blue: 0.04))
        .environment(\.colorScheme, .dark)
    }

    // MARK: слева

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CapriGlyph(alert: !store.waiting.isEmpty)
                Caps("capri", size: 15, color: Palette.text, weight: .heavy)
            }
            .padding(.top, 34).padding(.bottom, 22)

            Caps("сессии", size: 8).padding(.bottom, 6)
            filterRow(.waiting, "ждут меня", count: store.waiting.count, color: Palette.acid)
            filterRow(.running, "работают", count: store.runningCount, color: Palette.crimson)
            filterRow(.all, "все", count: store.sessions.count, color: Palette.text)

            Caps("хосты", size: 8).padding(.top, 22).padding(.bottom, 6)
            hostRow(nil)
            ForEach(store.hosts) { h in hostRow(h) }

            Spacer()
            CodexPanel(codex: codex, ui: ui).padding(.bottom, 12)
            Button { actions.settings() } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Caps("настройки", size: 9, color: Palette.text)
                    Spacer()
                    Caps("⌘,", size: 8)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .hud(stroke: Palette.line.opacity(0.6), fill: Palette.fill, cut: 5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .background(Color.black.opacity(0.35))
    }

    private func filterRow(_ f: SessionFilter, _ title: String, count: Int, color: Color) -> some View {
        let on = ui.filter == f
        return Button { ui.filter = f; ui.chatOpen = false } label: {
            HStack {
                Rectangle().fill(on ? color : Color.clear).frame(width: 2, height: 12)
                Caps(title, size: 9.5, color: on ? Palette.text : Palette.dim, weight: on ? .bold : .semibold)
                Spacer()
                Caps(String(format: "%02d", count), size: 9.5, color: count > 0 ? color : Palette.dim, weight: .bold)
            }
            .padding(.vertical, 5).padding(.trailing, 4)
            .background(on ? Palette.crimson.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hostRow(_ h: SessionStore.HostRow?) -> some View {
        let on = ui.host == h?.name
        let count = store.sessions.filter { h == nil || $0.key.host == h?.name }.count
        return Button { ui.host = h?.name } label: {
            HStack(spacing: 6) {
                if let h {
                    Rectangle().fill(h.connected ? Palette.acid : Palette.crimson).frame(width: 5, height: 5)
                    Image(systemName: h.name == "local" ? "laptopcomputer" : "server.rack").font(.system(size: 10))
                        .foregroundColor(Palette.dim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.name == "local" ? "Этот Mac" : h.name).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        Caps(h.connected ? "на связи" : "нет связи", size: 7, color: h.connected ? Palette.dim : Palette.crimson)
                    }
                } else {
                    Rectangle().fill(Palette.dim).frame(width: 5, height: 5)
                    Text("Все хосты").font(.system(size: 11.5, weight: on ? .semibold : .regular))
                }
                Spacer()
                Caps("\(count)", size: 8.5)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .background(on ? Palette.crimson.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(h.map { "\($0.name): \($0.connected ? "на связи" : "нет связи")" } ?? "Сессии со всех хостов")
    }

    // MARK: список

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caps(title, size: 11, color: Palette.text, weight: .bold)
                Caps(String(format: "// %02d", visible.count), size: 11, color: Palette.crimson, weight: .bold)
            }
            .padding(.top, 34).padding(.horizontal, 12)
            HStack(spacing: 0) {
                Rectangle().fill(Palette.crimson).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
            if visible.isEmpty {
                Caps(ui.filter == .waiting ? "никто не ждёт" : "сессий нет", size: 9)
                    .frame(maxWidth: .infinity).padding(.top, 30)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(visible, id: \.key) { s in row(s) }
                    }
                    .padding(.horizontal, 8)
                    // Порядок стабильный (SessionOrder); сессия, сменившая группу, переезжает плавно.
                    .animation(.easeInOut(duration: 0.28), value: visible.map(\.key))
                }
            }
        }
    }

    private var title: String {
        switch ui.filter {
        case .waiting: return "ждут меня"
        case .running: return "работают"
        case .all: return "все сессии"
        }
    }

    private func row(_ s: Session) -> some View {
        let on = s.key == selected?.key
        let color = s.statusColor
        let name = store.name(s)
        return Button {
            ui.selected = s.key
            ui.chatOpen = false
            store.clearDelivery(s.key)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusMark(status: s.status).frame(width: 9)
                    Text(name.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    if let d = name.detail {
                        Text(d).font(.mono(9.5)).foregroundColor(Palette.dim).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    AgoLabel(clock: store.clock, since: s.statusSince, color: color)
                }
                HStack(spacing: 6) {
                    Caps(s.hostLabel, size: 7.5).fixedSize()
                    Caps(s.statusLabel, size: 7.5, color: color)
                    if s.tmux == nil { Caps("без tmux", size: 7.5) }
                }
                .padding(.leading, 15)
                if let line = store.summary(s) ?? (s.headline != s.statusLabel ? s.headline : nil) {
                    Text(line).font(.system(size: 10.5)).foregroundColor(Palette.text.opacity(0.7))
                        .lineLimit(2).padding(.leading, 15)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Palette.crimson.opacity(0.14) : Color.white.opacity(0.015))
            .overlay(alignment: .leading) { Rectangle().fill(on ? color : .clear).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusMark: View {
    var status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .needsInput: Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold))
            case .running: Rectangle().frame(width: 5, height: 5).rotationEffect(.degrees(45))
            default: Rectangle().frame(width: 5, height: 1.5)
            }
        }
        .foregroundColor(Session.color(status))
    }
}

// MARK: - Выбранная сессия

struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    /// Не @ObservedObject: экран и историю перерисовывают свои вложенные виды, а не вся карточка.
    var details: DetailStore
    @ObservedObject var codex: CodexService
    @ObservedObject var ui: WindowUI
    var session: Session
    var actions: WindowActions
    @FocusState private var replyFocused: Bool

    private var s: Session { session }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if s.status == .needsInput { request }
            ScreenPane(details: details, clock: store.clock, session: s)
            HistoryPane(details: details, session: s)
            reply
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 14)
        .onAppear { if s.status != .running { replyFocused = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusMark(status: s.status)
                Text(store.name(s).title).font(.system(size: 18, weight: .semibold))
                if let d = store.name(s).detail { Text(d).font(.mono(11)).foregroundColor(Palette.dim) }
                Caps(s.statusLabel, size: 9, color: s.statusColor, weight: .bold)
                AgoLabel(clock: store.clock, since: s.statusSince, color: s.statusColor)
                Spacer()
                button("открыть ↗", enabled: s.tmux != nil) { actions.open(s.key) }
                    .help(s.tmux == nil ? "сессия не в tmux" : "Terminal с tmux attach на эту панель")
            }
            HStack(spacing: 10) {
                Caps(s.hostLabel, size: 8)
                if let t = s.tmux { Caps("tmux \(t.session ?? "?") · окно \(t.window ?? "?") · \(t.pane)", size: 8) }
                if s.confidence == .inferred { Caps("по экрану", size: 8, color: Palette.violet) }
                if let cwd = s.cwd { Text(cwd).font(.mono(9)).foregroundColor(Palette.dim).lineLimit(1).truncationMode(.head) }
            }
            HStack(spacing: 0) {
                Rectangle().fill(s.statusColor).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }

    private var request: some View {
        let choices = s.request?.choices ?? []
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Caps("▲ \(s.kindLabel)", size: 8.5, color: Palette.acid, weight: .bold)
                if let tool = s.request?.tool { Caps(tool, size: 8.5) }
                Spacer()
                WaitBar(clock: store.clock, since: s.statusSince, color: Palette.acid)
            }
            Text(s.request?.summary ?? s.headline)
                .font(s.request?.kind == .permission ? .mono(11) : .system(size: 12))
                .lineLimit(6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.black.opacity(0.55))
            if let summary = store.summary(s) { CodexSummaryLine(text: summary, size: 11.5) }
            if !choices.isEmpty {
                FlowButtons(choices: choices, enabled: !store.deliveries.isBusy(s.key)) { n in
                    actions.send(s.key, .choose(n))
                }
            }
        }
        .padding(9)
        .hud(stroke: Palette.acid.opacity(0.6), fill: Palette.acid.opacity(0.05), cut: 9)
    }

    private var reply: some View {
        let draft = Binding(get: { ui.drafts[s.key] ?? "" }, set: { ui.drafts[s.key] = $0 })
        let text = draft.wrappedValue
        let refusal = store.check(s.key, .text(text.isEmpty ? "x" : text))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(">").font(.mono(13, .bold)).foregroundColor(Palette.crimson)
                    TextField(s.status == .running ? "сессия работает…" : "ответ в \(store.name(s).title) — Enter отправить, ⌥Enter новая строка",
                              text: draft, axis: .vertical)
                        .textFieldStyle(.plain).font(.mono(12))
                        .lineLimit(1...5)
                        .focused($replyFocused)
                        .onSubmit { submit(text) }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .hud(fill: Color.black.opacity(0.5), cut: 7)
                button(codex.drafting == s.key ? "codex думает…" : "черновик ✦", enabled: codex.isReady && codex.drafting == nil) {
                    makeDraft()
                }
                .help(codex.isReady ? "Codex предложит ответ в поле — отправляете вы" : "Codex не подключён")
                button("отправить ⏎", enabled: refusal == nil && !text.isEmpty) { submit(text) }
            }
            if let h = store.hint(s) {
                Text(h.text).font(.system(size: 10)).foregroundColor(h.color).lineLimit(2)
            }
            if let e = ui.draftError[s.key] {
                Text(e).font(.system(size: 10)).foregroundColor(Palette.crimson).lineLimit(2)
            }
        }
    }

    private func makeDraft() {
        let key = s.key
        ui.draftError[key] = nil
        codex.draft(key) { [ui] r in
            switch r {
            case .success(let t) where !t.isEmpty:
                // Не затираем то, что человек успел набрать сам.
                if (ui.drafts[key] ?? "").isEmpty { ui.drafts[key] = t } else { ui.drafts[key] = (ui.drafts[key] ?? "") + "\n" + t }
            case .failure(let e): ui.draftError[key] = "черновик: " + CodexService.message(e)
            default: break
            }
        }
    }

    private func submit(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.check(s.key, .text(text)) == nil else { return }
        actions.send(s.key, .text(text))
    }

    private func button(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Caps(title, size: 9, color: Palette.text, weight: .bold)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .hud(stroke: Palette.crimson.opacity(0.7), fill: Palette.crimson.opacity(0.1), cut: 5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    static func color(_ kind: HistoryEntry.Kind) -> Color {
        switch kind {
        case .attention: return Palette.acid
        case .problem: return Palette.crimson
        case .reply: return Palette.text
        case .tools: return Palette.dim
        case .info: return Palette.text.opacity(0.8)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func time(_ ts: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: ts)) }
}

/// Экран tmux-панели (`ScreenTextView`: без прыжков прокрутки).
struct ScreenPane: View {
    @ObservedObject var details: DetailStore
    var clock: Clock
    var session: Session

    var body: some View {
        let s = session
        let snap = details.screen(s)
        let lines = details.lines(s) ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Caps("экран", size: 8, color: Palette.text, weight: .bold)
                if let snap { ScreenAge(clock: clock, ts: snap.ts) }
                Spacer()
                if snap != nil { Caps("\(lines.count) строк", size: 7.5) }
            }
            if snap != nil {
                ScreenTextView(lines: lines)
                .background(Color.black.opacity(0.6))
                .overlay(Rectangle().stroke(Palette.line.opacity(0.4), lineWidth: 1))
            } else {
                Text(s.tmux == nil ? "Сессия не в tmux — экрана нет." : "Экран ещё не пришёл с хоста.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.4))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct HistoryPane: View {
    @ObservedObject var details: DetailStore
    var session: Session

    var body: some View {
        let entries = details.history.list(session.key).suffix(7)
        VStack(alignment: .leading, spacing: 3) {
            Caps("история", size: 8, color: Palette.text, weight: .bold)
            if entries.isEmpty {
                Text(session.confidence == .inferred ? "Сессия видна только по экрану — хуков нет." : "Событий пока не было.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            ForEach(Array(entries)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(SessionDetailView.time(e.ts)).font(.mono(9)).foregroundColor(Palette.dim)
                    Text(e.text).font(.system(size: 10.5)).foregroundColor(SessionDetailView.color(e.kind)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// «обновлён N с назад» — подписан только на часы.
struct ScreenAge: View {
    @ObservedObject var clock: Clock
    var ts: Double
    var body: some View {
        let age = max(0, Int(clock.now - ts))
        Caps(age < 3 ? "живой" : "снят \(agoText(Double(age))) назад", size: 7.5, color: age < 15 ? Palette.dim : Palette.crimson)
    }
}

/// Кнопки вариантов в несколько строк (варианты бывают длинными).
struct FlowButtons: View {
    var choices: [ReplyChoice]
    var enabled: Bool
    var choose: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(choices) { c in
                Button { choose(c.index) } label: {
                    HStack(spacing: 8) {
                        Caps("\(c.index)", size: 10, color: c.index == 1 ? Palette.acid : Palette.crimson, weight: .heavy)
                        Text(c.label).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .hud(stroke: (c.index == 1 ? Palette.acid : Palette.crimson).opacity(0.6),
                         fill: (c.index == 1 ? Palette.acid : Palette.crimson).opacity(0.08), cut: 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .help(c.label)
            }
        }
    }
}

