import SwiftUI
import AppKit
import CapriKit

/// Настройки Capri (UserDefaults). Список хостов применяется после перезапуска.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    static let defaultHosts = ["timoserver", "quiz"]

    @Published var sound: Bool { didSet { d.set(sound, forKey: "capri.sound") } }
    @Published var hostsText: String

    init() {
        Self.migrateFromPrototype()
        sound = d.object(forKey: "capri.sound") as? Bool ?? true
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
