import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Набор сборщиков по хостам + переподключение после сна Мака и при смене сети.
/// Создавать и вызывать с главного потока.
public final class CollectorSupervisor {
    public private(set) var collectors: [HostCollector]
    private let onInput: (CapriInput) -> Void
    private var started = false
    private let path = NWPathMonitor()
    private var lastPathSatisfied: Bool?
    private var lastInterfaces: [String] = []
    private var observers: [NSObjectProtocol] = []
    public var onLog: ((String) -> Void)?

    public init(sources: [HostSource], onInput: @escaping (CapriInput) -> Void) {
        self.onInput = onInput
        collectors = []
        collectors = sources.map(makeCollector)
    }

    private func makeCollector(_ source: HostSource) -> HostCollector {
        let c = HostCollector(source: source)
        c.onInput = onInput
        c.onLog = { [weak self] in self?.onLog?($0) }
        return c
    }

    /// Новый список хостов без перезапуска: прежние сборщики с тем же именем и способом связи остаются,
    /// убранные останавливаются, новые запускаются. Возвращает имена убранных хостов.
    @discardableResult
    public func setSources(_ sources: [HostSource]) -> [String] {
        var keep: [HostCollector] = []
        for src in sources {
            if let c = collectors.first(where: { $0.source.name == src.name && $0.source.transport == src.transport }) {
                keep.append(c)
            } else {
                let c = makeCollector(src)
                keep.append(c)
                if started { c.start() }
            }
        }
        let removed = collectors.filter { old in !keep.contains { $0 === old } }
        removed.forEach { $0.stop() }
        collectors = keep
        return removed.map(\.source.name)
    }

    public func start() {
        started = true
        collectors.forEach { $0.start() }
        #if canImport(AppKit)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reconnectAll(reason: "пробуждение")
        })
        #endif
        path.pathUpdateHandler = { [weak self] p in
            let satisfied = p.status == .satisfied
            let interfaces = p.availableInterfaces.map(\.name)
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPathSatisfied = satisfied; self.lastInterfaces = interfaces }
                guard let was = self.lastPathSatisfied else { return }   // первое срабатывание — исходное состояние
                if satisfied && (!was || interfaces != self.lastInterfaces) {
                    self.reconnectAll(reason: "сеть изменилась")
                }
            }
        }
        path.start(queue: DispatchQueue(label: "capri.network"))
    }

    public func stop() {
        started = false
        path.cancel()
        #if canImport(AppKit)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        #endif
        observers = []
        collectors.forEach { $0.stop() }
    }

    public func reconnectAll(reason: String) {
        onLog?("\(reason) — переподключаюсь")
        collectors.forEach { $0.reconnectNow() }
    }
}
