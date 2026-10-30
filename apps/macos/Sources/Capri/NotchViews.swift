import SwiftUI
import CapriKit

/// Состояние самого notch (не сессий): выбранная сессия, черновик ответа, акцент peek, помощник.
final class NotchUI: ObservableObject {
    @Published var selected: SessionKey?
    @Published var reply = ""
    @Published var hasNotch = true
    /// Сессия, о которой peek сообщает прямо сейчас (новое «ждёт меня»).
    @Published var alertKey: SessionKey?
    /// Высота содержимого раскрытого notch и помощника (капля подстраивается под неё).
    @Published var expandedHeight: CGFloat?
    @Published var assistantHeight: CGFloat?
    /// Текст в поле помощника и показан ли он сейчас (анимация лица — только пока виден).
    @Published var assistantText = ""
    @Published var assistantShown = false
    /// Увеличивается при каждом открытии помощника — поле ввода забирает фокус.
    @Published var assistantFocusTick = 0
}

/// Действия notch → контроллер.
struct NotchActions {
    var send: (SessionKey, ReplyAction) -> Void
    var open: (SessionKey) -> Void
    var select: (SessionKey) -> Void
    /// «Подробнее» — основное окно на этой сессии.
    var details: (SessionKey) -> Void
    /// Экранчик с Capri.
    var assistant: () -> Void
    /// Основное окно (без выбора сессии).
    var window: () -> Void
    /// Основное окно на разговоре с Capri.
    var conversation: () -> Void
}

func agoText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// Сводка Codex под запросом: что спрашивает сессия, по-человечески.
struct CodexSummaryLine: View {
    var text: String
    var size: CGFloat = 10.5
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Caps("codex", size: size * 0.72, color: Palette.codex, weight: .bold).fixedSize()
            Text(text).font(.system(size: size)).foregroundColor(Palette.text.opacity(0.9)).lineLimit(2)
        }
        .help("Сводка от Codex по запросу и экрану сессии (секреты вырезаны)")
    }
}

/// «Сколько ждёт» — подписан только на часы, тик не перерисовывает остальную панель.
struct AgoLabel: View {
    @ObservedObject var clock: Clock
    var since: Double
    var color: Color
    var body: some View { Caps(agoText(clock.now - since), size: 8, color: color, weight: .bold) }
}

struct WaitBar: View {
    @ObservedObject var clock: Clock
    var since: Double
    var color: Color
    var body: some View { SegmentBar(fraction: min(1, (clock.now - since) / 600), color: color) }
}

/// Высота содержимого для подгонки капли.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Сообщить высоту (содержимое должно иметь свою, т.е. `fixedSize(vertical:)`).
    func reportHeight(_ set: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(ContentHeightKey.self) { h in if h > 0 { set(h) } }
    }
}

func hudButton(_ title: String, accent: Color = Palette.crimson, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Caps(title, size: 8.5, color: accent == Palette.crimson ? Palette.text : accent, weight: .bold)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .hud(stroke: accent.opacity(0.7), fill: accent.opacity(0.1), cut: 5)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.4)
}

// MARK: - Свёрнутый вид

