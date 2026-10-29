import SwiftUI

private enum Palette {
    static let canvas = Color(red: 0.085, green: 0.074, blue: 0.108)
    static let sidebar = Color(red: 0.112, green: 0.096, blue: 0.139)
    static let surface = Color(red: 0.148, green: 0.128, blue: 0.177)
    static let accent = Color(red: 0.96, green: 0.43, blue: 0.61)
    static let green = Color(red: 0.53, green: 0.82, blue: 0.64)
    static let muted = Color(red: 0.65, green: 0.62, blue: 0.70)
}

struct DashboardView: View {
    @ObservedObject var store: DemoStore
    @ObservedObject var character: CharacterController
    @State private var page = "sessions"
    @State private var settings = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            VStack(alignment: .leading, spacing: 0) {
                topbar
                if page == "sessions" { sessionContent }
                else { connections }
            }
            .padding(.horizontal, 30).padding(.top, 42).padding(.bottom, 22)
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .background(Palette.canvas).preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { preferences }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle").font(.system(size: 24)).foregroundStyle(Palette.accent)
                Text("capri").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-1)
            }.padding(.bottom, 8)
            Text("Рядом, пока ты создаёшь.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            VStack(spacing: 6) {
                navRow("Сессии", symbol: "square.stack.3d.up", value: "sessions", count: "3")
                navRow("Подключения", symbol: "point.3.connected.trianglepath.dotted", value: "connections")
            }.padding(.top, 35)
            VStack(alignment: .leading, spacing: 16) {
                Text("Окружение").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                Label("Этот Mac", systemImage: "laptopcomputer").font(.system(size: 12))
                HStack { Image(systemName: "server.rack"); Text("dev-server"); Spacer(); Text("демо").font(.system(size: 10)).foregroundStyle(Palette.muted) }.font(.system(size: 12))
            }.padding(.horizontal, 12).padding(.top, 36)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                if let image = CharacterAssets.face { Image(nsImage: image).resizable().scaledToFit().frame(width: 66, height: 66) }
                Text("Я здесь.").font(.system(size: 20, weight: .medium, design: .rounded))
                Text("Позову, когда понадобится\nтвоё внимание.").font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 12).padding(.bottom, 24)
            Button { settings = true } label: {
                HStack { Image(systemName: "slider.horizontal.3"); Text("Настройки"); Spacer(); Text("⌘,").foregroundStyle(Palette.muted) }.font(.system(size: 12))
            }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command).padding(12)
            HStack(spacing: 6) { Circle().fill(Palette.green).frame(width: 5, height: 5); Text("Локальный прототип · v0.1").font(.system(size: 10)).foregroundStyle(Palette.muted) }.padding(.horizontal, 12).padding(.top, 7)
        }.padding(.horizontal, 18).padding(.top, 49).padding(.bottom, 24).background(Palette.sidebar)
    }
    private func navRow(_ title: String, symbol: String, value: String, count: String? = nil) -> some View {
        Button { page = value } label: {
            HStack(spacing: 10) { Image(systemName: symbol).frame(width: 16); Text(title); Spacer(); if let count { Text(count).foregroundStyle(Palette.muted) } }
                .font(.system(size: 13, weight: .medium)).padding(12)
                .background(page == value ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var topbar: some View {
        HStack {
            Text(page == "sessions" ? "Центр сессий" : "Подключения").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            Spacer()
            Text("Демо").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 4).background(Palette.accent.opacity(0.12), in: Capsule())
            Button { settings = true } label: { Image(systemName: "person.crop.circle").font(.system(size: 18)) }.buttonStyle(.plain).padding(.leading, 12).accessibilityLabel("Настройки персонажа")
        }.padding(.bottom, 27)
    }
    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Всё под присмотром.").font(.system(size: 29, weight: .medium, design: .rounded)).tracking(-0.7)
            Text(store.attentionCount > 0 ? "Одна сессия ждёт твоего решения." : "Сейчас твоё внимание не требуется.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 7)
            HStack(spacing: 8) {
                filter("Все сессии", selected: !store.attentionOnly) { store.attentionOnly = false }
                filter("Нужно внимание  \(store.attentionCount)", selected: store.attentionOnly) { store.attentionOnly = true }
                Spacer()
            }.padding(.top, 24).padding(.bottom, 14)
            VStack(spacing: 3) {
                ForEach(store.visible) { session in sessionRow(session) }
                if store.visible.isEmpty { Text("Запросов пока нет.").font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 65) }
            }
            Divider().overlay(Color.white.opacity(0.03)).padding(.vertical, 18)
            detail
            Spacer(minLength: 14)
            composer
            Text("Демонстрационные сессии. Команды остаются в этом окне.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 10)
        }
    }
    private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7).background(selected ? Palette.surface : .clear, in: Capsule()).foregroundStyle(selected ? Color.white.opacity(0.9) : Palette.muted) }.buttonStyle(.plain)
    }
    private func stateColor(_ state: DemoState) -> Color { state == .approval ? Palette.accent : state == .completed ? Palette.green : Palette.muted }
    private func sessionRow(_ session: DemoSession) -> some View {
        Button { store.select(session.id) } label: {
            HStack(spacing: 13) {
                Image(systemName: session.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(session.agent == "Codex" ? Palette.green : Palette.muted).frame(width: 34, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) { Text(session.project).font(.system(size: 13, weight: .semibold)); Text(session.agent).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    Text(session.task).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) { Circle().fill(stateColor(session.state)).frame(width: 5, height: 5); Text(session.state.label).font(.system(size: 11)) }.foregroundStyle(stateColor(session.state))
                    Text(session.control).font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .background(store.selectedID == session.id ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(store.selected.project).font(.system(size: 12, weight: .semibold))
                Text("/ \(store.selected.host)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button { store.runScenario() } label: { Label("Демосценарий", systemImage: "play.fill").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(!store.selected.canSend)
            }
            Text(store.selected.summary).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            if store.selected.pendingID != nil {
                HStack(spacing: 9) {
                    Label("swift test", systemImage: "terminal").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Отклонить") { store.resolveApproval(allow: false) }.buttonStyle(.bordered).controlSize(.small)
                    Button("Разрешить демо") { store.resolveApproval(allow: true) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6).background(Palette.accent, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Palette.canvas)
                }.padding(11).background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            } else {
                ForEach(Array(store.selected.events.suffix(2).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 8) { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(Palette.green); Text(event).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1) }
                }
            }
            if let notice = store.notice { Text(notice).font(.system(size: 10)).foregroundStyle(Palette.accent) }
        }
    }
    private var composer: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble").foregroundStyle(Palette.muted)
            TextField(store.selected.canSend ? "Напиши выбранной демосессии…" : store.selected.pendingID != nil ? "Сначала ответь на запрос выше" : "Эта сессия доступна для наблюдения", text: $store.composer)
                .textFieldStyle(.plain).font(.system(size: 12)).onSubmit { store.send() }.disabled(!store.selected.canSend)
            Button { store.send() } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 29, height: 29).background(Palette.accent.opacity(store.selected.canSend ? 1 : 0.2), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Palette.canvas) }.buttonStyle(.plain).disabled(!store.selected.canSend || store.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Отправить в демосессию")
        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Сначала — надёжная связь.").font(.system(size: 27, weight: .medium, design: .rounded))
            Text("В прототипе подключения ещё не настроены. Здесь будут настоящие агенты и серверы.").font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
            ForEach([("Codex", "CAPRI-002 · проверить app-server и авторизацию"), ("Claude Code", "CAPRI-003 · принять первое событие hook"), ("SSH / tmux", "CAPRI-004 · подключить один выбранный хост"), ("Tima / Telegram", "Следующие этапы после локального Core")], id: \.0) { title, subtitle in
                HStack { VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted) }; Spacer(); Text("Не подключено").font(.system(size: 10)).foregroundStyle(Palette.muted) }.padding(.vertical, 14)
                Divider()
            }
            Spacer()
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Персонаж").font(.system(size: 22, weight: .medium, design: .rounded)); Spacer(); Button("Готово") { settings = false }.keyboardShortcut(.defaultAction) }
            Picker("Размер", selection: $character.size) { Text("Маленький").tag("small"); Text("Средний").tag("medium"); Text("Большой").tag("large") }.pickerStyle(.segmented)
            Toggle("Приостановить анимацию", isOn: $character.paused)
            Toggle("Оставаться на месте", isOn: $character.pinned)
            Text("Когда закрепление выключено, Capri меняет место раз в 45 секунд. Системное уменьшение движения соблюдается.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack { Button("К вырезу экрана") { character.returnToNotch() }; Button("Телепорт") { character.teleport() }; Spacer() }
            Button(character.isHidden ? "Показать персонажа" : "Скрыть на 1 час") { if character.isHidden { character.show() } else { character.hideForOneHour() } }
            Divider()
            Text(character.rendererStatus).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text("Звук, голос, автозапуск и подключения появятся на следующих этапах.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(28).frame(width: 480).background(Palette.sidebar).preferredColorScheme(.dark)
    }
}
