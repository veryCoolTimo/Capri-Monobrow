# Проверки Capri

## Этап 1 — конвейер событий · 2026-10-29

**Итог:** конвейер работает на тестовых сессиях `capri-test-*` (timoserver по ssh и локально
на Маке): запрос разрешения попадает в состояние Capri на Маке за **0.07–0.16 с** (цель ≤3 с),
одно уведомление на переход. Реальная установка хуков на Мак, timoserver и quiz **не делалась** —
ждёт «да» Тимофея; пробные diff — в `work/install-dry-run/` (вне репозитория).

### Состав

| Часть | Где | Что делает |
|---|---|---|
| `capri-hook` | `tools/capri-hook/capri-hook` (python ≥3.9) | хук: stdin → строка в `~/.capri/events.jsonl` (+ `ts`, `host`, `agent`, tmux-панель и сессия); большие поля режутся, `tool_response` выбрасывается; ничего не печатает, всегда exit 0; ротация >5 МБ → `.1` под `flock` |
| `capri-hook stream` | там же | снимок (последние 300 событий, `tmux list-panes`, экраны панелей агентов с ANSI) → `snapshot-end` → поток новых строк (опрос 0.2 с, переживает ротацию), панели раз в 5 с, экраны раз в 2 с только при изменении, heartbeat 15 с. Панель агента определяется по дереву процессов (`ps`), а не по `pane_current_command` |
| установщик | `capri-hook install/uninstall/status`, `scripts/install-hooks.sh <host> --dry-run/--apply/--uninstall` | сливает хуки, добавляя **в конец** массивов событий; бэкап `*.capri-bak-<время>` рядом; удаляет только свои записи; копирует себя в `~/.capri/bin` |
| доверие хукам Codex | там же | после записи `hooks.json` спрашивает `codex app-server` `hooks/list` и пишет `hooks.state.<key>.trusted_hash` через `config/value/write` (upsert) — TOML правит сам Codex; бэкап `config.toml` |
| модель и reducer | `CapriKit/CapriEvent.swift`, `SessionReducer.swift` | события → сессии `host+agent+session_id`, статусы, запрос (команда / вопрос с вариантами), эффект «уведомить» |
| фолбэк по экрану | `CapriKit/ScreenClassifier.swift` | ANSI-разбор: работа (`esc to interrupt`), диалог (варианты `1. …`), ожидание ввода и **набранный текст без dim-подсказки** |
| сбор | `CapriKit/HostCollector.swift` | процесс `capri-hook stream` локально или по ssh (`BatchMode`, `ServerAliveInterval=15`), backoff 1→30 с, сторож молчания 45 с, `reconnectNow()` на пробуждение |
| проверка | `CapriCollect` (CLI) | печатает переходы и задержку «событие на хосте → состояние на Маке», пишет `/tmp/capri-state.json` |

Тесты: `python3 -m unittest discover -s tools/capri-hook` — 28 (timoserver python 3.12 и Мак
системный 3.9; доверие Codex проверяется настоящим `codex app-server` на временном `CODEX_HOME`;
стресс-тест 6 писателей × 60 строк через ротацию — ни одной потери);
`npm run test:macos` — 45 XCTest, из них 29 на записанных фикстурах
(`Fixtures/events/*.jsonl` — формат capri-hook, `Fixtures/screens-ansi/*.ansi` — 16 экранов).

### Правила статусов (с учётом находок Этапа 0)

- `needs_input` берётся с `PermissionRequest` (Claude и Codex), `Notification permission_prompt`
  только подтверждает и не даёт второго уведомления. AskUserQuestion — запрос с вариантами.
- `UserPromptSubmit`/`PostToolUse` → `running`; `Stop`/`Interrupt` → `idle`; `StopFailure` →
  `error`/`rate_limited`; `SessionEnd` или исчезнувшая панель → `ended`.
- Отказ в разрешении и Esc у Claude хуков не дают: если экран панели показывает ожидание ввода
  при статусе `running`/`needs_input`, через 3 с (и не раньше 1 с после смены статуса) сессия
  становится `idle` с `confidence: inferred`. Свежий хук всегда сильнее экрана.
- notify Codex: учитывается только для известных сессий; ход генерации заголовка
  (`Generate a concise, single-line task title…`) отбрасывается.
- Сессия без хуков видна по экрану как `pane:%N` (`inferred`); когда из той же панели приходит
  хук — сливается с настоящей.
- Повтор журнала после переподключения дедуплицируется и уведомлений не даёт.
- Обрыв хоста не стирает статусы сессий.

### Сквозная проверка (CapriCollect на Маке)

