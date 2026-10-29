import SwiftUI
import AppKit
import CapriKit

/// Настройки Capri (UserDefaults). Список хостов применяется после перезапуска.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    static let defaultHosts = ["timoserver", "quiz"]

    @Published var sound: Bool { didSet { d.set(sound, forKey: "capri.sound") } }
    @Published var hostsText: String
    @Published var codexEnabled: Bool { didSet { d.set(codexEnabled, forKey: "capri.codex"); onCodexChange?(codexEnabled) } }
    @Published var codexSummaries: Bool { didSet { d.set(codexSummaries, forKey: "capri.codexSummaries") } }
    @Published var codexPath: String { didSet { d.set(codexPath.isEmpty ? nil : codexPath, forKey: "capri.codexPath") } }
    /// Хосты, содержимое сессий которых в Codex не уходит (по умолчанию прод).
    @Published var codexPrivateText: String {
        didSet { d.set(Self.parseHosts(codexPrivateText).hosts, forKey: "capri.codexPrivateHosts") }
    }
    var codexPrivateHosts: Set<String> { Set(Self.parseHosts(codexPrivateText).hosts) }
    var onCodexChange: ((Bool) -> Void)?
    /// Пауза уведомлений до этого времени (unix). nil — без паузы.
    @Published var pausedUntil: Double? { didSet { d.set(pausedUntil, forKey: "capri.pausedUntil") } }
    @Published var systemNotifications: AttentionPolicy.SystemNotifications {
        didSet { d.set(systemNotifications.rawValue, forKey: "capri.systemNotifications") }
    }
    @Published var fullscreenQuiet: Bool { didSet { d.set(fullscreenQuiet, forKey: "capri.fullscreenQuiet"); onFullscreenChange?() } }
    var onFullscreenChange: (() -> Void)?
    @Published var loginItemError: String?
    /// Текст запроса в уведомлениях macOS (видно на экране блокировки). По умолчанию — только проект и хост.
    @Published var notificationText: Bool { didSet { d.set(notificationText, forKey: "capri.notificationText") } }
    var loginItem: Bool {
        get { LoginItem.enabled }
        set { loginItemError = LoginItem.set(newValue); objectWillChange.send() }
    }

    init() {
        Self.migrateFromPrototype()
        sound = d.object(forKey: "capri.sound") as? Bool ?? true
        pausedUntil = d.object(forKey: "capri.pausedUntil") as? Double
        systemNotifications = AttentionPolicy.SystemNotifications(rawValue: d.string(forKey: "capri.systemNotifications") ?? "") ?? .whenHidden
        fullscreenQuiet = d.object(forKey: "capri.fullscreenQuiet") as? Bool ?? true
        notificationText = d.object(forKey: "capri.notificationText") as? Bool ?? false
        codexEnabled = d.object(forKey: "capri.codex") as? Bool ?? true
        // Сводки отправляют экраны сессий в OpenAI — только по явному включению.
        codexSummaries = d.object(forKey: "capri.codexSummaries") as? Bool ?? false
        codexPrivateText = (d.stringArray(forKey: "capri.codexPrivateHosts") ?? ["quiz"]).joined(separator: ", ")
        codexPath = d.string(forKey: "capri.codexPath") ?? ""
        hostsText = (d.stringArray(forKey: "capri.hosts") ?? Self.defaultHosts).joined(separator: ", ")
    }

    /// Настройки прототипа (`local.capri.prototype`) переезжают в `local.capri` один раз.
    static func migrateFromPrototype() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "capri.migrated"), let old = UserDefaults(suiteName: "local.capri.prototype") else { return }
        for key in ["capri.hosts", "capri.sound", "size", "paused", "pinned"] where d.object(forKey: key) == nil {
            if let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "capri.migrated")
    }

    static var hosts: [String] { UserDefaults.standard.stringArray(forKey: "capri.hosts") ?? defaultHosts }

    /// Имя хоста уходит в ssh: только алиасы из ~/.ssh/config, без пробелов и ведущего «-».
    static func validHost(_ h: String) -> Bool {
        !h.isEmpty && !h.hasPrefix("-") && h.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) }
    }

    static func parseHosts(_ text: String) -> (hosts: [String], invalid: [String]) {
        let items = text.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init)
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0).inserted }
        return (unique.filter(validHost), unique.filter { !validHost($0) })
    }

    var hostsChanged: Bool { Self.parseHosts(hostsText).hosts != Self.hosts }

    func saveHosts() { d.set(Self.parseHosts(hostsText).hosts, forKey: "capri.hosts") }

    /// Перезапуск: новый экземпляр стартует, когда этот уже вышел.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Ждём выхода этого процесса (иначе новый упрётся в lock единственного экземпляра), но не дольше 10 с.
        p.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var character: CharacterVisibility
    /// Хосты, к которым Capri подключён сейчас (могут быть заданы `--hosts` в обход настроек).
    var active: [String]
    var close: () -> Void

    var body: some View {
        let parsed = Settings.parseHosts(settings.hostsText)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Caps("настройки", size: 13, color: Palette.text, weight: .heavy)
                Spacer()
                Button("Готово", action: close).keyboardShortcut(.defaultAction)
            }
            section("ssh-хосты") {
                TextField("timoserver, quiz", text: $settings.hostsText)
                    .textFieldStyle(.roundedBorder).font(.mono(12))
                Text("Алиасы из ~/.ssh/config через запятую. Этот Mac подключён всегда. На хосте нужен capri-hook: scripts/install-hooks.sh <host> --apply.")
                    .font(.system(size: 10.5)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                if active != Settings.hosts {
                    Text("Сейчас подключены: \(active.isEmpty ? "—" : active.joined(separator: ", ")) (заданы при запуске).")
                        .font(.system(size: 10.5)).foregroundColor(Palette.dim)
                }
                if !parsed.invalid.isEmpty {
                    Text("Не подходят: \(parsed.invalid.joined(separator: ", "))").font(.system(size: 10.5)).foregroundColor(Palette.crimson)
                }
                if settings.hostsChanged {
                    HStack {
                        Text("Применится после перезапуска.").font(.system(size: 10.5)).foregroundColor(Palette.dim)
                        Spacer()
                        Button("Сохранить и перезапустить") { settings.saveHosts(); Settings.relaunch() }
                    }
                }
            }
            section("уведомления") {
                Toggle("Звук при «ждёт меня»", isOn: $settings.sound)
                Picker("Уведомления macOS", selection: $settings.systemNotifications) {
                    Text("Нет").tag(AttentionPolicy.SystemNotifications.off)
                    Text("Когда notch не видно (экран спит, заблокирован, вы на другом мониторе)").tag(AttentionPolicy.SystemNotifications.whenHidden)
                    Text("Всегда").tag(AttentionPolicy.SystemNotifications.always)
                }
                Toggle("Текст запроса в уведомлениях (виден на экране блокировки)", isOn: $settings.notificationText)
                    .disabled(settings.systemNotifications == .off)
                Toggle("В полноэкранных приложениях прятать notch (всплывает только на «ждёт меня»)", isOn: $settings.fullscreenQuiet)
            }
            section("запуск") {
                Toggle("Запускать Capri при входе в систему", isOn: Binding(get: { settings.loginItem }, set: { settings.loginItem = $0 }))
                    .disabled(!LoginItem.available)
                if let e = settings.loginItemError ?? (LoginItem.available ? nil : "Доступно для Capri из /Applications (scripts/install-macos.sh).") {
                    Text(e).font(.system(size: 10.5)).foregroundColor(Palette.dim)
                }
                if LoginItem.needsApproval {
                    HStack {
                        Text("macOS ждёт разрешения на автозапуск.").font(.system(size: 10.5)).foregroundColor(Palette.crimson)
                        Button("Открыть Настройки") { LoginItem.openSystemSettings() }
                    }
                }
            }
            section("codex") {
                Toggle("Codex в Capri (вход через аккаунт ChatGPT)", isOn: $settings.codexEnabled)
                Toggle("Сводки «что спрашивает сессия» в notch (автоматически)", isOn: $settings.codexSummaries)
                    .disabled(!settings.codexEnabled)
                Text("Сводки, чат и черновики отправляют в OpenAI запрос сессии и низ её экрана. Токены, ключи, пароли и email вырезаются; инструменты у Codex выключены — он только читает текст.")
                    .font(.system(size: 10.5)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Не отправлять в Codex:").font(.system(size: 11))
                    TextField("quiz", text: $settings.codexPrivateText).textFieldStyle(.roundedBorder).font(.mono(11))
                }
                TextField("путь к codex (пусто — найти самому)", text: $settings.codexPath)
                    .textFieldStyle(.roundedBorder).font(.mono(11))
                    .onSubmit { settings.onCodexChange?(false); if settings.codexEnabled { settings.onCodexChange?(true) } }
            }
            section("персонаж") {
                Toggle("Показывать бродящего персонажа", isOn: $character.visible)
            }
        }
        .padding(22)
        .frame(width: 460)
        .foregroundColor(Palette.text)
        .background(Color(red: 0.06, green: 0.05, blue: 0.07))
        .environment(\.colorScheme, .dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Caps(title, size: 8.5, color: Palette.crimson, weight: .bold)
            content()
        }
    }
}

/// Мост к персонажу: создаётся лениво, только когда его включили.
final class CharacterVisibility: ObservableObject {
    var show: () -> Void = {}
    var hide: () -> Void = {}
    var isVisible: () -> Bool = { false }
    var visible: Bool {
        get { isVisible() }
        set { objectWillChange.send(); newValue ? show() : hide() }
    }
}
