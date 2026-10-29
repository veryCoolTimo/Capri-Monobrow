# Проверки Capri

## Этап 0 — спайки · 2026-10-29

Фикстуры для тестов Этапа 1: `apps/macos/Tests/CapriKitTests/Fixtures/`.
Код спайков: `spikes/`.

### 1. Notch-панель (Mac, macOS 27.0.1, MacBook Pro M4 Pro) — геометрия и отрисовка работают, наведение и клики не проверены вручную

Код: `apps/macos/Sources/CapriKit/NotchGeometry.swift` (чистая геометрия, 6 тестов в
`NotchGeometryTests`), спайк-приложение `apps/macos/Sources/NotchSpike/main.swift`.
Запуск: `scripts/mac.sh "bash spikes/notch/run.sh [--expanded] [--no-notch] [--screen N]"` —
собирает `dist/NotchSpike.app`, запускает и печатает диагностику `/tmp/capri-notch.json`.
Снимки: [свёрнутый](preview/notch-collapsed.png), [раскрытый](preview/notch-expanded.png),
[пилюля без выреза](preview/notch-pill.png).

| Проверка | Результат |
|---|---|
| Геометрия выреза | Встроенный дисплей 1512×982 pt @2x: `safeAreaInsets.top = 32`, `auxiliaryTopLeftArea = (0, 950, 663.5×32)`, `auxiliaryTopRightArea = (848.5, 950, 663.5×32)` → вырез `x 663.5…848.5` (185×32 pt). Строка меню 33 pt (`frame.maxY − visibleFrame.maxY`) — на 1 pt выше выреза |
| Панель над строкой меню | `NSPanel` borderless + nonactivating, level `mainMenu + 3 = 27` (строка меню — слой 24 у WindowServer), `constrainFrameRect` не даёт AppKit увести окно ниже меню. По `CGWindowList`: слой 27, bounds `Y = 0`, на экране. На снимке чёрная полоса продолжает вырез поверх строки меню |
| Свёрнутый вид | 338×32 pt по центру выреза, по бокам иконка и счётчики |
| Раскрытый вид (`--expanded`) | 440×320 pt, прижат к верху экрана, центр по вырезу; список «ждут меня» рисуется |
| Экран без выреза (`--no-notch`) | Пилюля 200×26 pt по центру под строкой меню (`y = visibleFrame.maxY − 26`) |
| Фокус | `canBecomeKey == false`: панель не забирает фокус у текущего приложения |
| Тесты | `npm run test:macos` — 10/10 |

**Найдено:**
- `auxiliaryTop*Area` на основном экране совпадают с глобальными координатами (origin экрана 0,0),
  поэтому нельзя отличить «локальные» от «глобальных». Геометрия считает так: если центр области
  не внутри `screen.frame`, это локальные координаты и добавляется origin экрана.
- AppKit округляет frame окна до целых точек, а вырез стоит на полуточках (663.5). Рамки
  округляются наружу (`.integral`), чтобы вырез был закрыт целиком.
- `screencapture` из ssh не работает (`could not create image from display`); работает из
  Terminal (`open -a Terminal x.command`), но на macOS 27 Terminal запросил разрешение «обойти
  системный выбор окна» — **на экране Мака остался системный диалог, его нужно закрыть**.
  Дальше скриншоты — только с согласия Тимофея.

**Не проверено (нужны глаза/руки Тимофея):**
- Раскрытие по наведению и сворачивание при уходе мыши (`NSTrackingArea .activeAlways`) —
  синтетические события мыши требуют Accessibility, не давали.
- Клики мимо панели проходят насквозь: окно размером ровно с видимую форму, поэтому мимо него
  клики идут в другие окна; прозрачные углы скругления — по опыту прототипа WindowServer
  пропускает (alpha 0). Нужно кликнуть рядом с панелью в строку меню и в окно под раскрытой панелью.
- Полноэкранные приложения (`.fullScreenAuxiliary`, `.canJoinAllSpaces`) и строка меню с
  автоскрытием.
- Внешний монитор: не подключён. Нужно проверить координаты `auxiliaryTop*Area` и пилюлю на
  экране с отрицательным origin (`--screen 1`).

### 2. Хуки Claude Code и Codex — работают на Маке и timoserver

Скрипты: `spikes/hooks/` — `record.py` (пишет stdin/argv/env хука в JSONL, всегда exit 0),
`claude-settings.json` (все события → record.py), `codex-hooks.json` (проектные хуки Codex),
`start-codex.sh`, `setup-testdir.sh` (готовит `~/capri-test-hooks`), `make-fixtures.py`
(обезличивание). Глобальные `~/.claude/settings.json` и `~/.codex/*` не менялись:
Claude запускался с `--settings ~/capri-test-hooks/claude-settings.json`, Codex — с проектным
`./.codex/hooks.json`, `--dangerously-bypass-hook-trust` (доверие не пишется в конфиг) и
`-c notify=[...]` только на запуск. Сессии: tmux `capri-test-claude`, `capri-test-codex`.

Фикстуры: `Fixtures/hooks/{claude,codex}-{mac,server}.jsonl`, `claude-mac-stopfailure.jsonl`,
снимки экрана `Fixtures/hooks/screens/` (диалоги разрешений, работает, прерван, простой).
Формат строки: `{ts, host, label:"<agent>:<Event>", argv, stdin, env}`.

Версии: Claude Code 2.1.310 (Mac), 2.1.295 (timoserver), модель haiku; Codex 0.147.0 (Mac),
0.151.0 (timoserver), gpt-5.6-sol.

**Claude Code — наблюдаемые последовательности**

