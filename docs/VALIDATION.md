# Проверки Capri

## Этап 0 — спайки · 2026-10-29

Фикстуры для тестов Этапа 1: `apps/macos/Tests/CapriKitTests/Fixtures/`.
Код спайков: `spikes/`.

### 3. `codex app-server` (Mac, codex-cli 0.147.0 из Homebrew) — работает

Скрипт: `spikes/codex-app-server/spike.py` (python3, stdio JSON-RPC, одна строка = одно сообщение).
Прогон: `scripts/mac.sh "python3 spikes/codex-app-server/spike.py"`.
Запись обмена: `Fixtures/codex-app-server/spike-turn.jsonl` (email заменён, шумные
`mcpServer/startupStatus/updated` выкинуты).

| Шаг | Результат |
|---|---|
| `generate-ts` / `generate-json-schema` | Работают: 93 файла + `v2/` (550), ~2.6 МБ TS. В репозиторий не кладём — генерировать заново под версию CLI |
| `initialize` | ~0.3–0.5 с. Ответ: `userAgent`, `codexHome`, `platformOs`. После него клиент шлёт уведомление `initialized` |
| `account/read` `{refreshToken:false}` | 7–9 мс. `{account:{type:"chatgpt", email, planType:"plus"}, requiresOpenaiAuth:true}`. auth.json не читали |
| `account/rateLimits/read` | ~0.5 с. `primary` (5 ч окно, `usedPercent`, `resetsAt`), `secondary` (неделя), `credits`, `planType` |
| `model/list` | `gpt-5.6-sol` (isDefault), `gpt-5.6-terra`, `gpt-5.6-luna` |
| `thread/start` `{ephemeral, approvalPolicy:"never", sandbox:"read-only", cwd:"/tmp", model}` | ~0.25 с |
| `turn/start` → `turn/completed` | 3.9 с, ответ `pong`. Текст ответа — `item/completed` с `item.type=="agentMessage"`, поток — `item/agentMessage/delta` |

Порядок уведомлений хода: `thread/started` → `thread/status/changed` → `turn/started` →
`hook/started`/`hook/completed` (пользовательский SessionStart-хук из `~/.codex/hooks.json`) →
`item/started`/`item/completed` (userMessage) → `item/agentMessage/delta` → `item/completed`
(agentMessage) → `thread/tokenUsage/updated` → `account/rateLimits/updated` → `turn/completed`.

Ключевые методы для Capri: `initialize`, `account/read`, `account/login/start|cancel`,
`account/logout`, `account/rateLimits/read`, `model/list`, `thread/start`, `turn/start`,
`turn/interrupt`, `hooks/list`. Уведомления: `account/updated`, `account/login/completed`,
`account/rateLimits/updated`, `turn/completed`, `item/completed`, `error`.
Запросы сервера к клиенту (approval): `item/commandExecution/requestApproval`,
`item/fileChange/requestApproval`, `item/permissions/requestApproval`, `item/tool/requestUserInput`.

**Найдено:**
- Модель из `~/.codex/config.toml` (`gpt-6.1-sol`) CLI 0.147 не принимает: ход падает с
  `400 model_not_found ... not supported when using Codex with a ChatGPT account`.
  Capri должен явно передавать модель из `model/list` (isDefault), а не полагаться на конфиг.
- app-server поднимает **все MCP-серверы пользователя** (13 шт., perplexity падает) и
  **выполняет пользовательские хуки** Codex на каждом треде. Для служебных сводок Capri это
  лишняя нагрузка и побочные эффекты.
- В ChatGPT.app лежит свой CLI `codex-cli 0.163.0-alpha.11.2`
  (`/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`),
  Homebrew — 0.147.0, на timoserver — 0.151.0. Схема у версий может различаться.

**Неизвестные:**
- Как отключить MCP-серверы и хуки для треда Capri (`-c mcp_servers=...`, `config` в
  `thread/start`?) — не проверено.
- `account/login/start` (вход через браузер) не проверяли: аккаунт уже залогинен, выход
  из него сломал бы CLI Тимофею. Проверить на отдельном `CODEX_HOME` в Этапе 4.
- Какой бинарь брать: Homebrew или из ChatGPT.app (новее). Решить в Этапе 4.

---

## Проверка прототипа · 2026-10-27

### Результат

