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
    /// Глаза ушли на рабочий стол (идёт сцена) — в notch их нет.
    @Published var faceAway = false
    /// Смена пространства: глаза уезжают вместе со столом (`SpaceSweep`); nil — эффекта нет.
    @Published var sweep: SpaceSweepRun?
    /// Кивает под музыку (4 с после смены трека).
    @Published var vibing = false
    /// Что играет («Artist — Track») и играет ли сейчас; nil — ничего или неизвестно.
    @Published var music: String?
    @Published var musicPlaying = false
    /// Строка трека видна сама: 4 с после старта или смены трека (`NowPlayingState.revealUntil`).
    @Published var musicReveal = false
    /// Курсор над глазами Capri или над полосой музыки в раскрытом notch — строка трека видна.
    @Published var musicHover = false
    /// Полоса музыки в раскрытом notch, в координатах его SwiftUI-слоя (сверху вниз). Не публикуется: нужна
    /// только контроллеру для наведения.
    var musicStripRect: CGRect?
    /// Кнопки ⏮ ⏯ ⏭ в peek, в координатах его слоя: клик по peek раскрывает notch — по кнопкам ловим сами.
    var peekMusicRects: [String: CGRect] = [:]
    /// Notch раскрыт (кивает, пока раскрыт и играет музыка).
    @Published var expandedOpen = false
    /// «Спрятать персонажа на час» — в notch не кивает.
    @Published var characterHidden = false
    /// Голос (push-to-talk): что показывает строка peek; nil — голоса нет.
    @Published var voice: VoiceLine?
    /// Громкость микрофона 0…1 (сглаженная, 12 fps) — для молнии вдоль notch и рта. Не публикуется: её читают
    /// таймер молнии и `TimelineView` рта, не SwiftUI.
    var voiceLevel: Double = 0
    /// Подсказка в помощнике «держи ⌃⌥Пробел — скажи голосом» (пока голосом не пользовались 3 раза).
    @Published var voiceHint = false
    /// Слышит ли она голос (меняется только при смене состояния) — для лица в notch.
    @Published var voiceHeard: HearingWatch.Status?
}

/// Строка голоса в notch.
struct VoiceLine: Equatable {
    enum Phase: Equatable {
        /// Держат клавишу: глаза слушают, молния вдоль notch, частичный текст.
        case listening
        /// Отпустили: дослушиваю и разбираю.
        case working
        /// Итог (записала, напомню, включаю…).
        case done
        /// Не вышло (нет модели, нет микрофона, не расслышала).
        case failed
    }
    var phase: Phase
    var text: String
    /// Мелкая подпись справа (`⌃⌥Space`, «⌘⏎ отправить»).
    var hint: String = ""
    /// Пока текста нет — вместо «слушаю…»: какой вход взяли вместо выбранного, «не слышу — проверь микрофон».
    var note: String = ""
    /// `note` — тревога («не слышу»): малиновым.
    var alarm = false
}

/// Включён ли слой notch. Скрытый слой (свёрнутый notch) снимает содержимое целиком — вместе с подписками
/// на `store`/`clock`/`codex`, иначе спрятанный вид пересчитывал бы `body` на каждое изменение сессий.
final class HostGate: ObservableObject {
    @Published var live = false
}

/// Содержимое слоя notch, пока слой включён (`HostGate`); выключен — пусто, без подписок.
struct Gated<Content: View>: View {
    @ObservedObject var gate: HostGate
    @ViewBuilder var content: () -> Content

