import SwiftUI
import AppKit
import CapriKit

/// Настройки Capri (UserDefaults). Всё применяется сразу, без перезапуска.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    static let defaultHosts = ["timoserver", "quiz"]

    @Published var sound: Bool { didSet { d.set(sound, forKey: "capri.sound") } }
    /// ssh-хосты (алиасы из ~/.ssh/config). Этот Mac подключён всегда.
    @Published private(set) var hosts: [String]
    var onHostsChange: (([String]) -> Void)?
    @Published var codexEnabled: Bool {
        didSet { guard codexEnabled != oldValue else { return }; d.set(codexEnabled, forKey: "capri.codex"); onCodexChange?(codexEnabled) }
    }
    @Published var codexSummaries: Bool { didSet { d.set(codexSummaries, forKey: "capri.codexSummaries") } }
    /// Путь к codex; пусто — искать самому. Применяется кнопкой (`applyCodexPath`).
    @Published var codexPath: String
    /// Хосты, содержимое сессий которых в Codex не уходит (по умолчанию прод).
    @Published var codexPrivateHosts: Set<String> { didSet { d.set(codexPrivateHosts.sorted(), forKey: "capri.codexPrivateHosts") } }
    var onCodexChange: ((Bool) -> Void)?
    /// Пауза уведомлений до этого времени (unix). nil — без паузы.
    @Published var pausedUntil: Double? { didSet { d.set(pausedUntil, forKey: "capri.pausedUntil") } }
    /// Уведомления macOS, когда notch не видно (экран спит, заблокирован, вы на другом мониторе).
    @Published var systemNotifications: Bool { didSet { d.set(systemNotifications, forKey: "capri.systemNotificationsOn") } }
    @Published var fullscreenQuiet: Bool { didSet { d.set(fullscreenQuiet, forKey: "capri.fullscreenQuiet"); onFullscreenChange?() } }
    var onFullscreenChange: (() -> Void)?
    /// Текст запроса в уведомлениях macOS (виден на экране блокировки). По умолчанию — только имя сессии.
    @Published var notificationText: Bool { didSet { d.set(notificationText, forKey: "capri.notificationText") } }
    @Published var loginItemError: String?
    /// Глобальный шорткат вызова Capri (⌃⌥Space).
    @Published var assistantHotKey: Bool { didSet { d.set(assistantHotKey, forKey: "capri.assistantHotKey"); onHotKeyChange?() } }
    var onHotKeyChange: (() -> Void)?
    /// Шорткат не зарегистрировался (занят другим приложением).
    @Published var hotKeyError: String?
    /// Главный выключатель: Capri вообще выходит на рабочий стол (любая сцена — музыка, ответ, посадка, терминал).
    /// Выкл. — всё только в notch. Вкл. по умолчанию; все пути делят один бюджет `ScreenBudget`.
    @Published var desktop: Bool { didSet { d.set(desktop, forKey: "capri.desktop"); onCharacterChange?() } }
    /// Персонаж выходит на рабочий стол короткими сценами (по умолчанию выкл.; демо из меню — всегда).
    @Published var character: Bool { didSet { d.set(character, forKey: "capri.character"); onCharacterChange?() } }
    @Published var characterRate: CharacterDirector.Rate {
        didSet { d.set(characterRate.rawValue, forKey: "capri.characterRate"); onCharacterChange?() }
    }
    @Published var characterSessionEvents: Bool { didSet { d.set(characterSessionEvents, forKey: "capri.characterSessionEvents") } }
    @Published var characterTakeover: Bool { didSet { d.set(characterTakeover, forKey: "capri.characterTakeover") } }
    /// Фоновые сцены по таймеру (телепорт в угол, окно, сессии, захват) — экспериментально, по умолчанию выкл.
    @Published var characterAmbient: Bool { didSet { d.set(characterAmbient, forKey: "capri.characterAmbient"); onCharacterChange?() } }
    /// Сцены по моим действиям (ответ сессии → к терминалу, вопрос помощнику → «думает»/ответ) — вкл. по умолчанию.
    @Published var characterOnAction: Bool { didSet { d.set(characterOnAction, forKey: "capri.characterOnAction") } }
    /// «Спрятать персонажа на час»: до этого времени (unix) сцен и кивания нет.
    @Published var characterHiddenUntil: Double? {
        didSet { d.set(characterHiddenUntil, forKey: "capri.characterHiddenUntil"); onCharacterChange?() }
    }
    /// Кивать в notch под Spotify / Музыку.
    @Published var music: Bool { didSet { d.set(music, forKey: "capri.music"); onMusicChange?() } }
    /// «Садиться на окна, которые я открываю» (этап 2 присутствия) — вкл. по умолчанию.
    @Published var perch: Bool { didSet { d.set(perch, forKey: "capri.perch") } }
    /// Тихие часы посадок на окна (минуты от полуночи), по умолчанию 00:30–09:00.
    @Published var perchQuietStart: Int { didSet { d.set(perchQuietStart, forKey: "capri.perchQuietStart") } }
    @Published var perchQuietEnd: Int { didSet { d.set(perchQuietEnd, forKey: "capri.perchQuietEnd") } }
    /// «Не садиться здесь» — bundle id.
    @Published var perchBlocked: [String] { didSet { d.set(perchBlocked, forKey: "capri.perchBlocked") } }
    /// «Прогнать с окон на час»: до этого времени (unix) посадок нет.
    @Published var perchHiddenUntil: Double? { didSet { d.set(perchHiddenUntil, forKey: "capri.perchHiddenUntil") } }

    /// Голос: удерживать ⌃⌥Space и говорить (короткое нажатие — как раньше, помощник).
    @Published var voice: Bool { didSet { d.set(voice, forKey: "capri.voice") } }
    /// Путь к модели речи (.gguf); пусто — кэш Hugging Face.
    @Published var voiceModelPath: String { didSet { d.set(voiceModelPath, forKey: "capri.voiceModelPath") } }

    var quietHours: QuietHours { QuietHours(start: perchQuietStart, end: perchQuietEnd) }
    var perchHidden: Bool { (perchHiddenUntil ?? 0) > Date().timeIntervalSince1970 }
    var onCharacterChange: (() -> Void)?
    var onMusicChange: (() -> Void)?
    var loginItem: Bool {
        get { LoginItem.enabled }
        set { loginItemError = LoginItem.set(newValue); objectWillChange.send() }
    }

    var notificationPolicy: AttentionPolicy.SystemNotifications { systemNotifications ? .whenHidden : .off }

    init() {
        Self.migrate()
        sound = d.object(forKey: "capri.sound") as? Bool ?? true
        pausedUntil = d.object(forKey: "capri.pausedUntil") as? Double
        systemNotifications = d.object(forKey: "capri.systemNotificationsOn") as? Bool ?? true
        fullscreenQuiet = d.object(forKey: "capri.fullscreenQuiet") as? Bool ?? true
        notificationText = d.object(forKey: "capri.notificationText") as? Bool ?? false
        codexEnabled = d.object(forKey: "capri.codex") as? Bool ?? true
        // Сводки отправляют экраны сессий в OpenAI — только по явному включению.
        codexSummaries = d.object(forKey: "capri.codexSummaries") as? Bool ?? false
        codexPrivateHosts = Set(d.stringArray(forKey: "capri.codexPrivateHosts") ?? ["quiz"])
        codexPath = d.string(forKey: "capri.codexPath") ?? ""
        hosts = Self.hosts
        assistantHotKey = d.object(forKey: "capri.assistantHotKey") as? Bool ?? true
        desktop = d.object(forKey: "capri.desktop") as? Bool ?? true
        character = d.object(forKey: "capri.character") as? Bool ?? false
        characterRate = d.string(forKey: "capri.characterRate").flatMap(CharacterDirector.Rate.init(rawValue:)) ?? .sometimes
        characterSessionEvents = d.object(forKey: "capri.characterSessionEvents") as? Bool ?? true
        characterTakeover = d.object(forKey: "capri.characterTakeover") as? Bool ?? false
        characterAmbient = d.object(forKey: "capri.characterAmbient") as? Bool ?? false
        characterOnAction = d.object(forKey: "capri.characterOnAction") as? Bool ?? true
        characterHiddenUntil = d.object(forKey: "capri.characterHiddenUntil") as? Double
        music = d.object(forKey: "capri.music") as? Bool ?? true
        perch = d.object(forKey: "capri.perch") as? Bool ?? true
        perchQuietStart = d.object(forKey: "capri.perchQuietStart") as? Int ?? QuietHours.standard.start
        perchQuietEnd = d.object(forKey: "capri.perchQuietEnd") as? Int ?? QuietHours.standard.end
        perchBlocked = d.stringArray(forKey: "capri.perchBlocked") ?? []
        perchHiddenUntil = d.object(forKey: "capri.perchHiddenUntil") as? Double
        voice = d.object(forKey: "capri.voice") as? Bool ?? true
        voiceModelPath = d.string(forKey: "capri.voiceModelPath") ?? ""
    }

    var characterHidden: Bool { (characterHiddenUntil ?? 0) > Date().timeIntervalSince1970 }

    /// Настройки прототипа (`local.capri.prototype`) переезжают в `local.capri` один раз;
    /// трёхпозиционные уведомления (нет / когда не видно / всегда) стали переключателем.
    static func migrate() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "capri.migrated"), let old = UserDefaults(suiteName: "local.capri.prototype") {
            for key in ["capri.hosts", "capri.sound"] where d.object(forKey: key) == nil {
                if let v = old.object(forKey: key) { d.set(v, forKey: key) }
            }
            d.set(true, forKey: "capri.migrated")
        }
        if let old = d.string(forKey: "capri.systemNotifications") {
            if d.object(forKey: "capri.systemNotificationsOn") == nil { d.set(old != "off", forKey: "capri.systemNotificationsOn") }
            d.removeObject(forKey: "capri.systemNotifications")
        }
    }

    static var hosts: [String] { UserDefaults.standard.stringArray(forKey: "capri.hosts") ?? defaultHosts }

    /// Добавить хост; nil — добавлен, иначе почему нет.
    func addHost(_ raw: String) -> String? {
        let h = raw.trimmingCharacters(in: .whitespaces)
        guard HostSource.isValidAlias(h) else { return "«\(h)» не похоже на алиас из ~/.ssh/config" }
        guard !hosts.contains(h) else { return "\(h) уже в списке" }
        // Новый хост может оказаться продом: в Codex его сессии уходят только после явного включения.
        codexPrivateHosts.insert(h)
        setHosts(hosts + [h])
        return nil
    }

    func removeHost(_ h: String) {
        guard hosts.contains(h) else { return }
        setHosts(hosts.filter { $0 != h })
    }

    private func setHosts(_ list: [String]) {
        hosts = list
        d.set(list, forKey: "capri.hosts")
        onHostsChange?(list)
    }

    func applyCodexPath() {
        let p = codexPath.trimmingCharacters(in: .whitespaces)
        d.set(p.isEmpty ? nil : p, forKey: "capri.codexPath")
        if codexEnabled { onCodexChange?(false); onCodexChange?(true) }
    }

    var codexPathChanged: Bool {
        codexPath.trimmingCharacters(in: .whitespaces) != (d.string(forKey: "capri.codexPath") ?? "")
    }
}

