# Capri · нативный прототип

Каркас MVP и первый запускаемый срез CAPRI-001. Нативное приложение для macOS: персонаж на рабочем столе и окно сессий с демоданными.

## Запуск

Установка на Маке: `bash scripts/install-macos.sh` — собирает и ставит `/Applications/Capri.app` (запуск из Launchpad, Spotlight, Dock). Запускается один экземпляр; повторный запуск открывает окно. Значок ✦ в строке меню остаётся после закрытия окна. Выход — «Выйти» в меню или ⌘Q.

Из исходников:

```sh
npm ci
npm run build:macos
npm start
```

Нужны macOS 13+, Swift 6 toolchain, полный Xcode для XCTest, Node 22.18+. Swift-зависимостей нет. Скрипт выбирает `/Applications/Xcode.app` локально через `DEVELOPER_DIR`, не меняя системный xcode-select. Сборка ad-hoc signed, для этого Mac; публичной notarization нет.

## Что работает

- Две маленькие связанные нативные NSPanel для WebGL-спрайта и формы ввода; idle, teleport, working, thinking, approval, success, error и sleep.
- Клик на персонажа открывает окно; drag перемещает. Нативная alpha-форма пропускает фоновые клики без polling курсора; небольшой запас у силуэта покрывает idle-анимацию.
- Маленький/средний/большой размер, пауза, закрепление, возврат рядом с вырезом экрана и скрытие на час.
- Настройки и скрытие сохраняются в отдельном UserDefaults domain `local.capri.prototype.preferences`.
- При выключенном закреплении Capri раз в 45 секунд телепортируется вдоль нижней границы рабочего пространства. Это первый набросок roaming.
- Окно демосессий: выбор, фильтр запросов, одноразовое деморазрешение и ввод в выбранную управляемую демосессию. Все сообщения остаются в оперативной памяти.
- TypeScript-контракт событий и чистый reducer с проверками приоритетов, deduplication, disconnect и новых turns.

## Что пока является каркасом

Настоящие Codex/Claude, SSH/tmux, SQLite/Core daemon/IPC, голос, Markdown memory, Telegram и login item не подключены. Демосостояния не показывают состояние работающих на Mac агентов. «Разрешить демо» не запускает `swift test` или другую команду.

Приложение не устанавливает hooks, сервер, автозапуск или новые разрешения микрофона/Accessibility.

## Структура и план

```text
apps/macos/               SwiftUI + AppKit + WKWebView
apps/telegram-mini-app/   граница будущей Mini App
packages/protocol/       общие TypeScript типы
packages/core/           reducer; daemon ещё не реализован
packages/agent-*/        билеты интеграций
packages/…/              остальные границы подсистем
docs/MVP_SPEC.md          исходная спецификация пользователя
docs/superpowers/plans/   первый срез и roadmap P0–P6
docs/VALIDATION.md        проверенное и оставшиеся ручные проверки
```

[План реализации](docs/superpowers/plans/2026-10-27-capri-prototype.md) · [Архитектурное решение](docs/ADR/001-prototype-boundaries.md)

## Проверки

```sh
npm test
npm run typecheck
npm run test:macos
npm run build:macos
node scripts/check-diagnostics.mjs docs/preview
```

Экспорт только собственного WebView для диагностики:

```sh
"/Applications/Capri.app/Contents/MacOS/Capri" --export-diagnostics /absolute/path/to/capri-diagnostics
```

Не запускать второй экземпляр поверх первого: сначала завершить Capri через его меню.

## Источники

WebGL shader и референс-спрайт: [mochiiwuff/capri-desktop](https://github.com/mochiiwuff/capri-desktop), commit `f8395800976b4c787ec088d6fead140a934875fb`. Код рендерера — MIT с сохранённым notice. Иллюстрации не покрыты MIT; это локальный fan prototype. См. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Для публичной сборки нужен отдельный набор персонажа с подтверждёнными правами.
