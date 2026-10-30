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

/// Слева от выреза — глаза Capri (клик — помощник), справа — шкала сессий: столбик на сессию, зелёный — ждёт
/// меня, малиновый — работает, тусклый — простаивает; не влезли — «+N».
struct TopRowView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var codex: CodexService
    var notchWidth: CGFloat

    static let maxBars = 6

    var body: some View {
        let waiting = store.waiting.count
        let list = store.overview
        HStack(spacing: 0) {
            CapriFace(mood: waiting > 0 ? .alert : codex.chatBusy ? .thinking : .idle, style: .mask)
                .frame(width: 32, height: 16)
                .help("Capri — спросить (⌃⌥Space)")
            Spacer(minLength: ui.hasNotch ? notchWidth : 8)
            HStack(spacing: 2.5) {
                ForEach(list.prefix(Self.maxBars), id: \.key) { s in SessionBar(status: s.status) }
                if list.count > Self.maxBars {
                    Caps("+\(list.count - Self.maxBars)", size: 7.5, color: Palette.dim, weight: .bold).fixedSize()
                }
            }
            .help("Ждут меня: \(waiting) · работают: \(store.runningCount) · всего: \(list.count)")
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Столбик сессии в свёрнутом notch: ждёт — зелёный и выше, работает — малиновый, иначе — тусклый контур.
struct SessionBar: View {
    var status: SessionStatus
    var body: some View {
        let color = Session.color(status)
        let tall = status == .needsInput
        Group {
            if status == .needsInput || status == .running || status == .error || status == .rateLimited {
                Rectangle().fill(color)
            } else {
                Rectangle().strokeBorder(color.opacity(0.7), lineWidth: 1)
            }
        }
        .frame(width: 4, height: tall ? 12 : 9)
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

/// Обзор сессий: все живые сессии ровной таблицей (ждут → работают → остальные), у каждой — состояние, что
/// делает и сколько. Ответы сессиям — через Capri (помощник) или основное окно; клик по строке — окно на ней.
struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var actions: NotchActions

    static let maxRows = 7

    var body: some View {
        let list = store.overview
        let rows = Array(list.prefix(Self.maxRows))
        VStack(alignment: .leading, spacing: 6) {
            header(list)
            if rows.isEmpty {
                Text("Сессий нет").font(.system(size: 12, weight: .medium)).foregroundColor(Palette.dim)
                    .padding(.vertical, 4)
            }
            VStack(spacing: 1) {
                ForEach(rows, id: \.key) { row($0) }
            }
            if list.count > rows.count {
                Button(action: actions.window) {
                    Caps("ещё \(list.count - rows.count) — в окне ⟶", size: 8, color: Palette.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: rows.map(\.key))
        .foregroundColor(Palette.text)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .reportHeight { ui.expandedHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ list: [Session]) -> some View {
        let waiting = list.filter { $0.status == .needsInput }.count
        let running = list.filter { $0.status == .running }.count
        return VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Caps("сессии", size: 10, color: Palette.text, weight: .bold)
                count("ждут", waiting, Palette.acid)
                count("работают", running, Palette.crimson)
                count("всего", list.count, Palette.dim)
                Spacer(minLength: 4)
                ForEach(store.hosts.filter { !$0.connected }) { h in
                    Caps("нет связи: \(SessionStore.displayHost(h.name))", size: 7.5, color: Palette.crimson).lineLimit(1)
                }
                hudButton("✦ capri", accent: Palette.codex) { actions.assistant() }
                    .help("Спросить Capri или ответить сессии (⌃⌥Space)")
                hudButton("окно") { actions.window() }
            }
            HStack(spacing: 0) {
                Rectangle().fill(Palette.crimson).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }

    private func count(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Caps(label, size: 8, color: Palette.dim)
            Caps("\(n)", size: 9.5, color: n > 0 ? color : Palette.dim, weight: .bold)
        }
        .fixedSize()
    }

    /// Строка: метка · имя · хост · что делает · состояние · сколько. Колонки фиксированной ширины — ровно.
    private func row(_ s: Session) -> some View {
        let name = store.name(s)
        let waiting = s.status == .needsInput
        return Button(action: { actions.details(s.key) }) {
            HStack(spacing: 7) {
                StatusMark(status: s.status).frame(width: 9)
                Text(name.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .frame(width: 92, alignment: .leading)
                Text(waiting ? (store.summary(s) ?? s.headline) : (name.detail ?? SessionStore.displayHost(s.key.host)))
                    .font(waiting ? .system(size: 10.5) : .mono(8.5))
                    .foregroundColor(waiting ? Palette.text.opacity(0.85) : Palette.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Caps(s.statusLabel, size: 8, color: s.statusColor, weight: .bold).fixedSize()
                    .frame(width: 70, alignment: .trailing)
                AgoLabel(clock: store.clock, since: s.statusSince, color: s.statusColor)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(waiting ? Palette.acid.opacity(0.07) : Color.clear)
            .overlay(alignment: .leading) { Rectangle().fill(waiting ? Palette.acid : .clear).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(waiting ? "\(s.headline)\nКлик — окно на этой сессии; ответить — через ✦ capri" : "Клик — окно на этой сессии")
    }
}