| Сценарий | События (Δ от начала) |
|---|---|
| Запрос разрешения Bash → «1 Yes» | `UserPromptSubmit` → `PreToolUse` (+1.8 с) → `PermissionRequest` (+0.06 с) → `Notification{notification_type:"permission_prompt", message:"Claude needs your permission"}` (**+6.0 с после PermissionRequest**) → ответ → `PostToolUse` → `Stop` → `SubagentStop` |
| Простой после `Stop` | `Notification{notification_type:"idle_prompt", message:"Claude is waiting for your input"}` через ~60 с |
| AskUserQuestion | `PreToolUse` + `PermissionRequest` с `tool_name:"AskUserQuestion"` и `tool_input.questions[{question, header, options[{label,description}], multiSelect}]` → `Notification permission_prompt` (+6 с). После ответа `PostToolUse.tool_input.answers{вопрос: ответ}` |
| Разрешение «4 No» | **Ничего**: ни `Stop`, ни `PermissionDenied`, ни `idle_prompt` (ждали >2 мин). Экран: `Interrupted · What should Claude do instead?` |
| Esc во время ответа | **Ничего** после `UserPromptSubmit`. Экран: `Interrupted · What should Claude do instead?` |
| `/exit` | `SessionEnd{reason:"prompt_input_exit"}` |
| Не залогинен | `StopFailure{error:"authentication_failed", last_assistant_message:"Not logged in · Please run /login"}` |

Поля: везде `session_id`, `transcript_path`, `cwd`, `hook_event_name`; с хода — `prompt_id`,
`permission_mode`, `effort`. `SessionStart` даёт `source`, `model`. `Stop` даёт
`last_assistant_message`, `stop_hook_active`, `background_tasks`, `session_crons`.
`PermissionRequest` даёт `tool_input` и `permission_suggestions`. В env хука:
`TMUX_PANE`, `TMUX`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PROJECT_DIR`.

**Codex — наблюдаемые последовательности** (события хуков: SessionStart, SessionEnd,
UserPromptSubmit, Stop, PreToolUse, PostToolUse, PermissionRequest, SubagentStart/Stop,
Interrupt, PreCompact/PostCompact; события `Notification` нет)

| Сценарий | События |
|---|---|
| Первый промпт | `SessionStart{source:"startup"}` приходит **только с первым ходом**, не при запуске TUI |
| Запрос разрешения → «1 Yes» | `UserPromptSubmit` → `PreToolUse` → `PermissionRequest{tool_input:{command, description}}` (сразу, без задержки) → `PostToolUse` → `Stop{last_assistant_message}` → notify |
| Разрешение → Esc (отказ) | `Interrupt` (без `Stop` и notify). Экран: `■ Conversation interrupted` |
| `/quit` | `Interrupt` (если был незавершённый ход) → `SessionEnd{reason:"other"}` |

Поля Codex: `session_id` (= `thread-id` в notify), `turn_id`, `transcript_path`, `cwd`,
`hook_event_name`, `model`, `permission_mode`. `TMUX_PANE` в env есть.
notify: JSON последним аргументом argv: `{type:"agent-turn-complete", thread-id, turn-id, cwd,
client:"codex-tui", input-messages[], last-assistant-message}`.

**Найдено (важно для Этапа 1):**
- Самый быстрый сигнал «ждёт меня» у Claude — `PermissionRequest`, а не `Notification`
  (та приходит на ~6 с позже). Брать `PermissionRequest` → `needs_input`, `Notification` —
  подтверждение и текст.
- AskUserQuestion приходит как `PermissionRequest` с вопросами и вариантами — можно сразу
  рисовать кнопки в notch.
- **Отказ в разрешении и Esc не дают никакого хука у Claude** — состояние застрянет в
  `needs_input`/`running`. Нужен фолбэк по экрану (`Interrupted ·`) или по следующему
  `UserPromptSubmit`. У Codex есть `Interrupt`.
- Codex 0.151 шлёт notify и для **служебного хода генерации заголовка** (другой
  `thread-id`, `input-messages` начинается с `Generate a concise, single-line task title`).
  Фильтровать: учитывать notify только для известных `session_id` из хуков. В 0.147 такого нет.
- В строке ввода Claude после ответа бывает **серая подсказка** (`❯ show the contents of
  stamp.txt`), у Codex — плейсхолдер (`› Write tests for @filename`). Проверка «нет чужого
  набранного текста» по `capture-pane -p` их не отличит — нужен `capture-pane -e` (цвета)
  или другой признак.
- Подсказки генерирует субагент — отсюда `SubagentStop` с `agent_type:""` после каждого
  `Stop` у Claude. Не путать с концом хода.
- Маркер «работает» у Claude 2.1.x — в нижней строке: `esc to interrupt`.
- Диалог доверия папке и диалог MCP-серверов проекта у Claude не дают хуков (только экран).
  Курсор по умолчанию в диалоге доверия на `No, exit`.

**Неизвестные:**
- Claude на Маке, запущенный в tmux-сервере, поднятом **из ssh**, не видит Keychain →
  `Not logged in`. Тестовый tmux пришлось стартовать через `open -a Terminal x.command`.
  Для Capri это не мешает (сессии Тимофея запущены из GUI), но «Открыть»/перезапуск сессий
  из Capri должны стартовать tmux в GUI-контексте.
- Есть ли у Claude `idle_prompt` после отказа/прерывания при более долгом ожидании — нет за 2 мин.
- Codex: Esc во время потокового ответа не дал `Interrupt` сразу (пришёл только при `/quit`) —
  повторить.
- Хуки Codex на quiz не проверялись (план: Mac и timoserver).

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