| Сценарий | Результат |
|---|---|
| Claude на timoserver: запрос разрешения | `needs_input`, задержка 0.12 с, одно 🔔 |
| Claude на timoserver: отказ через Esc | `idle (inferred)` через ~6–7 с (снимок экрана раз в 2 с + пауза 3 с) |
| Codex на timoserver: разрешение → «1» | `needs_input` 0.13 с → `running` → `idle` |
| Codex 0.151: Esc во время ответа | хук `Interrupt` есть (в Этапе 0 было под вопросом) |
| Claude на Маке (локальный источник): разрешение → «1» | `needs_input` 0.07 с → `running` → `idle` |
| Обрыв потока (убит удалённый процесс) | переподключение через 1–4 с, снимок, статусы сохранены |
| Полный повтор журнала при подключении | промежуточные статусы без уведомлений; устаревший `needs_input` после отказа исправлен экраном за ~4 с |
| Запрос разрешения Codex **во время обрыва** (поток 20 с убивался в цикле) | после переподключения `needs_input (hook)` и одно 🔔 — событие из снимка, случившееся без связи, считается живым |
| Хук недоступен, сессия ждёт разрешения | `needs_input (inferred)` по экрану + 🔔 |

**Не проверено вживую:** сон/пробуждение Мака (код: `NSWorkspace.didWakeNotification` →
`reconnectNow()`, плюс ServerAlive/сторож 45 с), обрыв Wi‑Fi, quiz (нужна установка), Codex
notify-обёртка на реальном конфиге (по умолчанию выключена — хватает хука `Stop`).

### Ревью (2 агента) и исправления

Найдено и исправлено до установки на хосты:

- **Гонка ротации журнала** (подтверждена стресс-тестом): писатель, ждавший замок, писал в уже
  повёрнутый файл или затирал `.1`. Теперь после захвата `flock` сверяется inode; замок с таймаутом 1 с.
- **Follower терял хвост** старого файла при ротации — теперь дочитывает перед переключением.
- **Протокол:** `hello` несёт `proto`/`version`/`now`, heartbeat и `snapshot-end` — `now`; у события
  `id` (дедуп по нему, а не по `ts` с точностью до мс). Capri отказывается от несовместимого
  протокола и переводит время хоста в часы Мака (сдвиг из hello/heartbeat) — пауза «ждёт ввода»
  больше не зависит от расхождения часов.
- **Пропущенное за время обрыва/сна уведомляется:** событие из снимка после переподключения,
  случившееся без связи, обрабатывается как живое.
- **Приватность:** в журнал пишется только белый список полей: без промптов, без `tool_response`,
  без содержимого Write/Edit; из запроса разрешения — `command`/`description`/`file_path`/`url`/
  `questions`. `~/.capri` — 0700, журнал — 0600, строки только ASCII (переживают любую локаль ssh).
- **Снимок при подключении** — последние 30 событий каждой сессии из `.1` и текущего файла
  (а не 300 последних строк): давно ждущая сессия не теряется.
- **Неизменный экран** переотправляется раз в 10 с; ожидание подтверждения сбрасывается только
  сменой статуса и перезапускается, если устарело — `needs_input` не залипает после отказа,
  даже если `Notification` пришла позже.
- **Установщик:** путь хука в `shlex.quote`; доверие Codex — только записям из нашего `hooks.json`
  с точной командой; уже стоящая наша запись не двигается (индексы чужих хуков и их доверие
  сохраняются), предупреждение, если после неё стоят чужие; битый JSON/неожиданная структура —
  понятный отказ без записи; файл, изменившийся во время установки, — отказ; таймаут app-server
  30 с; скрипт копируется атомарно и **до** записи хуков; notify возвращается, только если там
  ещё наша обёртка, с бэкапом `config.toml`; удаление без файла ничего не создаёт.
- **Сборщик:** обработчики pipe снимаются на EOF (не крутятся вхолостую), поколения процесса
  отсекают данные старого соединения, `--` перед именем хоста в ssh.
- **Reducer:** новая сессия в той же панели закрывает прежнюю (убитую без `SessionEnd`); закрытые
  сессии убираются через час, сессии без tmux — закрываются после 6 ч тишины.
- **Экран:** строку `Working … esc to interrupt` у Codex ищем в 8 нижних строках (очередь
  сообщений её сдвигает); фоновые цвета `48;5;N` не читаются как dim.
- `CollectorSupervisor` (CapriKit): переподключение всех хостов после сна Мака
  (`NSWorkspace.didWakeNotification`) и при смене сети (`NWPathMonitor`) — приложение получит это
  готовым. Статус «хост отключён» UI берёт из `hosts[...]`, а не из статуса сессии.

Отложено: TTL у бэкапов `*.capri-bak-*` (копятся при каждой установке), сверка `pane_pid` перед
отправкой ответа — в Этапе 2 (tmux переиспользует `%N` после перезапуска сервера; pid уже пишется).