    var body: some View {
        if gate.live { content() } else { Color.clear }
    }
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
    /// ⏮ ⏯ ⏭ у строки трека.
    var music: (MusicCommand) -> Void = { _ in }
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

/// «♪ Artist — Track» в раскрытом notch (только пока играет или 5 с после паузы). Текст виден 4 с после смены
/// трека и пока курсор над глазами или над этой полосой (`revealed`); иначе — только мини-эквалайзер (цель
/// наведения). Место строка занимает всегда — высота капли не прыгает.
struct MusicLine: View {
    var line: String
    var playing: Bool
    /// Анимировать эквалайзер (только пока notch раскрыт).
    var animating: Bool
    var revealed = true
    /// ⏮ ⏯ ⏭ — видны вместе со строкой (4 с после смены трека и при наведении).
    var onCommand: ((MusicCommand) -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            EqualizerBars(color: playing ? Palette.crimson : Palette.dim, animating: playing && animating, height: 8)
            Text("♪ " + line).font(.mono(9.5, .semibold)).foregroundColor(playing ? Palette.text.opacity(0.85) : Palette.dim)
                .lineLimit(1).truncationMode(.tail)
                .opacity(revealed ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: revealed)
            Spacer(minLength: 0)
            if let onCommand {
                MusicButtons(playing: playing, action: onCommand)
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
                    .animation(.easeInOut(duration: 0.2), value: revealed)
            }
        }
        .help("Что играет в Spotify или Музыке")
    }
}

/// ⏮ ⏯ ⏭ — Capri сама управляет плеером (AppleScript, только по этому клику).
struct MusicButtons: View {
    var playing: Bool
    /// nil — только рисунок (peek: клики ловит контроллер по рамкам `PeekMusicKey`).
    var action: ((MusicCommand) -> Void)?
    var size: CGFloat = 9

    var body: some View {
        HStack(spacing: 4) {
            button("prev", "backward.end.fill", .previous)
            button("toggle", playing ? "pause.fill" : "play.fill", .toggle)
            button("next", "forward.end.fill", .next)
        }
    }

    @ViewBuilder
    private func button(_ id: String, _ symbol: String, _ cmd: MusicCommand) -> some View {
        let label = Image(systemName: symbol).font(.system(size: size, weight: .bold))
            .foregroundColor(id == "toggle" ? Palette.text : Palette.text.opacity(0.8))
            .frame(width: size * 2.4, height: size * 1.8)
            .hud(stroke: CapriFX.hackPink.opacity(id == "toggle" ? 0.8 : 0.45), fill: CapriFX.hackPink.opacity(id == "toggle" ? 0.14 : 0.04), cut: 4)
            .contentShape(Rectangle())
        if let action {
            Button { action(cmd) } label: { label }.buttonStyle(.plain)
                .help(id == "toggle" ? "Пауза / играть" : id == "next" ? "Следующий трек" : "Предыдущий трек")
        } else {
            label.background(GeometryReader { g in
                Color.clear.preference(key: PeekMusicKey.self, value: [id: g.frame(in: .named(PeekLineView.space))])
            })
        }
    }
}

/// Рамки кнопок музыки в peek (координаты слоя peek).
struct PeekMusicKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Прямоугольник полосы музыки в координатах слоя (для наведения).
struct MusicStripKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

// MARK: - Свёрнутый вид

