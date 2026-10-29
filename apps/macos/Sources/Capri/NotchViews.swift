import SwiftUI
import CapriKit

/// Состояние самого notch (не сессий): выбранная сессия, черновик ответа, акцент peek.
final class NotchUI: ObservableObject {
    @Published var selected: SessionKey?
    @Published var reply = ""
    @Published var hasNotch = true
    /// Сессия, о которой peek сообщает прямо сейчас (новое «ждёт меня»).
    @Published var alertKey: SessionKey?
}

/// Действия notch → контроллер.
struct NotchActions {
    var send: (SessionKey, ReplyAction) -> Void
    var open: (SessionKey) -> Void
    var select: (SessionKey) -> Void
    /// «Подробнее» — основное окно на этой сессии.
    var details: (SessionKey) -> Void
}

func agoText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
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

// MARK: - Свёрнутый вид

struct TopRowView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var notchWidth: CGFloat
    var body: some View {
        let waiting = store.waiting.count
        HStack(spacing: 0) {
            CapriGlyph(alert: waiting > 0)
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
                Caps(s.project, size: 10, color: Palette.acid, weight: .bold)
                Rectangle().fill(Palette.line).frame(width: 1, height: 11)
                Text(s.headline).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.text).lineLimit(1)
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

// MARK: - Раскрытая панель

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var actions: NotchActions
    @FocusState private var replyFocused: Bool

    /// Выбранная сессия. Если выбор задан, но сессия закрылась — nil (карточка скажет об этом),
    /// а не тихая подмена: иначе набранный ответ ушёл бы в другую сессию.
    var selected: Session? {
        guard let k = ui.selected else { return store.sessions.first }
        guard let r = store.resolve(k) else { return nil }
        return store.sessions.first { $0.key == r }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if store.sessions.isEmpty {
                Spacer()
                Caps("сессий нет", size: 10).frame(maxWidth: .infinity)
                Spacer()
            } else {
                list
                if let s = selected {
                    card(s)
                } else {
                    Caps("выбранная сессия закрылась — выберите другую", size: 8.5, color: Palette.crimson)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .hud(stroke: Palette.line, fill: Palette.fill, cut: 9)
                }
            }
        }
        .foregroundColor(Palette.text)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caps("ждут меня", size: 11, color: Palette.text, weight: .bold)
                Caps(String(format: "// %02d", store.waiting.count), size: 11, color: Palette.acid, weight: .bold)
                Spacer()
                ForEach(store.hosts) { h in
                    HStack(spacing: 3) {
                        Rectangle().fill(h.connected ? Palette.acid : Palette.crimson).frame(width: 5, height: 5)
                        Caps(SessionStore.displayHost(h.name), size: 8, color: h.connected ? Palette.dim : Palette.crimson)
                    }
                    .help(h.connected ? "\(h.name): на связи" : "\(h.name): нет связи")
                }
            }
            HStack(spacing: 0) {
                Rectangle().fill(Palette.crimson).frame(width: 26, height: 2)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(store.sessions, id: \.key) { s in row(s) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func color(_ s: Session) -> Color {
        switch s.status {
        case .needsInput: return Palette.acid
        case .running: return Palette.crimson
        case .error, .rateLimited: return Palette.crimson
        default: return Palette.dim
        }
    }

    private func row(_ s: Session) -> some View {
        let isSelected = s.key == selected?.key
        return Button(action: { actions.select(s.key) }) {
            HStack(spacing: 7) {
                Group {
                    switch s.status {
                    case .needsInput: Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold))
                    case .running: Rectangle().frame(width: 5, height: 5).rotationEffect(.degrees(45))
                    default: Rectangle().frame(width: 5, height: 1.5)
                    }
                }
                .foregroundColor(color(s)).frame(width: 9)
                Text(s.project).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(width: 96, alignment: .leading)
                Caps(s.hostLabel, size: 7).fixedSize()
                Text(s.headline).font(.system(size: 10)).foregroundColor(Palette.text.opacity(0.75)).lineLimit(1)
                Spacer(minLength: 4)
                AgoLabel(clock: store.clock, since: s.statusSince, color: color(s))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(isSelected ? Palette.crimson.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card(_ s: Session) -> some View {
        let waiting = s.status == .needsInput
        let accent = waiting ? Palette.acid : Palette.crimson
        let choices = waiting ? (s.request?.choices ?? []) : []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Caps(waiting ? "▲ attention" : s.status.rawValue.replacingOccurrences(of: "_", with: " "),
                     size: 8, color: accent, weight: .bold).fixedSize()
                Caps(s.kindLabel, size: 8).fixedSize()
                Spacer(minLength: 4)
                if waiting { WaitBar(clock: store.clock, since: s.statusSince, color: accent) }
                hudButton("подробнее", accent: Palette.crimson) { actions.details(s.key) }
                    .help("Основное окно: экран сессии и история")
                hudButton("открыть ↗", accent: Palette.crimson, enabled: s.tmux != nil) { actions.open(s.key) }
                    .help(s.tmux == nil ? "сессия не в tmux" : "Terminal с tmux attach на эту панель")
            }
            Text("\(s.project)  ·  \(s.hostLabel)").font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.text.opacity(0.8)).lineLimit(1)
            if waiting || s.status == .idle {
                Text(s.headline)
                    .font(s.request?.kind == .permission ? .mono(10.5) : .system(size: 11))
                    .foregroundColor(Palette.text)
                    .lineLimit(2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.55))
            }
            if !choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(choices) { c in
                            hudButton("\(c.index) \(short(c.label))", accent: c.index == 1 ? Palette.acid : Palette.crimson,
                                      enabled: !store.deliveries.isBusy(s.key)) {
                                actions.send(s.key, .choose(c.index))
                            }
                            .help(c.label)
                        }
                    }
                }
            } else {
                replyRow(s)
            }
            status(s)
        }
        .padding(8)
        .hud(stroke: accent.opacity(0.6), fill: accent.opacity(0.05), cut: 9)
    }

    private func replyRow(_ s: Session) -> some View {
        let refusal = store.check(s.key, .text(ui.reply.isEmpty ? "x" : ui.reply))
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(">").font(.mono(12, .bold)).foregroundColor(Palette.crimson)
                TextField(s.status == .running ? "сессия работает…" : "ответ в \(s.project)", text: $ui.reply)
                    .textFieldStyle(.plain).font(.mono(11.5))
                    .focused($replyFocused)
                    .onSubmit { submit(s) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .hud(fill: Color.black.opacity(0.5), cut: 6)
            hudButton("⏎", accent: Palette.crimson, enabled: refusal == nil && !ui.reply.isEmpty) { submit(s) }
        }
    }

    private func submit(_ s: Session) {
        let text = ui.reply
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.send(s.key, .text(text))
    }

    @ViewBuilder
    private func status(_ s: Session) -> some View {
        if let h = store.hint(s) {
            Text(h.text).font(.system(size: 9.5)).foregroundColor(h.color).lineLimit(1)
        }
    }

    private func short(_ label: String) -> String {
        label.count > 16 ? String(label.prefix(15)) + "…" : label
    }

    private func hudButton(_ title: String, accent: Color, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Caps(title, size: 8.5, color: accent == Palette.crimson ? Palette.text : accent, weight: .bold)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .hud(stroke: accent.opacity(0.7), fill: accent.opacity(0.1), cut: 5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