### Находки

- Ключ доверия хука Codex — `<путь hooks.json>:<событие>:<группа>:<хук>`. Поэтому наши записи
  добавляются в конец массивов: индексы и доверие существующих хуков не меняются.
- Codex 0.147 (Мак, Homebrew) не знает событие `Interrupt` — установщик сообщает об этом.
- Claude на Маке лежит как `…/claude/versions/2.1.x`, а обёртки (скрипты, `node codex`) прячут
  агента в `pane_current_command` — агент определяется по дереву процессов.
- Подсказка в строке ввода у обоих агентов — SGR dim (`ESC[2m`) после `❯`/`›`, набранный текст —
  без него. У Codex строка ввода видна и во время работы (с плейсхолдером).
- `pkill -f` с шаблоном из собственной команды убивает свою же оболочку — в скриптах искать
  процессы точнее.

### Установка на timoserver · 2026-10-29 (с «да» Тимофея)

`scripts/install-hooks.sh timoserver --apply`: свежий dry-run совпал с показанным заранее.
- `~/.claude/settings.json`: свои PreToolUse/PostToolUse/PostToolUseFailure/SessionStart остались
  первыми, наши записи — после них, плюс 6 новых событий. Бэкап `settings.json.capri-bak-*`.
- `~/.codex/hooks.json` — новый файл, 7 событий; доверие всем 7 (`hooks/list` → `trusted`).
- Повторный `--apply` ничего не меняет и бэкапов не плодит.

По ходу исправлено:
- `~/.capri` остался 0775 от ранних тестов (`makedirs(mode=)` действует только при создании) —
  установщик теперь ужесточает `~/.capri` и `bin/` до 0700.
- Codex урезает timeout `SessionEnd`/`Interrupt` до 3 с и ругается — timeout наших хуков 3 с
  (хуку хватает миллисекунд).
- Бэкап `config.toml` делался и тогда, когда доверие не менялось — теперь только перед записью.
- Окно «Accessing workspace» (доверие к новой папке) экран-классификатор принимал за idle с
  «набрано: No, exit». Меню без номеров с «Enter to confirm · Esc to cancel» теперь диалог;
  фикстура `claude-trust-folder.ansi`.

Живая проверка (CapriCollect на Маке → ssh timoserver, сессия `capri-test-e2e`, глобальные хуки):
- AskUserQuestion → `needs_input (hook)` с вариантами Red / Green, задержка 0.00 с, 🔔.
- Esc в вопросе → `idle (inferred)` по экрану через ~5 с.
- Окно доверия к папке (хуков ещё нет) → `needs_input (inferred)`, варианты «No, exit / Yes, I trust this folder».
- Живые сессии Тимофея тоже шлют события (`running`/`idle` по хукам) — запись идёт.
- Запрос разрешения Bash не воспроизвести: в Claude на timoserver включён auto mode.

### Установка на Мак и quiz · 2026-10-29 (с «да» Тимофея)

Свежий dry-run совпал с показанным (кроме timeout 5 → 3). Мак: свой SessionStart в Claude первым,
Codex `notify` не тронут, Codex 0.147 не знает `Interrupt`. quiz: 8 событий Claude, 7 Codex, доверие 7.
`~/.capri` 0700 на всех хостах, повторный `--apply` ничего не меняет.

Живая проверка (`claude --permission-mode default` в `capri-test-*`):
- **quiz** (критерий Этапа 1): запрос разрешения Bash → `needs_input (hook)` на Маке, задержка 0.08 с;
  Esc → `idle (inferred)` через ~5 с; окно доверия к папке → `needs_input (inferred)`.
- **Мак** (локальный поток): запрос разрешения → `needs_input (hook)`, задержка 0.01 с.

Найдено и исправлено: поток, запущенный без login-PATH (`/bin/sh -c`, как его запустит Capri
из Finder), не находил tmux из Homebrew — `panes: null`. capri-hook ищет tmux по известным путям.
SessionStart у Claude приходит только после окон доверия к папке и выбора MCP-серверов — до этого
сессию видно лишь по экрану.

---

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

#### 1b. Три состояния и плавность (переделка по отзыву, 2026-10-29)

Отзыв Тимофея после первого спайка: «прикольно, но нет плавности; при выезде окно слишком большое;
не было способа выйти». Что сделано:

- **Состояния:** свёрнутый 337×32 → **peek** 377×66 (+34 pt вниз, +40 pt шире; одна строка
  «проект · вопрос») по наведению или новому «ждёт меня» (на 3 с) → **expanded** 440×284 только
  по клику. Из peek сворачивается через 0.3 с после ухода мыши; из expanded — по клику мимо, Esc
  или потере фокуса. Снимок трёх состояний: [notch-states.png](preview/notch-states.png).
