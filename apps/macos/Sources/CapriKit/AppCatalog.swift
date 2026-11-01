import Foundation

/// Что за приложение стало передним: от этого зависит, садится ли Capri на его окно и что говорит.
public enum AppCategory: String, CaseIterable, Codable {
    case browser, messenger, mail, ide, terminal, design, finance, video, notes, files, settings, music, other
    /// Игры и лаунчеры игр, звонки — тишина (реплик нет).
    case game, call

    /// Категории, у которых есть реплики (на остальных Capri не садится).
    public static let speaking: [AppCategory] = allCases.filter { $0 != .game && $0 != .call }

    public var title: String {
        switch self {
        case .browser: "браузер"
        case .messenger: "мессенджер"
        case .mail: "почта"
        case .ide: "код"
        case .terminal: "терминал"
        case .design: "дизайн"
        case .finance: "финансы"
        case .video: "видео"
        case .notes: "заметки"
        case .files: "файлы"
        case .settings: "настройки"
        case .music: "музыка"
        case .other: "прочее"
        case .game: "игра"
        case .call: "звонок"
        }
    }
}

/// Категория приложения по bundle id (потом по `LSApplicationCategoryType` из Info.plist) и списки «никогда».
public enum AppCatalog {
    /// Capri, системные служебные окна, вход, пароли, лаунчеры-строки поиска: здесь не сидит никогда.
    public static let never: Set<String> = [
        "local.capri",
        "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver", "com.apple.Spotlight",
        "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent",
        "com.apple.coreservices.uiagent", "com.apple.WindowManager", "com.apple.ScreenSaver.Engine",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences.SecurityPrivacyExtension",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.Dashlane",
        "me.proton.pass.electron", "com.raycast.macos", "com.runningwithcrayons.Alfred",
    ]

    /// Звонки: переднее такое приложение — тишина (и `CallGuard`).
    public static let calls: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "Cisco-Systems.Spark", "com.skype.skype", "com.tinyspeck.slackmacgap.huddle",
    ]

    static let byBundle: [String: AppCategory] = {
        var m: [String: AppCategory] = [:]
        func put(_ c: AppCategory, _ ids: [String]) { for id in ids { m[id.lowercased()] = c } }
        put(.browser, ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
                       "org.mozilla.firefox", "ru.yandex.desktop.yandex-browser", "com.kagi.kagimacOS", "com.brave.Browser",
                       "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
                       "org.chromium.Chromium"])
        put(.messenger, ["ru.keepcoder.Telegram", "com.tdesktop.Telegram", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
                         "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "com.viber.osx",
                         "org.whispersystems.signal-desktop"])
        put(.mail, ["com.apple.mail", "com.readdle.smartemail-Mac", "com.microsoft.Outlook", "com.apple.iCal",
                    "com.flexibits.fantastical2.mac", "com.superhuman.electron", "ru.yandex.mail", "com.google.Gmail"])
        put(.ide, ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                   "dev.zed.Zed", "com.panic.Nova", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm",
                   "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider", "com.google.android.studio",
                   "com.sublimetext.4", "com.exafunction.windsurf", "com.openai.codex", "com.anthropic.claudefordesktop"])
        put(.terminal, ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
                        "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable"])
        put(.design, ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.pixelmatorteam.pixelmator.x",
                      "com.adobe.Photoshop", "com.adobe.illustrator", "com.seriflabs.affinitydesigner2",
                      "com.seriflabs.affinityphoto2", "com.apple.Preview", "com.blender.blender", "com.apple.FinalCut"])
        put(.finance, ["com.apple.stocks", "com.moneymoney-app.retail", "com.tinkoff.investing", "ru.sberbank.online",
                       "com.binance.BinanceDesktop", "com.tradingview.tradingviewapp.desktop", "com.apple.Numbers",
                       "com.microsoft.Excel"])
        put(.video, ["com.apple.TV", "org.videolan.vlc", "com.colliderli.iina", "com.netflix.Netflix",
                     "com.apple.QuickTimePlayerX", "tv.twitch.studio", "com.obsproject.obs-studio"])
        put(.notes, ["com.apple.Notes", "md.obsidian", "notion.id", "com.apple.iWork.Pages", "com.microsoft.Word",
                     "net.shinyfrog.bear", "com.apple.reminders", "com.apple.TextEdit", "com.craft.craft", "com.logseq.logseq"])
        put(.files, ["com.apple.finder", "com.binarynights.ForkLift", "com.panic.transmit", "com.apple.archiveutility"])
        put(.settings, ["com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.Console", "com.apple.DiskUtility"])
        put(.music, ["com.spotify.client", "com.apple.Music", "com.apple.podcasts", "ru.yandex.music"])
        put(.game, ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "net.battle.app", "com.blizzard.bna",
                    "com.gog.galaxy", "com.apple.Chess", "com.riotgames.RiotGames.RiotClient"])
        for id in calls { m[id.lowercased()] = .call }
        return m
    }()

    /// Категория: по bundle id (без учёта регистра), иначе по `LSApplicationCategoryType`, иначе «прочее».
    public static func category(bundle: String, lsCategory: String? = nil) -> AppCategory {
        if let c = byBundle[bundle.lowercased()] { return c }
        guard let ls = lsCategory?.lowercased() else { return .other }
        if ls.hasSuffix("-games") || ls == "public.app-category.games" { return .game }
        switch ls {
        case "public.app-category.developer-tools": return .ide
        case "public.app-category.graphics-design", "public.app-category.photography": return .design
        case "public.app-category.finance", "public.app-category.business": return .finance
        case "public.app-category.video", "public.app-category.entertainment": return .video
        case "public.app-category.music": return .music
        case "public.app-category.social-networking": return .messenger
        case "public.app-category.productivity": return .notes
        case "public.app-category.utilities": return .files
        default: return .other
        }
    }

    /// Можно ли вообще садиться на это приложение: не «никогда», не игра, не звонок, не в списке человека.
    public static func allowed(bundle: String, category: AppCategory, userBlocked: Set<String>) -> Bool {
        reason(bundle: bundle, category: category, userBlocked: userBlocked) == nil
    }

    /// Почему нельзя (nil — можно): `never`, `game`, `call`, `blocked`.
    public static func reason(bundle: String, category: AppCategory, userBlocked: Set<String>) -> String? {
        if bundle.isEmpty || never.contains(bundle) || bundle.lowercased().hasPrefix("com.apple.loginwindow") { return "never" }
        if category == .game { return "game" }
        if category == .call { return "call" }
        if userBlocked.contains(bundle) { return "blocked" }
        return nil
    }
}
