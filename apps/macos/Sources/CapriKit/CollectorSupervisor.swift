import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Набор сборщиков по хостам + переподключение после сна Мака и при смене сети.
/// Создавать и вызывать с главного потока.
public final class CollectorSupervisor {
    public let collectors: [HostCollector]
    private let path = NWPathMonitor()
    private var lastPathSatisfied: Bool?
    private var lastInterfaces: [String] = []
    private var observers: [NSObjectProtocol] = []
    public var onLog: ((String) -> Void)?

    public init(sources: [HostSource], onInput: @escaping (CapriInput) -> Void) {
        collectors = sources.map(HostCollector.init(source:))
        for c in collectors {
            c.onInput = onInput
            c.onLog = { [weak self] in self?.onLog?($0) }
        }
    }

    public func start() {
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