Первый запускаемый срез собран и открыт на текущем Mac. Это рабочая оболочка с демосессиями; весь MVP и полный acceptance CAPRI-001 ещё не закрыты.

| Проверка | Результат |
|---|---|
| `npm test` | 10/10 проходят: dedupe, stale events, разные sessions, completed/disconnected, новый turn, approval matching и приоритеты |
| `npm run typecheck` | Проходит, TypeScript 7.0.2 |
| `npm run test:macos` | 4/4 XCTest: экран с отрицательными координатами, ограничение окна, alpha map/Y origin, истечение скрытия |
| `npm run build:macos` | Release arm64 собран, ad-hoc подпись проверена через codesign |
| Запуск из `.app` без `.build` и node_modules | Успешно: ресурсы загружаются из самой сборки |
| WebGL | `webgl: true`, 34 отрисованных кадра за первый диагностический интервал, состояние `approval` |
| Native background hit | WindowServer пропускает прозрачный угол мимо обеих панелей |
| Native sprite hit | Точка на теле попадает в нативную панель ввода |
| Keyboard focus | Overlay `canBecomeKey == false` |
| Деморазрешение | Запрос исчезает, сценарий переходит running → completed; внешняя команда не запускается |
| Observed | Поле ввода и запуск сценария недоступны |
| Ввод в controllable демосессию | Сообщение появилось в истории выбранной сессии, поле очистилось, сценарий запустился |
| ⌘V и ⌘Q | Вставка текста и штатное завершение проверены через UI |
| Настройки | Через UI проверены большой/средний размер, hide/show и teleport |

Живой checker: `node scripts/check-diagnostics.mjs docs/preview`. Он проверяет реальные данные запуска, а не статический fixture. Для нового прогона предварительно экспортировать диагностику из `.app` по инструкции в README.

Снимки собственного приложения: [окно сессий](preview/dashboard.png), [WebGL персонаж](preview/character.png). Диагностика: [renderer.json](preview/renderer.json), [native.json](preview/native.json).

### Нагрузка: короткий снимок, не energy benchmark

`ps` после запуска с открытым окном сессий, спрайт 12 fps, размер medium:

| Процесс | RSS | CPU в снимке |
|---|---:|---:|
| Capri | ~114 MiB | 1.7% |
| WebKit GPU | ~28 MiB | 1.0% |
| WebKit WebContent | ~30 MiB | 1.1% |
| WebKit Networking | ~18 MiB | 0.0% |

RSS включает разделяемые страницы; это не измерение уникальной физической памяти. CPU — проценты одного ядра в конкретном снимке. Потребление батареи и длительная idle-нагрузка не измерены.

### Исправлено по живому запуску и ревью

- Отдельный UserDefaults suite вместо совпадающего с bundle ID; убран crash на запуске.
- Ресурсы лежат в Contents/Resources; подпись `.app` проверяется без unsealed-root ошибки.
- Texture передаётся в WebGL через data URI, чтобы не получать file-origin SecurityError.
- Нативная форма ввода отделена от WebKit; убрано переключение click-through по таймеру.
- Teleport выбирает новое место. Авторитетная реакция отменяет устаревшие callbacks; hide отменяет переход и снимает transient teleport state.
- Ответ на чужой approval ID не может очистить или заменить текущий запрос; добавлены два регрессионных теста.
- NSHostingView больше не увеличивает окно до его произвольного intrinsic height.
- Нативное меню включает edit-команды и штатный выход.

### До полного acceptance остаётся проверить

- Физический drag/click по всему силуэту, быстрые переходы между приложениями, изменённые позы и края экранов.
- Реальное засыпание/пробуждение, GPU context loss, fullscreen Spaces, внешний монитор и его отключение.
- Скрытие на час после перезапуска и фактическое автоматическое возвращение через 3600 секунд; сейчас unit-проверено правило времени, UI-проверены hide/show.
- Несколько копий приложения: использовать один экземпляр. Single-instance guard ещё не реализован.
- Длительную нагрузку, energy impact и battery-save mode.
- Настоящие агентские события, авторизацию и транспорт; всё это следующие P0/P2 билеты.

Нативный hotspot пока статичен и имеет небольшой запас вокруг исходного спрайта. На сильных деформациях он может расходиться с видимой позой; для полного движка нужен обновляемый hit pack или иной проверенный способ синхронизации формы.
