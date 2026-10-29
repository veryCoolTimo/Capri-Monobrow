import Foundation
import Combine

enum DemoState: String {
    case working, approval, completed, observed
    var label: String {
        switch self { case .working: return "Работает"; case .approval: return "Ждёт решения"; case .completed: return "Готово"; case .observed: return "Наблюдение" }
    }
    var character: String {
        switch self { case .working: return "working"; case .approval: return "approval"; case .completed: return "success"; case .observed: return "idle" }
    }
}
struct DemoSession: Identifiable {
    let id: String
    let agent: String
    let symbol: String
    let project: String
    let task: String
    let host: String
    let control: String
    var state: DemoState
    var summary: String
    var events: [String]
    var pendingID: UUID?
    var canSend: Bool { control != "Observed" && pendingID == nil }
}

final class DemoStore: ObservableObject {
    @Published var sessions: [DemoSession] = [
        DemoSession(id: "codex", agent: "Codex", symbol: "command", project: "capri", task: "Нативная оболочка персонажа", host: "Этот Mac", control: "Managed", state: .approval,
            summary: "Оболочка собрана. В демосценарии Codex просит разрешить запуск локальных проверок.",
            events: ["Прочитал спецификацию", "Собрал прозрачное окно", "Ожидает деморазрешение: swift test"], pendingID: UUID()),
        DemoSession(id: "claude", agent: "Claude Code", symbol: "asterisk", project: "website", task: "Проверка навигации", host: "Этот Mac", control: "Observed", state: .observed,
            summary: "Пример внешней сессии. Capri может показывать вывод и сводку; отправка команд недоступна, пока владение сессией не подтверждено.",
            events: ["Обнаружена внешняя сессия", "Доступен режим наблюдения"]),
        DemoSession(id: "tmux", agent: "tmux", symbol: "terminal", project: "api-service", task: "Проверка после сборки", host: "dev-server", control: "Controllable tmux", state: .completed,
            summary: "Пример подключённой tmux-сессии на сервере. Последний демонстрационный прогон завершён.",
            events: ["Сессия явно привязана пользователем", "Демопрогон завершён"])
    ]
    @Published var selectedID = "codex"
    @Published var composer = ""
    @Published var attentionOnly = false
    @Published var notice: String?
    var onReaction: ((String) -> Void)?
    private var scenarioGeneration: [String: UUID] = [:]
    var selected: DemoSession { sessions.first(where: { $0.id == selectedID }) ?? sessions[0] }
    var visible: [DemoSession] { attentionOnly ? sessions.filter { $0.pendingID != nil } : sessions }
    var attentionCount: Int { sessions.filter { $0.pendingID != nil }.count }

    func select(_ id: String) { selectedID = id; composer = ""; notice = nil; onReaction?(selected.state.character) }
    func resolveApproval(allow: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedID }), sessions[index].pendingID != nil else { return }
        sessions[index].pendingID = nil
        sessions[index].events.append(allow ? "Деморазрешение принято один раз" : "Деморазрешение отклонено")
        if allow { runScenario(id: selectedID) }
        else { sessions[index].state = .completed; sessions[index].summary = "Демооперация отменена. Никакие команды не запускались."; onReaction?("idle") }
    }
    func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, selected.canSend else { return }
        let id = selectedID
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].events.append("Ты: \(text)")
        composer = ""
        runScenario(id: id)
    }
    func runScenario(id: String? = nil) {
        let id = id ?? selectedID
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].control != "Observed", sessions[index].pendingID == nil else {
            notice = "Сначала ответь на демозапрос или выбери управляемую демосессию."; return
        }
        let generation = UUID(); scenarioGeneration[id] = generation
        sessions[index].state = .working
        sessions[index].summary = "Демосценарий выполняется. Реальные агенты и терминалы не подключены."
        sessions[index].events.append("Запущен локальный UI-сценарий")
        onReaction?("thinking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.scenarioGeneration[id] == generation else { return }
            if self.selectedID == id { self.onReaction?("working") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, self.scenarioGeneration[id] == generation,
                  let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
            self.sessions[index].state = .completed
            self.sessions[index].summary = "Демосценарий завершён. Здесь будет сводка настоящего агента: что изменилось и что требует твоего внимания."
            self.sessions[index].events.append("Демосценарий завершён")
            if self.selectedID == id { self.onReaction?("success") }
        }
    }
}