/// Окно настроек: обычное окно macOS с формой, всё применяется сразу.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// Только список хостов, а не весь стор: форма не перерисовывается на каждое событие сессий.
    @ObservedObject var hosts: HostList
    /// Ключи Spotify Web API (Связка ключей) — поиск трека по названию.
    @ObservedObject var spotify: SpotifySearch
    /// Голос: где модель, скачивание.
    @ObservedObject var voice: VoiceCenter
    @State private var spotifyID = ""
    @State private var spotifySecret = ""
    @State private var newHost = ""
    @State private var hostError: String?
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                Toggle("Вызывать Capri по \(HotKey.assistant.label)", isOn: $settings.assistantHotKey)
                if let e = settings.hotKeyError { Text(e).font(.caption).foregroundColor(Palette.crimson) }
            } header: {
                Text("Capri")
            } footer: {
                Text("Ещё: клик по глазам слева от выреза или «✦ capri» в раскрытом notch.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Toggle("Говорить с Capri: держите \(HotKey.assistant.label)", isOn: $settings.voice)
                    .disabled(!settings.assistantHotKey)
                HStack {
                    Text("Модель речи")
                    Spacer()
                    switch voice.model {
                    case .found(let p):
                        Text((p as NSString).lastPathComponent).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(p)
                    case .missing:
                        Text("не найдена").font(.caption).foregroundColor(Palette.crimson)
                        Button("Скачать (~750 МБ)") { voice.downloadModel() }
                    case .downloading(let f):
                        ProgressView(value: f).frame(width: 120)
                        Text("\(Int(f * 100))%").font(.caption.monospacedDigit())
                    case .failed(let e):
                        Text("не скачалась: \(e)").font(.caption).foregroundColor(Palette.crimson).lineLimit(2)
                        Button("Ещё раз") { voice.downloadModel() }
                    }
                }
                .disabled(!settings.voice)
                HStack {
                    TextField("Свой путь к .gguf (пусто — кэш Hugging Face)", text: $settings.voiceModelPath)
                        .onSubmit { voice.refreshModel() }
                    Button("Проверить") { voice.refreshModel() }
                }
                .disabled(!settings.voice)
                if AsrHelper.binary == nil {
                    Text("В этой сборке нет распознавания речи (capri-asr).").font(.caption).foregroundColor(Palette.crimson)
                }
            } header: {
                Text("Голос")
            } footer: {
                Text("Коротко нажать — помощник, держать — говорить; отпустите — Capri выполнит. «Включи …», «пауза», «запиши …» (Заметки), «напомни через 20 минут / в 18:00 / завтра в 9 …» (Напоминания), «найди в интернете …», «ответь votek2 …» (сначала покажет текст, отправит после ⌘⏎). Остальное — помощнику. Речь распознаётся на этом Маке (Nemotron), микрофон включён, только пока держите клавишу. Первый раз macOS спросит доступ к микрофону, к Заметкам и Напоминаниям.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Уведомления") {
                Toggle("Звук, когда сессия ждёт ответа", isOn: $settings.sound)
                Toggle("Уведомления macOS, когда notch не видно", isOn: $settings.systemNotifications)
                    .help("Экран спит или заблокирован, курсор на другом мониторе")
                Toggle("Текст запроса в уведомлениях", isOn: $settings.notificationText)
                    .disabled(!settings.systemNotifications)
                    .help("Виден на экране блокировки. Выключено — только имя сессии.")
                Toggle("Прятать notch в полноэкранных приложениях", isOn: $settings.fullscreenQuiet)
                    .help("Notch всплывёт только на новое «ждёт меня»")
            }
            Section {
                Toggle("Capri выходит на рабочий стол", isOn: $settings.desktop)
                    .help("Выключено — никаких сцен на столе: ни музыки, ни посадок на окна, ни терминала, ни ответов. Всё — в notch.")
                HStack {
                    Text("Тихие часы")
                    Spacer()
                    DatePicker("с", selection: minutes($settings.perchQuietStart), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("до")
                    DatePicker("до", selection: minutes($settings.perchQuietEnd), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            } header: {
                Text("Capri на рабочем столе")
            } footer: {
                Text("Один общий счёт на все появления на столе: не чаще раза в 10 минут, 2 раз в час и \(ScreenBudget.perDay) в день, не раньше 5 минут после прошлой сцены. Не в тихие часы (\(settings.quietHours.label)) и не во время звонка (камера или микрофон заняты). Ниже — какие поводы вообще бывают.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Capri отвечает на мои действия на столе", isOn: $settings.characterOnAction)
                    .disabled(!settings.desktop)
                    .help("Ответил сессии — телепорт к терминалу; спросил помощника и свернул notch — окно «думаю» и ответ")
                Toggle("Реагировать на музыку (Spotify, Музыка)", isOn: $settings.music)
                    .help("Включили музыку сами после тишины — около минуты кивает на окне плеера и уходит в notch (включили через Capri — только кивок в notch); смена трека — кивок в notch не чаще раза в 15 минут")
                Toggle("Сцены, когда сессия доработала", isOn: $settings.character)
                    .disabled(!settings.desktop)
                    .help("Короткий телепорт, когда сессия закончила работу (не чаще раза в 20 минут)")
            } header: {
                Text("Персонаж")
            } footer: {
                Text("Capri появляется только в ответ на ваши действия — не в полноэкранных приложениях и не когда notch раскрыт. Capri можно перетащить за глаза или заголовок; наведение держит окно, «📌» — до «×». Клики мимо её окон проходят насквозь. Посмотреть все сцены — меню ✦ → Персонаж.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Садиться на окна запущенных приложений", isOn: $settings.perch)
                    .disabled(!settings.desktop)
                    .help("Запустили приложение (первый раз за день) — Capri садится на край окна, говорит про то, что происходит, и уходит. Клик по глазам — «кыш».")
                ForEach(settings.perchBlocked, id: \.self) { id in
                    HStack {
                        Text("Не садиться: \(Self.appName(id))")
                        Spacer()
                        Button(role: .destructive) { settings.perchBlocked.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Снова можно")
                    }
                }
            } header: {
                Text("На окнах")
            } footer: {
                Text("Только когда вы запускаете приложение, и только первый запуск этого приложения за день (переключение ⌘-Tab — не повод). Не больше \(PerchPolicy.perDay) посадок в день — и в общем счёте стола выше. Не садится в полноэкранных приложениях, играх, звонках (камера или микрофон заняты), менеджерах паролей. Прогнали два раза подряд — час не садится. «Не садиться на …» — правый клик по Capri на окне.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Фоновые сцены по таймеру", isOn: $settings.characterAmbient)
                    .disabled(!settings.character)
                    .help("Телепорт, окно статуса, сессии — сами по себе, без вашего действия")
                Picker("Как часто", selection: $settings.characterRate) {
                    Text("редко").tag(CharacterDirector.Rate.rare)
                    Text("иногда").tag(CharacterDirector.Rate.sometimes)
                }
                .disabled(!settings.character || !settings.characterAmbient)
                Toggle("Изображать захват экрана", isOn: $settings.characterTakeover)
                    .disabled(!settings.character || !settings.characterAmbient)
                    .help("Только рисунок поверх: Capri ничего не нажимает и не печатает")
            } header: {
                Text("Экспериментальное")
            } footer: {
                Text("Выключено по умолчанию. Нужна «Сцены, когда сессия доработала».")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section {
                if spotify.hasKeys {
                    HStack {
                        Text("Ключи Spotify сохранены")
                        Spacer()
                        Button("Проверить") { spotify.check() }
                        Button("Стереть", role: .destructive) { spotify.erase() }
                    }
                } else {
                    TextField("Client ID", text: $spotifyID).font(.system(.body, design: .monospaced))
                    SecureField("Client secret", text: $spotifySecret).font(.system(.body, design: .monospaced))
                    HStack {
                        Spacer()
                        Button("Сохранить") {
                            spotify.save(id: spotifyID, secret: spotifySecret)
                            if spotify.hasKeys { spotifyID = ""; spotifySecret = ""; spotify.check() }
                        }
                        .disabled(spotifyID.trimmingCharacters(in: .whitespaces).isEmpty || spotifySecret.isEmpty)
                    }
                }
                if let st = spotify.status { Text(st).font(.caption).foregroundColor(.secondary) }
            } header: {
                Text("Музыка")
            } footer: {
                Text("«Включи …» помощнику и кнопки ⏮ ⏯ ⏭: Capri управляет Spotify и Музыкой через AppleScript — только когда вы её просите; macOS спросит разрешение (Автоматизация; после переустановки Capri может спросить снова). Чтобы Spotify-трек находился по названию, нужны ключи бесплатного приложения developer.spotify.com (Create app → Client ID и Client secret) — они хранятся в Связке ключей. Без ключей по названию Spotify не ищется — Capri попросит ссылку; ссылки и spotify:-адреса включает сама, в фоне. Музыка ищет по вашей медиатеке.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(hosts.rows) { h in
                    HStack {
                        Circle().fill(h.connected ? Palette.acid : Palette.crimson).frame(width: 7, height: 7)
                        Text(h.name == "local" ? "Этот Mac" : h.name)
                        Text(h.connected ? "на связи" : "нет связи").foregroundColor(.secondary).font(.caption)
                        Spacer()
                        if h.name != "local" {
                            Button(role: .destructive) { settings.removeHost(h.name) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Убрать хост")
                        }
                    }
                }
                HStack {
                    TextField("алиас из ~/.ssh/config", text: $newHost)
                        .onSubmit(addHost)
                    Button("Добавить", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let e = hostError { Text(e).foregroundColor(Palette.crimson).font(.caption) }
            } header: {
                Text("Хосты")
            } footer: {
                Text("На хосте нужен capri-hook: scripts/install-hooks.sh <host> --apply.").font(.caption).foregroundColor(.secondary)
            }
            Section {
                Toggle("Запускать Capri при входе в систему", isOn: Binding(get: { settings.loginItem }, set: { settings.loginItem = $0 }))
                    .disabled(!LoginItem.available)
                if let e = settings.loginItemError ?? (LoginItem.available ? nil : "Доступно для Capri из /Applications.") {
                    Text(e).font(.caption).foregroundColor(.secondary)
                }
                if LoginItem.needsApproval {
                    HStack {
                        Text("macOS ждёт разрешения на автозапуск.").font(.caption).foregroundColor(Palette.crimson)
                        Button("Открыть Настройки") { LoginItem.openSystemSettings() }
                    }
                }
            } header: {
                Text("Запуск")
            }
            Section {
                Toggle("Codex в Capri (вход через ChatGPT)", isOn: $settings.codexEnabled)
                Toggle("Сводки «что спрашивает сессия» в notch", isOn: $settings.codexSummaries)
                    .disabled(!settings.codexEnabled)
                ForEach(hosts.rows.filter { $0.name != "local" }) { h in
                    Toggle("Отправлять в Codex сессии с \(h.name)", isOn: Binding(
                        get: { !settings.codexPrivateHosts.contains(h.name) },
                        set: { on in if on { settings.codexPrivateHosts.remove(h.name) } else { settings.codexPrivateHosts.insert(h.name) } }))
                        .disabled(!settings.codexEnabled)
                }
                DisclosureGroup("Дополнительно", isExpanded: $advanced) {
                    HStack {
                        TextField("путь к codex (пусто — найти самому)", text: $settings.codexPath)
                            .font(.system(.body, design: .monospaced))
                        Button("Применить") { settings.applyCodexPath() }.disabled(!settings.codexPathChanged)
                    }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Помощник, сводки и черновики отправляют в OpenAI запросы сессий, последние события и низ экранов ждущих и упомянутых в вопросе сессий. Токены, ключи, пароли и email вырезаются; инструменты у Codex выключены — он только читает текст. Сессии с выключенных хостов — только имя и статус.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420)
    }

    /// Минуты от полуночи ↔ время для `DatePicker`.
    private func minutes(_ b: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: b.wrappedValue / 60, minute: b.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    /// Имя приложения по bundle id (для списка «не садиться»).
    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addHost() {
        hostError = settings.addHost(newHost)
        if hostError == nil { newHost = "" }
    }
}
