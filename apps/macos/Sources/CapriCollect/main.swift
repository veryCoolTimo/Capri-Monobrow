// CapriCollect — консольная проверка конвейера Этапа 1 без интерфейса.
// Подключается к хостам (`capri-hook stream` локально или по ssh), гонит события через
// SessionReducer и печатает переходы статусов с задержкой «событие на хосте → состояние в Capri».
//
//   CapriCollect --ssh timoserver [--hook 'python3 ~/x/capri-hook'] --local [--hook '...'] [--only-sessions capri-test-]
//   --state PATH   куда писать снимок состояния (JSON, права 0600), по умолчанию $TMPDIR/capri-state.json
//   --seconds N    выйти через N секунд
// Выход: Ctrl-C.
import AppKit
import CapriKit

var sources: [HostSource] = []
var statePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("capri-state.json")
var seconds: Double?
var onlySessions: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--ssh":
        let host = args.removeFirst()
        guard HostSource.isValidAlias(host) else { FileHandle.standardError.write("плохой хост: \(host)\n".data(using: .utf8)!); exit(2) }
        sources.append(.ssh(host))
    case "--local":
        sources.append(.local())
    case "--hook":
        guard !sources.isEmpty else { FileHandle.standardError.write("--hook идёт после --ssh/--local\n".data(using: .utf8)!); exit(2) }
        sources[sources.count - 1].hook = args.removeFirst()
    case "--only-sessions": onlySessions = args.removeFirst()
    case "--state": statePath = args.removeFirst()
    case "--seconds": seconds = Double(args.removeFirst())
    default:
        FileHandle.standardError.write("неизвестный аргумент \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}
if sources.isEmpty { sources = [.local()] }
if let onlySessions { for i in sources.indices { sources[i].streamArgs = ["--only-sessions", onlySessions] } }

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
var state = CapriState()
let started = Date()

func stamp() -> String { String(format: "%7.2f", Date().timeIntervalSince(started)) }

func describe(_ s: Session) -> String {
    var line = "\(s.key) [\(s.title)] \(s.status.rawValue) (\(s.confidence.rawValue))"
    if let r = s.request { line += " · \(r.kind.rawValue): \(r.summary.prefix(60))" }
    if let o = s.request?.options, !o.isEmpty { line += " · варианты: \(o.joined(separator: " / "))" }
    if let t = s.typedInput { line += " · набрано: «\(t)»" }
    if let p = s.tmux { line += " · tmux \(p.session ?? "?") \(p.pane)" }
    return line
}

func dump() {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    struct Out: Encodable { var hosts: [String: HostState]; var sessions: [Session]; var waiting: [SessionKey] }
    let out = Out(hosts: state.hosts, sessions: state.sessions.values.sorted { $0.key.description < $1.key.description },
                  waiting: state.waiting.map(\.key))
    // В состоянии команды и набранный текст — файл только для владельца.
    if let d = try? enc.encode(out) {
        FileManager.default.createFile(atPath: statePath, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

func feed(_ input: CapriInput) {
    let before = state.sessions
    let effects = SessionReducer.reduce(&state, input)
    let now = Date().timeIntervalSince1970
    for (key, s) in state.sessions where before[key]?.status != s.status || before[key]?.request != s.request {
        var lag = ""
        if case let .event(_, e, replay) = input, !replay { lag = String(format: " · задержка %.2f с", now - e.ts) }
        if case let .screen(_, _, _, _, ts) = input { lag = String(format: " · по экрану, снят %.2f с назад", now - ts) }
        print("\(stamp()) \(describe(s))\(lag)")
    }
    for key in before.keys where state.sessions[key] == nil { print("\(stamp()) \(key) убрана") }
    for e in effects {
        if case let .notifyNeedsInput(key) = e { print("\(stamp()) 🔔 ЖДЁТ МЕНЯ: \(key)") }
    }
    if case let .connection(host, c, _) = input { print("\(stamp()) хост \(host): \(c ? "подключён" : "отключён")") }
    dump()
}

let supervisor = CollectorSupervisor(sources: sources, onInput: feed)
supervisor.onLog = { print("\(stamp()) \($0)") }
supervisor.start()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in feed(.tick(Date().timeIntervalSince1970)) }
if let seconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { supervisor.stop(); exit(0) }
}
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { supervisor.stop(); exit(0) }
sigint.resume()
RunLoop.main.run()
