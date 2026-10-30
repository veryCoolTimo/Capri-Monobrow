import SwiftUI
import CapriKit

/// Ответы Codex — с inline-markdown (`код`, **жирный**), без блоков. Ссылки убираем: текст модели может
/// прийти с чужого экрана, кликабельный `[текст](url)` в нём не нужен.
func markdown(_ s: String) -> AttributedString {
    guard var a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
        return AttributedString(s)
    }
    for run in a.runs where run.link != nil { a[run.range].link = nil }
    return a
}

/// Текст сообщения разговора: «думает», ответ с markdown или ошибка, карточки действий. Общий для notch и окна.
struct ChatMessageBody: View {
    @ObservedObject var codex: CodexService
    var message: CodexService.ChatMessage
    var size: CGFloat = 12
    var lineLimit: Int? = nil
    var animate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if message.role == .codex && message.text.isEmpty {
                ThinkingDots(active: animate)
            } else {
                Text(message.role == .user ? AttributedString(message.text) : markdown(message.text))
                    .font(.system(size: size)).lineLimit(lineLimit)
                    .foregroundColor(message.role == .error ? Palette.crimson : Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.proposals) { p in ProposalCard(codex: codex, message: message.id, proposal: p) }
        }
    }
}

/// Настроение Capri по состоянию разговора и сессий.
func assistantMood(codex: CodexService, waiting: Int, typing: Bool) -> CapriMood {
    let last = codex.chat.last
    if codex.chatBusy { return (last?.text.isEmpty ?? true) ? .thinking : .speaking }
    if last?.role == .error { return .error }
    if typing { return .listening }
    if waiting > 0 { return .alert }
    return .idle
}

/// Экранчик Capri в notch: облачко с ответом над головой, ниже — голова и поле ввода.
struct AssistantView: View {
    @ObservedObject var codex: CodexService
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    var actions: NotchActions
    @FocusState private var focused: Bool

