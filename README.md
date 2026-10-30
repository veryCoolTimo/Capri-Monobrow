# Capri

Нативное приложение для macOS (Swift/AppKit): notch над вырезом экрана, окно сессий и значок в строке меню.
Показывает все сессии Claude Code и Codex на нескольких машинах (этот Mac и ssh-хосты) и сообщает, когда
сессия ждёт ответа; ответить можно прямо из notch. Codex (вход через ChatGPT) — сводки, черновики и чат.

## Запуск

Установка на Маке: `bash scripts/install-macos.sh` — собирает и ставит `/Applications/Capri.app` (Launchpad,
Spotlight, Dock) и запускает в фоне, без окна (`--show` — с окном, `--no-open` — не запускать).
Один экземпляр; окно открывается только явно: Dock, «подробнее» в notch, меню, клик по уведомлению.
Выход — «Выйти» в меню ✦ или ⌘Q.

Нужны macOS 13+, Swift 6 toolchain, полный Xcode для XCTest. Swift-зависимостей нет. Сборка ad-hoc signed.

На хостах нужен `capri-hook` (`tools/capri-hook`): `scripts/install-hooks.sh <host> --apply`.

## Как устроено

- `apps/macos/Sources/CapriKit` — без UI: сборщики событий по хостам (ssh + `capri-hook stream`), reducer
  статусов, разбор экрана tmux, ответы с проверкой доставки, клиент `codex app-server`.
- `apps/macos/Sources/Capri` — notch, окно сессий, настройки, уведомления, Codex.
- План работ: `docs/plans/`. Проверки и что осталось руками: `docs/VALIDATION.md`.

## Структура и план

```text
apps/macos/               Swift: CapriKit (логика) + Capri (AppKit/SwiftUI)
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
```