/// Слева от выреза — глаза Capri (клик — помощник), справа — счётчики.
struct TopRowView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var codex: CodexService
    var notchWidth: CGFloat
    var body: some View {
        let waiting = store.waiting.count
        HStack(spacing: 0) {
            CapriFace(mood: waiting > 0 ? .alert : codex.chatBusy ? .thinking : .idle, style: .mask)
                .frame(width: 26, height: 13)
                .help("Capri — спросить (⌃⌥Space)")
            Spacer(minLength: ui.hasNotch ? notchWidth : 8)
            HStack(spacing: 7) {
                if waiting > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold))
                        Text("\(waiting)")
                    }.foregroundColor(Palette.acid)
                }
                if store.runningCount > 0 {
                    HStack(spacing: 3) {
                        Rectangle().frame(width: 5, height: 5).rotationEffect(.degrees(45))
                        Text("\(store.runningCount)")
                    }.foregroundColor(Palette.crimson)
                }
            }.font(.mono(11, .bold))
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PeekLineView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var body: some View {
        let waiting = store.waiting
        let focus = ui.alertKey.flatMap { k in waiting.first { $0.key == k } } ?? waiting.first
        HStack(spacing: 7) {
            if let s = focus {
                Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold)).foregroundColor(Palette.acid)
                Caps(store.name(s).title, size: 10, color: Palette.acid, weight: .bold).fixedSize()
                Rectangle().fill(Palette.line).frame(width: 1, height: 11)
                Text(store.summary(s) ?? s.headline).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                if waiting.count > 1 { Caps("+\(waiting.count - 1)", size: 9, color: Palette.dim) }
            } else {
                Caps("ждут меня · 0", size: 9, color: Palette.dim)
                Spacer(minLength: 0)
                Caps("работают · \(store.runningCount)", size: 9, color: store.runningCount > 0 ? Palette.crimson : Palette.dim)
                Caps("всего · \(store.sessions.count)", size: 9, color: Palette.dim)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Компактный раскрытый notch

/// Только ждущие сессии (до 4 строк) + выбранная; выбранная раскрывается на месте: варианты или ответ.
/// Всё подробное — в основном окне.
struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var actions: NotchActions
    @FocusState private var replyFocused: Bool

    static let maxRows = 4

    private var selectedKey: SessionKey? { ui.selected.flatMap(store.resolve) }

    /// Ждущие в стабильном порядке стора + выбранная (даже если уже не ждёт — строка не исчезает из-под курсора).
    private var rows: [Session] {
        let sel = selectedKey
        let list = store.sessions.filter { $0.status == .needsInput || $0.key == sel }
        guard list.count > Self.maxRows else { return list }
        var head = Array(list.prefix(Self.maxRows))
        if let sel, !head.contains(where: { $0.key == sel }), let s = list.first(where: { $0.key == sel }) { head[Self.maxRows - 1] = s }
        return head
    }

    var body: some View {
        let rows = rows
        let waiting = store.waiting.count
        VStack(alignment: .leading, spacing: 5) {
            header(waiting)
            if rows.isEmpty {
                HStack(spacing: 8) {
                    Text("Никто не ждёт").font(.system(size: 12, weight: .medium))
                    Caps("работают · \(store.runningCount)", size: 8.5, color: store.runningCount > 0 ? Palette.crimson : Palette.dim)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            ForEach(rows, id: \.key) { s in
                VStack(alignment: .leading, spacing: 5) {
                    row(s)
                    if s.key == selectedKey { detail(s) }
                }
            }
            if waiting > rows.filter({ $0.status == .needsInput }).count {
                Caps("+\(waiting - rows.filter { $0.status == .needsInput }.count) ждут — в окне", size: 8, color: Palette.dim)
            }
            footer
        }
        .animation(.easeInOut(duration: 0.22), value: rows.map(\.key))
        .animation(.easeInOut(duration: 0.22), value: selectedKey)
        .foregroundColor(Palette.text)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .reportHeight { ui.expandedHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ waiting: Int) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caps("ждут меня", size: 10, color: Palette.text, weight: .bold)
                Caps(String(format: "// %02d", waiting), size: 10, color: Palette.acid, weight: .bold)
                Spacer()
                ForEach(store.hosts.filter { !$0.connected }) { h in
                    Caps("нет связи: \(SessionStore.displayHost(h.name))", size: 7.5, color: Palette.crimson)
                }
                hudButton("✦ capri", accent: Palette.codex) { actions.assistant() }
                    .help("Спросить Capri (⌃⌥Space)")
            }
            HStack(spacing: 0) {
                Rectangle().fill(Palette.crimson).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }

    private func row(_ s: Session) -> some View {
        let on = s.key == selectedKey
        let name = store.name(s)
        return Button(action: { actions.select(s.key) }) {
            HStack(spacing: 7) {
                StatusMark(status: s.status).frame(width: 9)
                Text(name.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                if let d = name.detail { Text(d).font(.mono(8.5)).foregroundColor(Palette.dim).lineLimit(1) }
                Text(store.summary(s) ?? s.headline).font(.system(size: 10.5)).foregroundColor(Palette.text.opacity(0.72)).lineLimit(1)
                Spacer(minLength: 4)
                AgoLabel(clock: store.clock, since: s.statusSince, color: s.statusColor)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(on ? Palette.crimson.opacity(0.14) : Color.clear)
            .overlay(alignment: .leading) { Rectangle().fill(on ? s.statusColor : .clear).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ s: Session) -> some View {
        let choices = s.status == .needsInput ? (s.request?.choices ?? []) : []
        return VStack(alignment: .leading, spacing: 5) {
            if s.status == .needsInput, let r = s.request, r.summary.count > 60 {
                Text(r.summary).font(r.kind == .permission ? .mono(10) : .system(size: 10.5))
                    .lineLimit(3).padding(.horizontal, 7).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.55))
            }
            if !choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(choices) { c in
                            hudButton("\(c.index) \(short(c.label))", accent: c.index == 1 ? Palette.acid : Palette.crimson,
                                      enabled: !store.deliveries.isBusy(s.key)) { actions.send(s.key, .choose(c.index)) }
                                .help(c.label)
                        }
                    }
                }
            } else {
                replyRow(s)
            }
            if let h = store.hint(s) { Text(h.text).font(.system(size: 9.5)).foregroundColor(h.color).lineLimit(1) }
        }
        .padding(.leading, 22)
        .transition(.opacity)
    }

    private func replyRow(_ s: Session) -> some View {
        let refusal = store.check(s.key, .text(ui.reply.isEmpty ? "x" : ui.reply))
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(">").font(.mono(12, .bold)).foregroundColor(Palette.crimson)
                TextField(s.status == .running ? "сессия работает…" : "ответ в \(store.name(s).title)", text: $ui.reply)
                    .textFieldStyle(.plain).font(.mono(11.5))
                    .focused($replyFocused)
                    .onSubmit { submit(s) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .hud(fill: Color.black.opacity(0.5), cut: 6)
            hudButton("⏎", enabled: refusal == nil && !ui.reply.isEmpty) { submit(s) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let k = selectedKey {
                hudButton("подробнее ⟶") { actions.details(k) }.help("Основное окно: экран сессии и история")
                hudButton("открыть ↗", enabled: store.session(k)?.tmux != nil) { actions.open(k) }
                    .help("Terminal с tmux attach на эту панель")
            }
            Spacer()
            hudButton("окно capri") { actions.window() }
        }
        .padding(.top, 2)
    }

    private func submit(_ s: Session) {
        guard !ui.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.send(s.key, .text(ui.reply))
    }

    private func short(_ label: String) -> String {
        label.count > 16 ? String(label.prefix(15)) + "…" : label
    }
}