    var body: some View {
        let waiting = store.waiting.count
        let mood = assistantMood(codex: codex, waiting: waiting, typing: !ui.assistantText.isEmpty)
        VStack(alignment: .leading, spacing: 0) {
            Bubble(codex: codex, store: store, shown: ui.assistantShown)
                .padding(.leading, 6)
            HStack(alignment: .bottom, spacing: 10) {
                CapriFace(mood: mood, active: ui.assistantShown)
                    .accessibilityHidden(true)
                    .frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(">").font(.mono(13, .bold)).foregroundColor(Palette.codex)
                        TextField(codex.chatBusy ? "Capri думает…" : "спроси Capri: что ждёт? что сделала web? ответь…",
                                  text: $ui.assistantText)
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                            .focused($focused)
                            .onSubmit(send)
                        Button {} label: { Image(systemName: "mic").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundColor(Palette.dim.opacity(0.6)).disabled(true)
                            .help("Голос — позже")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .hud(stroke: Palette.codex.opacity(focused ? 0.85 : 0.5), fill: Color.black.opacity(0.55), cut: 7)
                    HStack(spacing: 8) {
                        Caps(codex.pendingProposal != nil ? "⌘⏎ отправить действие" : "⏎ спросить", size: 7.5)
                        Caps("esc закрыть", size: 7.5)
                        Spacer()
                        if !codex.chat.isEmpty {
                            Button("весь разговор ⟶") { actions.conversation() }.buttonStyle(.plain)
                                .font(.mono(8.5)).foregroundColor(Palette.dim)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .foregroundColor(Palette.text)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .reportHeight { ui.assistantHeight = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ui.assistantFocusTick) { _ in focused = true }
        .onAppear { focused = true }
        .background(confirmShortcut)
    }

    /// ⌘⏎ — подтвердить первое предложенное действие.
    private var confirmShortcut: some View {
        Button("") {
            if let p = codex.pendingProposal { codex.confirm(p.message, p.proposal.id) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0).frame(width: 0, height: 0)
        .disabled(codex.pendingProposal == nil)
    }

    private func send() {
        let q = ui.assistantText
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !codex.chatBusy else { return }
        ui.assistantText = ""
        codex.ask(q)
    }
}

/// Облачко над головой: последний вопрос и ответ (или приветствие), предложенные действия.
/// Длинный ответ прокручивается внутри облачка: поле ввода под ним не уезжает за край капли.
private struct Bubble: View {
    @ObservedObject var codex: CodexService
    @ObservedObject var store: SessionStore
    var shown: Bool
    @State private var contentHeight: CGFloat = 40

    static let maxHeight: CGFloat = 190

    var body: some View {
        let (question, answer) = lastExchange
        ScrollView(.vertical, showsIndicators: contentHeight > Self.maxHeight) {
            VStack(alignment: .leading, spacing: 5) {
                if let q = question {
                    Text("ты: \(q)").font(.system(size: 10.5)).foregroundColor(Palette.dim).lineLimit(1)
                }
                if let a = answer {
                    ChatMessageBody(codex: codex, message: a, size: 12.5, animate: shown)
                } else {
                    Text(greeting).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.onAppear { contentHeight = g.size.height }
                .onChange(of: g.size.height) { contentHeight = $0 } })
        }
        .frame(height: min(contentHeight, Self.maxHeight))
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Как в рефе Persona 5: малиновая «тень» со сдвигом под тёмным облачком со светлой кромкой.
        // Следующий .background ложится под предыдущий: сначала тёмное облачко, под ним — малиновая «тень».
        .background(BubbleShape().fill(Color(red: 0.06, green: 0.05, blue: 0.08)))
        .background(BubbleShape().fill(Palette.crimson.opacity(0.85)).offset(x: 3, y: 3))
        .overlay(BubbleShape().stroke(Palette.text.opacity(0.85), lineWidth: 1.2))
        .padding(.bottom, 8)   // место под хвостик
        .animation(.easeOut(duration: 0.18), value: answer?.text)
    }

    private var lastExchange: (String?, CodexService.ChatMessage?) {
        guard let i = codex.chat.lastIndex(where: { $0.role == .user }) else { return (nil, nil) }
        let answer = codex.chat.indices.contains(i + 1) ? codex.chat[i + 1] : nil
        return (codex.chat[i].text, answer)
    }

    private var greeting: String {
        let waiting = store.waiting
        if waiting.isEmpty { return "Привет. Никто не ждёт. Спроси, что делает любая сессия." }
        let names = waiting.prefix(3).map { store.name($0).title }.joined(separator: ", ")
        return "Ждут тебя: \(waiting.count) — \(names)\(waiting.count > 3 ? "…" : ""). Спроси, с чего начать."
    }
}

/// Облачко с хвостиком-молнией внизу слева — к голове Capri (зигзаг по мотивам рефа Persona 5).
struct BubbleShape: Shape {
    func path(in r0: CGRect) -> Path {
        let r = CGRect(x: r0.minX, y: r0.minY, width: r0.width, height: r0.height - 8)
        let c: CGFloat = 8
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        // Хвостик-молния к голове (голова ~ на 45 pt от левого края).
        p.addLine(to: CGPoint(x: r.minX + 54, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 44, y: r.maxY + 4))
        p.addLine(to: CGPoint(x: r.minX + 50, y: r.maxY + 4))
        p.addLine(to: CGPoint(x: r.minX + 34, y: r0.maxY))
        p.addLine(to: CGPoint(x: r.minX + 38, y: r.maxY + 1))
        p.addLine(to: CGPoint(x: r.minX + 32, y: r.maxY + 1))
        p.addLine(to: CGPoint(x: r.minX + 36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.closeSubpath()
        return p
    }
}

/// «думает…» — три точки по очереди (при «Уменьшить движение» или когда не видно — статично).
struct ThinkingDots: View {
    var active = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12,
                                paused: !active || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { ctx in
            let t = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Rectangle().fill(Palette.codex)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.9)))
                }
                Caps("думает", size: 8, color: Palette.dim)
            }
            .padding(.vertical, 3)
        }
    }
}

/// Карточка действия, предложенного помощником: отправит только человек.
/// Текст показывается целиком: человек подтверждает ровно то, что видит.
struct ProposalCard: View {
    @ObservedObject var codex: CodexService
    var message: UUID
    var proposal: CodexService.Proposal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Caps("→ \(proposal.title) · \(SessionStore.displayHost(proposal.key.host))", size: 8, color: Palette.acid, weight: .bold)
                Text(actionText).font(.mono(11))
                    .foregroundColor(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            switch proposal.state {
            case .pending:
                hudButton("отправить", accent: Palette.acid) { codex.confirm(message, proposal.id) }
                    .help("⌘⏎")
                hudButton("отмена") { codex.cancel(message, proposal.id) }
            case .sending: Caps("отправляю…", size: 8)
            case .sent: Caps("отправлено ✓", size: 8, color: Palette.acid)
            case .failed(let m): Text(m).font(.system(size: 10)).foregroundColor(Palette.crimson).lineLimit(2)
            case .cancelled: Caps("отменено", size: 8)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .hud(stroke: Palette.acid.opacity(0.5), fill: Palette.acid.opacity(0.06), cut: 5)
    }

    private var actionText: String {
        switch proposal.action {
        case .text(let t): return t
        case .choose(let n): return "выбрать \(n)" + (proposal.choiceLabel.map { " · \($0)" } ?? "")
        }
    }
}
