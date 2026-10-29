# Capri: каркас, план и первый запускаемый прототип

> Implementation: inline, task by task. This plan intentionally implements CAPRI-001 plus a small demo UI; the remaining MVP is a roadmap, not a completion claim.

**Goal:** собрать нативный macOS-прототип, на котором можно проверить прозрачность, клики, поведение персонажа и компоновку окна сессий.

**Architecture:** AppKit управляет двумя небольшими связанными NSPanel для отрисовки и нативной формы ввода, SwiftUI — окном сессий, WKWebView — локальным WebGL-рендерером. TypeScript-пакеты задают общий протокол и правила состояния для будущего Core. В этой версии GUI использует только явно обозначенные демоданные.

**Tech stack:** Swift 6, SwiftPM, AppKit, SwiftUI, WebKit; TypeScript; Node built-in test runner. Без Electron и сторонних Swift-зависимостей.

**Spec:** [MVP_SPEC.md](../../MVP_SPEC.md), первый билет CAPRI-001.

## Constraints

- GUI: SwiftUI + AppKit; маленькое прозрачное окно вместо полноэкранного WebView.
- Прозрачный фон пропускает клики. Персонажа можно перетащить без переключения фокуса.
- Observed, Controllable tmux и Managed обозначают разные возможности.
- Демо не подключается к настоящим агентам, SSH, микрофону и Telegram.
- Silence is not proof of a stall; disconnected не должен стирать completed.
- Исходный sprite.js — MIT; права на иллюстрацию отдельные. Локальный fan prototype, не публичный релиз.

## Review focus

- Курсор на прозрачном углу панели: клик должен уйти в нижнее приложение.
- Отключённый монитор: окно должно вернуться в доступную область экрана.
- Sleep/wake: рендер и нативные таймеры должны восстанавливаться.
- Hide for 1 hour: скрытие переживает перезапуск, показ доступен из меню.
- Ошибка WebGL/загрузки файла: показать диагностируемую ошибку, не молча пустое окно.

## Первый срез, выполняемый сейчас

### 1. Каркас и контракты

Files: root package.json / tsconfig.json; packages/protocol/src/index.ts; packages/core/src/session-state.ts; apps/macos/Package.swift; README.md; docs/ADR/001-prototype-boundaries.md.

- [x] Создать директории всех подсистем из спецификации; у каждой указать статус и следующий рабочий билет.
- [x] Определить CapriEvent, SessionControl, SessionState, SessionSnapshot и reducer applyEvent(snapshot, event).
- [x] Сначала проверить сбои контракта: повтор event ID, устаревший event, completed → disconnected, приоритет approval, снятие approval и новый turn.
- [x] Реализовать только проверенные правила reducer; остальные адаптеры оставить честными заглушками в документации.
- [x] Проверка: npm test и npm run typecheck проходят.

### 2. Нативный персонаж

Files: apps/macos/Sources/CapriKit/OverlayGeometry.swift; apps/macos/Tests/CapriKitTests/; apps/macos/Sources/Capri/{AppDelegate,CharacterController,CharacterView}.swift; Resources/Character/.

Interfaces: OverlayGeometry.clampedOrigin(_:panelSize:visibleFrame:), SpriteHitMap.contains(_:canvasSize:), CharacterController.setState(_:), show(), hideForOneHour(), returnToNotch().

- [x] Проверить прозрачные пиксели, координаты разных экранов и границы панели на Swift-тестах; проверить нативную маршрутизацию фона и тела живым diagnostic probe.
- [x] Перенести один WebGL sprite renderer и один PNG с attribution; связать JS и Swift через WKScriptMessageHandler.
- [x] Прозрачный bounded NSPanel: alpha hit-testing, drag/click, idle/teleport, масштаб, pin, quiet/pause и hide for 1 hour.
- [x] Реагировать на смену экранов и sleep/wake; соблюдать системный reduced motion.
- [x] Проверка: swift test, release build, реальный запуск и осмотр UI.

### 3. Окно сессий и упаковка

Files: apps/macos/Sources/Capri/{DemoStore,DashboardView}.swift; scripts/{build-macos,run-macos}.sh; docs/VALIDATION.md; THIRD_PARTY_NOTICES.md.

- [x] Сделать окно с тремя демосессиями и явной меткой Demo: Codex Managed, Claude Observed, remote tmux Controllable.
- [x] Выбор сессии, фильтры, краткая история, демоввод, честные состояния недоступных подключений.
- [x] Выбор состояния в демо меняет реакцию персонажа; деморазрешение одноразовое и привязано к выбранному событию.
- [x] Скрипт сборки создаёт .app с локальной ad-hoc подписью; скрипт запуска открывает его.
- [x] Запустить приложение, проверить взаимодействия и сохранить проверяемый screenshot.
- [x] Зафиксировать измеренную память/CPU и непроверенные ручные сценарии отдельно.

## Дальнейший план MVP

| Этап | Рабочие билеты | Выходной критерий |
|---|---|---|
| P0 завершить | CAPRI-002 Codex app-server spike; CAPRI-003 Claude hook spike; CAPRI-004 один SSH/tmux host | По одному настоящему событию каждого источника; проверена авторизация |
| P1 shell | CAPRI-010 roaming; 011 настройки экранов/fullscreen; 012 launch-at-login; 013 energy profiling | Стабильный персонаж после sleep/wake, на нескольких экранах |
| P2 Core | CAPRI-020 Unix-socket IPC; 021 SQLite migrations; 022 Codex managed; 023 Claude managed/hooks; 024 permissions | Создать/продолжить реальную задачу, получить событие и ответить на допустимый запрос |
| P3 discovery | CAPRI-030 local observers; 031 SSH hosts; 032 explicit adopt; 033 single-writer lock | Внешняя сессия наблюдается; управление доступно только после проверенного pairing |
| P4 voice/memory | CAPRI-040 Markdown provenance/edit/delete; 041 Tima bridge; 042 PTT; 043 licensed sound pack | Голос попадает в composer; недоступный transcriber имеет fallback |
| P5 Telegram | CAPRI-050 pairing/auth; 051 gateway; 052 Mini App; 053 offline relay | Mac offline виден явно, локальные действия недоступны |
| P6 hardening | CAPRI-060 reconnect/dedupe; 061 fault injection; 062 permissions; 063 asset audit/notarization | Пройдена матрица сбоев, нет ложных completed и утечек секретов |

Каждый этап получает отдельный подробный план после соответствующего P0 spike. Это позволяет не закреплять неподтверждённые API и условия авторизации в рабочем коде.

## Текущие решения

- Пока нет настоящего Core daemon; TypeScript reducer тестируется отдельно. IPC и SQLite идут в P2.
- Окно сессий — интерактивное демо для обсуждения UX; любые «отправки» остаются в памяти приложения.
- Нет автозапуска, hooks, изменений SSH/config, ключей и фонового сервиса при первом запуске.
- Статический alpha map повторяет геометрию спрайта; небольшой запас у силуэта компенсирует idle-анимацию. Точные попадания для сильных деформаций — отдельная проверка.

Первый срез не закрывает весь acceptance CAPRI-001: реальный sleep/wake, внешние мониторы, физический drag в другой Space и энергопотребление требуют отдельного ручного прогона. Его границы и результаты записаны в VALIDATION.md.
