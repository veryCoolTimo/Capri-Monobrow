import AppKit
import CapriKit

/// Список пространств от WindowServer — приватные `CGSMainConnectionID` + `CGSCopyManagedDisplaySpaces` (без
/// разрешений). Ищем через `dlsym`: нет символа — нет снимка, эффект смены пространства просто симметричный.
enum WindowServerSpaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (ConnectionFn, CopySpacesFn)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        func sym(_ names: [String]) -> UnsafeMutableRawPointer? {
            for n in names { if let p = dlsym(handle, n) { return p } }
            return nil
        }
        guard let conn = sym(["CGSMainConnectionID", "SLSMainConnectionID"]),
              let copy = sym(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"]) else { return nil }
        return (unsafeBitCast(conn, to: ConnectionFn.self), unsafeBitCast(copy, to: CopySpacesFn.self))
    }()

    static var available: Bool { functions != nil }

    static func snapshot() -> SpaceSnapshot? {
        guard let (conn, copy) = functions else { return nil }
        let cid = conn()
        guard cid != 0, let list = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return SpaceSnapshot.parse(list)
    }

    /// UUID дисплея экрана (как `Display Identifier` в списке пространств).
    static func uuid(_ screen: NSScreen?) -> String? {
        guard let n = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }
}

/// Смена пространства (свайп между столами и полноэкранными приложениями): куда ехало и что теперь на экране notch.
/// Слушает только уведомление NSWorkspace — без таймеров.
final class SpaceWatcher {
    private var observer: NSObjectProtocol?
    private var last: SpaceSnapshot?
    private let screen: () -> NSScreen?
    /// Смена на экране notch (`elsewhere` сюда не попадает).
    var onChange: ((SpaceMove, Bool?) -> Void)?
    var log: ((String) -> Void)?

    init(screen: @escaping () -> NSScreen?) { self.screen = screen }

    func start() {
        last = WindowServerSpaces.snapshot()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in self?.changed() }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func changed() {
        let now = WindowServerSpaces.snapshot()
        let change = Spaces.change(from: last, to: now, display: WindowServerSpaces.uuid(screen()))
        if now != nil { last = now }
        log?("space \(change)")
        if case .moved(let move, let fullscreen) = change { onChange?(move, fullscreen) }
    }

    /// Для `spaces` в отладке: список пространств дисплея notch и текущее.
    func describe() -> String {
        guard let s = WindowServerSpaces.snapshot() else { return "spaces: нет CGS" }
        let uuid = WindowServerSpaces.uuid(screen())
        return s.displays.map { d in
            let mark = d.display == uuid ? " (notch)" : ""
            let list = d.spaces.map { "\($0.id)\($0.fullscreen ? "f" : "")\($0.id == d.current ? "*" : "")" }.joined(separator: " ")
            return "display \(d.display.prefix(8))…\(mark): \(list)"
        }.joined(separator: "; ")
    }
}