- **Одна капля из выреза:** `CAShapeLayer` с плоским верхом, вогнутыми «ушками» сверху и
  скруглённым низом; путь с одинаковым набором сегментов во всех состояниях, Core Animation
  интерполирует его поточечно. Содержимое лежит в слое с маской той же формы.
- **Анимация:** `CASpringAnimation` пути капли и маски (stiffness/damping пересчитаны из
  response 0.45 c, damping 0.8). Перехват посередине идёт с `presentation()` — без скачков.
  Содержимое — fade + сдвиг 6–8 pt: при росте стартует через 0.1–0.12 с после формы, при
  сворачивании гаснет за 0.1 с, и только потом сжимается форма.
- **NSPanel не двигается:** фиксированная прозрачная панель 488×308 над вырезом; меняется только
  `ignoresMouseEvents` по попаданию мыши в целевую форму (глобальный и локальный мониторы
  `mouseMoved`, Accessibility не нужна). Мимо капли клики проходят в другие окна.
- **Выход:** значок в строке меню (Показать peek / Раскрыть / Выйти ⌘Q), то же меню по правому
  клику на капле, `scripts/stop-macos.sh`; скрипты запуска сначала убивают старый экземпляр.

**Замер 120 Гц** (`CADisplayLink` на главном потоке, экран `maximumFramesPerSecond = 120`,
кадр 8.33 мс; переходы запускались сигналами SIGUSR1/SIGUSR2, диагностика в `/tmp/capri-notch.json`):

| Вариант | Результат |
|---|---|
| Холостой фон (SIGHUP) | 120 fps, 0 пропусков |
| SwiftUI-форма с анимацией `frame` + тень | peek→expanded и обратно: 1–5 пропущенных кадров, до 58 мс на первом раскрытии |
| То же без тени, содержимое фиксированного размера | всё ещё 1–5 пропусков на раскрытии/сворачивании |
| **Core Animation (итог)** | 27 переходов подряд: 0 пропусков, кроме первого раскрытия (1 кадр 13 мс) — до прогрева было 2 кадра по 18 мс |

Замер ловит загрузку главного потока; сама пружина капли идёт в render server и от него не
зависит. Глазами плавность на 120 Гц должен подтвердить Тимофей.

#### 1c. Стиль по референсам (2026-10-29)

Референсы Тимофея лежат в `refs/ui-capri-2026-10-29/` (в `.gitignore`, это чужие арты, в
репозиторий не входят). Взяты палитра и язык форм; логотипы, названия и арт не копировались.
Значок Capri — свой рисунок в коде (осколки + глаз).

- Палитра: малиновый `#E8173F` — акцент и обводка; кислотно-зелёный `#3DF58A` — «ждёт меня»
  (глаз Capri, треугольник, ATTENTION); фиолетовый — тонкая обводка значка; капля чёрная.
- Свёрнутый: значок Capri слева, справа `▲ 2` (зелёный, ждут) и `◆ 3` (малиновый, работают),
  моноширинный шрифт.
- Peek: `▲ CAPRI | Run date > stamp.txt?` — название КАПСОМ моно, вопрос обычным шрифтом ради
  читаемости. По краю капли проступает тонкая малиновая обводка (без линии вдоль края экрана).
- Expanded в стиле HUD: заголовок `ЖДУТ МЕНЯ // 02` с красной линией, рамки со срезанными
  углами, запрос разрешения — блок ATTENTION с треугольником, таймер ожидания и сегментная
  полоска, кнопки `1 YES / 2 DON'T ASK / 3 NO / ОТКРЫТЬ ↗`, поле `> ответ`, внизу штрихкод и
  японский декор (`応答待機`, `警告 · 待機中`).
- Glitch-акцент на новое «ждёт меня»: 110 мс, дискретный сдвиг содержимого на ±3 pt, вспышка
  обводки зелёным, зелёная полоса сбоя. Не играется при «Уменьшить движение»
  (`accessibilityDisplayShouldReduceMotion`; сам переключатель не трогали — проверить вручную).

Снимок: [notch-states.png](preview/notch-states.png) (рендер собственного окна, маска не
учитывается).

**Плавность после стилизации:** HUD-панель сначала давала 1–7 пропущенных кадров на раскрытии.
Причина — `makeKey()` в начале анимации: смена key-статуса перерисовывает всю SwiftUI-панель.
`makeKey` перенесён на 0.5 с (после пружины), скрытые слои держатся с alpha 0.01 (прогрет первый
рендер шрифтов и Canvas). После этого серии по 18 переходов: 0 пропусков. Остаётся 1–2 кадра
≈20 мс на **первом** раскрытии после запуска — это первый `makeKey` на 0.5 с, когда пружина уже
почти закончилась; пружина идёт в render server и от этого не зависит.

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