/// Слева от выреза — глаза Capri (клик — помощник), справа — шкала сессий: столбик на сессию, зелёный — ждёт
/// меня, малиновый — работает, тусклый — простаивает (пять самых свежих, как в раскрытом); остальные — «+N».
struct TopRowView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var codex: CodexService
    var notchWidth: CGFloat

    static let maxBars = 5

    var body: some View {
        let waiting = store.waiting.count
        let list = store.overview
        // Музыка — никогда не выше «ждёт меня» и ответа Capri.
        let vibing = waiting == 0 && !codex.chatBusy && !ui.characterHidden
            && (ui.vibing || (ui.expandedOpen && ui.musicPlaying))
        HStack(spacing: 0) {
            // Слушает голос — выше всего: человек прямо сейчас говорит с ней.
            let listening = ui.voice?.phase == .listening
            Group {
                if let v = ui.voice {
                    // Голос: лицо само показывает, что слушает, слышит, не слышит, думает (мини-риг «значок»).
                    VoiceFaceView(state: VoiceFaceView.state(v, heard: ui.voiceHeard), level: { [ui] in ui.voiceLevel })
                } else {
                    CapriFace(mood: waiting > 0 ? .alert : codex.chatBusy ? .thinking : vibing ? .vibing : .idle, style: .mask)
                }
            }
                .frame(width: 32, height: 16)
                .opacity(ui.faceAway || ui.sweep != nil ? 0 : 1)
                .help("Capri — спросить (⌃⌥Space)")
            if listening {
                // Рот: зигзаг по громкости, сразу справа от глаз.
                VoiceMouthView(level: { [ui] in ui.voiceLevel }).frame(width: 20, height: 12).padding(.leading, 4)
            } else if vibing {
                EqualizerBars(color: Palette.crimson, animating: true, height: 9).padding(.leading, 4)
            }
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
        .overlay(alignment: .topLeading) {
            // Смена пространства: на время эффекта глаза рисует он (за край капли и в вырез).
            if let run = ui.sweep {
                GeometryReader { g in
                    SpaceSweepLive(run: run, rowHeight: g.size.height, hasNotch: ui.hasNotch, alert: waiting > 0)
                }
            }
        }
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
    static let space = "notchPeek"
    var body: some View {
        let waiting = store.waiting
        let focus = ui.alertKey.flatMap { k in waiting.first { $0.key == k } } ?? waiting.first
        HStack(spacing: 7) {
            if let v = ui.voice {
                VoiceLineView(line: v)
            } else if let s = focus {
                Image(systemName: "triangle.fill").font(.system(size: 7, weight: .bold)).foregroundColor(Palette.acid)
                Caps(store.name(s).title, size: 10, color: Palette.acid, weight: .bold).fixedSize()
                Rectangle().fill(Palette.line).frame(width: 1, height: 11)
                Text(store.summary(s) ?? s.headline).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                if waiting.count > 1 { Caps("+\(waiting.count - 1)", size: 9, color: Palette.dim) }
            } else if let line = ui.music {
                // Никто не ждёт — что играет (наведение на глаза).
                EqualizerBars(color: ui.musicPlaying ? Palette.crimson : Palette.dim, animating: false, height: 8)
                Text("♪ " + line).font(.mono(10, .semibold))
                    .foregroundColor(ui.musicPlaying ? Palette.text.opacity(0.85) : Palette.dim)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                MusicButtons(playing: ui.musicPlaying, action: nil, size: 8.5)
                Caps("работают · \(store.runningCount)", size: 9, color: store.runningCount > 0 ? Palette.crimson : Palette.dim)
                    .fixedSize()
            } else {
                Caps("ждут меня · 0", size: 9, color: Palette.dim)
                Spacer(minLength: 0)
                Caps("работают · \(store.runningCount)", size: 9, color: store.runningCount > 0 ? Palette.crimson : Palette.dim)
                Caps("всего · \(store.sessions.count)", size: 9, color: Palette.dim)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: PeekLineView.space)
        .onPreferenceChange(PeekMusicKey.self) { ui.peekMusicRects = $0 }
        .onDisappear { ui.peekMusicRects = [:] }
    }
}

// MARK: - Компактный раскрытый notch

/// Обзор сессий: пять самых свежих (ждущие меня — всегда первыми) ровной таблицей: состояние, что делает и
/// сколько. Ответы сессиям — через Capri (помощник) или основное окно; клик по строке — окно на ней.
struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var actions: NotchActions

    static let maxRows = 5
    /// Координаты всего слоя (как у NSHostingView, сверху вниз).
    static let space = "notchExpanded"

    var body: some View {
        let list = store.overview
        let rows = Array(list.prefix(Self.maxRows))
        VStack(alignment: .leading, spacing: 6) {
            header(list)
            if let line = ui.music {
                MusicLine(line: line, playing: ui.musicPlaying, animating: ui.expandedOpen,
                          revealed: ui.musicReveal || ui.musicHover, onCommand: actions.music)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MusicStripKey.self, value: g.frame(in: .named(ExpandedView.space)))
                    })
            }
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
        .onPreferenceChange(MusicStripKey.self) { ui.musicStripRect = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: ExpandedView.space)
        .onDisappear { ui.musicStripRect = nil }
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
