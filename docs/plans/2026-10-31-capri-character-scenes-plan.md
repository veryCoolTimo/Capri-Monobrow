# Capri — сцены персонажа: телепорт, окно, «захват», музыка (план 2026-10-31)

Следующий шаг после `2026-10-30-capri-design-research.md` (v5: только глаза, клипы сериала локально).
Цель: глаза Capri ненадолго выходят из notch на рабочий стол — телепортируются, превращаются в окошко,
«захватывают» экран, кивают под музыку из Spotify/Музыки. Один проход: код, тесты, контактные листы.
Коммит — только по решению Тимофея.

## 0. Жёсткие рамки

- **Сцена — короткое представление (≤ 8 с), а не постоянное присутствие.** Вне сцены панели нет
  (`orderOut`), `TimelineView` на паузе, CPU ≈ 0. Непрерывное блуждание — не в этом проходе.
- **StagePanel** — копия рецепта `NotchPanel`: `[.borderless, .nonactivatingPanel]`, прозрачная,
  без тени, `canBecomeKey/Main = false`, уровень `mainMenu + 2` (под notch), `[.canJoinAllSpaces,
  .stationary, .ignoresCycle]` **без** `.fullScreenAuxiliary`, показ только `orderFrontRegardless()`.
  Никаких `NSApp.activate`/`makeKey`. `ignoresMouseEvents = true` всегда, кроме «×» в сцене «окно».
- **Компьютером не управляем.** Курсор, окна, текст — рисунок внутри своей панели (розовый курсор с
  RGB-разносом, чтобы не спутать с настоящим). Нет `CGEvent`, `NSCursor`, Accessibility, AppleScript.
- **Без запросов разрешений.** Рамки окон — `CGWindowListCopyWindowInfo` без `kCGWindowName`;
  простой ввода — IOKit `HIDIdleTime`; курсор — `NSEvent.mouseLocation`; музыка —
  `DistributedNotificationCenter`. MediaRemote и ScriptingBridge — нет.
- **Полноэкранный режим** (`AttentionCenter.checkFullscreen`): сцены на столе не запускаются, идущая
  сцена гаснет. Исключений в этом проходе нет.
- Не трогаем `SessionReducer.swift`, `Assistant.swift`, `Codex.swift` и их тесты (используем только типы).
- Кадры сериала — только в `work/` и `~/.capri/art/eyes` на Маке. В репозиторий не попадают.

## 1. Арт: что режем из сериала

Источник — локальное видео сериала (в `work/`, не в репозитории; номера кадров и тайм-коды — в
локальных заметках там же). Всё новое — **необязательные** клипы: без них сцена
собирается из старых клипов (`appear`, `close`, `look`, `many`, `burst`) и процедурных эффектов.

| Клип | Что в кадре | Зачем |
|---|---|---|
| `tele_out` | распад на полосы с RGB-сдвигом | исчезновение |
| `tele_in` | проявление глаз сквозь полосы | появление |
| `melt` | правая половина кадра, рассыпание в частицы | окно рассыпается в частицы |
| `tex_mosh` | 1 кадр: розово-синий датамош | заливка «захвата» |
| `tex_graffiti` | 2–4 кадра: розовые пятна на мониторах | граффити поверх муляжа окна |

Всё — непрозрачные кадры в полосе 2:1, как текущие клипы: ключ по фону не делаем.

**Нарезка** (на timoserver, по одной тяжёлой команде за раз):
1. Выгрузка кадров `ffmpeg … -vf fps=24` в `seq/<клип>/%04d.png` (тайм-коды — в локальных заметках
   в `work/`), текстуры — по одному кадру (`-frames:v 1`).
2. `cut2.py`: в `CLIPS` добавить строки с папкой, диапазоном, верхом полосы `y0` и для `melt`
   кроп по x (новое необязательное поле `x0`, по умолчанию 0; для `melt` ≈ 400, ширина 880 → 2:1
   по высоте 440). Текстуры — с `cap` = 1, без склейки.
3. Бюджет: сейчас 114 PNG при лимите `ShowArt` 256. После нарезки — не больше ~200, иначе поднять
   порог склейки повторов или `cap`. `python3 cut2.py eyes` печатает сводку — проверить.
4. Контактный лист новых клипов (`fxpreview.py`/PIL) — посмотреть самому до отправки.
5. `scripts/push-capri-art.sh` → Мак, затем перезапуск Capri (`ShowArt.shared` грузится один раз).

**Код:** `ShowArt.names` += `tele_out, tele_in, melt, tex_mosh, tex_graffiti`; `look` по-прежнему
обязателен. Метод `ShowArt.clip(named:) -> FrameClip?` без подмены на `look` — сцене нужно знать, есть ли клип.

## 2. Сцены

Сцена — чистая функция `SceneTimeline.frame(scene, t, geometry) -> SceneFrame`:
позиция и масштаб глаз, клип и тик, уровень глитча, молния (от/до), белая вспышка, прогресс рамки,
печать текста, курсор. Детерминирована по `t` → одинаковые кадры в живом показе и снимках.
Глаза на столе — полоса 2:1, 120×60 pt. Старт и финиш — прямоугольник глаз в notch (`NotchGeometry`).

**A. Teleport (≈ 5 с).**
0–0.3 с — глаза в notch: `tele_out` (или `close` + сплющивание в линию 2 px) с глитчем 3 →
0.3–0.5 с — тонкая красная молния notch → цель, белая вспышка 2 кадра →
0.5–1.0 с — в цели `tele_in` (или `appear` + глитч 4) →
1.0–4.4 с — `look`, взгляд к курсору (`mouseLocation` левее/правее) →
4.4–5.0 с — `tele_out`, молния обратно, `appear` в notch.
Цель: правый нижний угол `visibleFrame` (отступ 24 pt) или **верхний край фронтального окна**
(«сидит на окне»): рамка из CGWindowList, окно целиком на экране notch и не у строки меню; иначе угол.

**B. Window form — «переделывается в окно» (≈ 8 с).**
0–0.6 с — короткий телепорт в угол → 0.6–1.0 с из линии глаз раскрывается рамка 280×170 (розовая
1 px рамка растёт по горизонтали, затем по вертикали, scanline-вайп) → заголовок `CAPRI//SYS ▮`
(не светофор macOS) → 1.0–7.0 с внутри глаза `look`/`talk`, строка печатается побуквенно из реальных
данных: «2 ждут · votek2», «всё тихо», «♪ Artist — Track» → 7.0–7.6 с `melt` (или глитч 4) → телепорт
домой. **«×» в углу** — единственная кликабельная точка (опрос `mouseLocation` раз в 0.1 с только во
время сцены, `ignoresMouseEvents` снимается лишь над «×»), закрывает сразу.

**C. Takeover — «управляет компом» (≈ 4.6 с, только изображение).**
Область: рамка фронтального окна, если это терминал (bundle id из `frontmostApplication`: Terminal,
iTerm2, Ghostty, WezTerm, Alacritty), иначе 480×300 в правом нижнем углу; обрезка по `visibleFrame`.
0–0.5 с телепорт к углу области → 0.5–1.2 с розовая волна сверху вниз + сканлайны (`tex_mosh`
с альфой 0.35, иначе процедурные полосы) → 1.2–3.8 с нарисованный курсор по 3 точкам Безье, кольца
«кликов», сами печатаются строки `> capri attach votek2`, `ACCESS ▮▮▮`, пятна `tex_graffiti`, глаза
в углу `many` → `burst`, красные молнии 1–2 px по краю на 2–4 кадра → 3.8–4.6 с глитч 4 сжимает всё
в линию, телепорт домой. Панель click-through, фокус у той же программы.

**D. Vibe — «видит, что играет трек».**
- *Notch (работает и при выключенном персонаже):* на старт/смену трека — 4 с кивания (сдвиг глаз
  по синусу ~112 bpm, чередование `look`/`slits` на сильную долю, глитч 1 на смену трека, без молний),
  рядом 3 полоски-эквалайзер. В раскрытом notch — строка `♪ Artist — Track` и кивание, пока раскрыт.
  Свёрнутый notch после 4 с — снова статичен. **Peek из-за музыки не делаем.**
- *Стол (если персонаж включён):* первое воспроизведение после ≥ 10 мин тишины — телепорт в угол,
  6 с кивания с нотами-глифами, домой.
- Пауза → через 5 с idle; стоп/выход плеера → сразу.
- Новый `CapriMood.vibing`: ветки в `CapriArt.frame`, `ShowArt.image/still`, `CapriFX.glitch/bolt`
  (bolt — никогда). В свёрнутом notch (`NotchViews:111`) `.vibing` только если `waiting == 0` и не
  `chatBusy`; alert всегда выше. `assistantMood` не трогаем.

## 3. Триггеры — `CharacterDirector` (CapriKit, чистая логика)

Вход: `now`, настройки, `fullscreen`, `paused`, `displaysAsleep`, `notchState`, `sceneRunning`,
`idleSec` (HIDIdleTime), `lowPower`, `reduceMotion`, история запусков. Выход:
`.play(Scene, target)` или `.skip(reason)` — причина пишется в debug.log.

Запреты для фоновых и событийных сцен: настройка выкл. или «спрятан на час»; пауза Capri; fullscreen;
экраны спят/экран заблокирован; notch раскрыт или в peek; сцена уже идёт; `idleSec < 3`
(человек печатает/двигает мышь прямо сейчас — подождать); `idleSec > 120` (никто не смотрит);
Low Power / Reduce Motion.
Лимиты: не чаще 1 сцены за 20 мин и 4 в час. Демо из меню и `scene …` идут мимо директора
(кроме fullscreen — там подсказка «выйдите из полноэкранного режима»).

| Событие | Сцена | Кулдаун |
|---|---|---|
| Сессия перешла `running → idle` (не `needsInput`) | Teleport | 10 мин |
| Ambient (таймер 30–60 мин, `idleSec` 3–120) | Teleport 70% / Window 30% | 30–60 мин |
| Ambient takeover (только если включён подпункт) | Takeover | ≥ 2 ч |
| Первое воспроизведение после ≥ 10 мин тишины | Vibe на столе | 30 мин |
| Старт/смена трека | Vibe в notch (мимо общих лимитов) | 3 мин |

Если во время сцены приходит `needsInput` — сцена обрывается (молния домой за 0.3 с), дальше обычный
alert notch. «Сессия завершилась» — чистая функция `SceneTriggers.finished(prev:next:)` по парам
(ключ, статус) из `store.$sessions` (подписка в `CharacterCenter`, редьюсер не трогаем).
Случайность — через `TickNoise`/инжектируемый seed, чтобы тесты были детерминированы.

## 4. Now playing — `NowPlaying`

- **CapriKit `NowPlayingParser`:** `parse(source:, userInfo: [AnyHashable: Any]) -> NowPlayingEvent`
  (`.playing(Track)`, `.paused(Track)`, `.stopped`). Spotify: `Player State`, `Name`, `Artist`,
  `Album`, `Track ID`, `Duration`, `Playback Position`. Музыка: `Player State`, `Name`, `Artist`,
  `Album`, `Total Time`, `Persistent ID`. Числа — `NSNumber`/`Int`/`Double`; длительность > 36000 → мс.
  `spotify:ad:` и пустой исполнитель → строка «реклама»; `spotify:episode:` → «подкаст».
  Плюс `NowPlayingState` (последний трек, `silentSince`, кулдауны vibe) — чистая.
- **Capri `NowPlayingMonitor.swift`:** подписка на `com.spotify.client.PlaybackStateChanged` и
  `com.apple.Music.playerInfo` с `suspensionBehavior: .deliverImmediately` (приложение почти всегда
  неактивно); `NSWorkspace.didTerminateApplicationNotification` для `com.spotify.client` /
  `com.apple.Music` → `.stopped`. На старте ничего не знаем — показываем после первого события
  (кэш в файл не пишем). Название трека не логируем: в debug.log только `source` и состояние.
- Включается настройкой «Реагировать на музыку»; выключение снимает наблюдателей.

## 5. Файлы

Новые:
- `CapriKit/CharacterDirector.swift`, `CapriKit/SceneTimeline.swift`, `CapriKit/NowPlayingParser.swift`
- `Tests/CapriKitTests/CharacterDirectorTests.swift`, `SceneTimelineTests.swift`, `NowPlayingTests.swift`
- `Capri/CharacterStage.swift` — `StagePanel`, `StageController` (показ, движение, «×», обрыв),
  `SceneView` (Canvas: `CapriShotView`-подобная отрисовка клипа, рамка окна, курсор, текст, текстуры)
- `Capri/NowPlayingMonitor.swift`
- `Capri/CharacterCenter.swift` — связка директора, сцен, музыки и кивания (см. «Отличия реализации»)
- `scripts/scene-frames.sh`

Меняются:
- `CapriFace.swift` — `.vibing`; `CapriSprite.swift` — имена клипов, `clip(named:)`, ветки vibing
- `CapriEffects.swift` — `flash` (белая вспышка), `boltPath(from:to:)` между произвольными точками, vibing
- `NotchViews.swift` — строка ♪, эквалайзер, кивание; `NotchController.swift` — «Спрятать персонажа
  на час» в контекстном меню, отдача прямоугольника глаз для сцен
- `AttentionCenter.swift` — флаг полноэкранного режима для персонажа (переходы сессий, `needsInput` и сон — в
  `CharacterCenter.swift`)
- `SettingsView.swift`, `AppDelegate.swift` (настройки, меню, wiring, debug)
- `work/art/show/cut2.py` (локально, не в репозитории)

## 6. Настройки и меню

- «Персонаж на рабочем столе» — `capri.character`, **по умолчанию выкл.**; подпункты
  «Как часто: редко / иногда» (`capri.characterRate`), «Сцены по событиям сессий» (вкл.),
  «Изображать захват экрана» (`capri.characterTakeover`, выкл.).
- «Реагировать на музыку (Spotify, Музыка)» — `capri.music`, по умолчанию вкл. (только notch).
- Меню строки состояния: «Персонаж ▸ Показать: Телепорт / Окно / Захват / Вайб» (работает и при
  выключенной настройке — чтобы посмотреть анимации), «Спрятать персонажа на час». ⌘Q «Выйти» — как было.
- Правый клик по notch: «Выйти» + «Спрятать персонажа на час».

## 7. Отладка (`--debug-control`, `~/.capri/tmp/control`, через `AppDelegate.debugCommand`)

- `scene teleport [corner|window]`, `scene window`, `scene takeover [terminal|corner]`, `scene vibe`,
  `scene stop`
- `scene sheet <name>` — рендер `SceneView` через `ImageRenderer` для набора `t` в одну сетку
  `~/.capri/tmp/scene-<name>.png` (без записи экрана и без показа панели)
- `music play <artist>|<track>`, `music pause`, `music stop` — фейковые события в тот же путь, что
  и монитор
- `director <event|ambient>` — прогнать политику, ответ в debug.log
- `dump` += `scene` (имя, t), `stage` (frame, `ignoresMouseEvents`, `isKey`, `isVisible`),
  `nowPlaying` (source, state, без названий), `director` (last, nextAmbient), `frontmostPid`

## 8. Тесты (CapriKit)

- **Director:** каждый запрет даёт свою причину; кулдауны 10 мин / 20 мин / 4 в час; ambient в окне
  30–60 мин детерминирован по seed; `needsInput` обрывает сцену; vibe в notch мимо общих лимитов, но
  с кулдауном 3 мин; первое воспроизведение после 10 мин тишины.
- **Triggers:** `running → idle` — да; `running → needsInput`, `idle → idle`, новые/исчезнувшие ключи — нет.
- **Timeline:** на границах фаз верные клип/глитч/молния; `t < 0` и `t > duration` — домашняя позиция;
  позиция непрерывна (нет скачков > N pt за кадр, кроме момента телепорта); цель обрезается по
  `visibleFrame`; без клипов `tele_*` — фолбэк на `appear`/`close`.
- **NowPlaying:** обезличенные словари Spotify/Музыки (Playing/Paused/Stopped), числа разных типов,
  мс/с, реклама/эпизод, пустой userInfo → `.stopped`.

## 9. Проверка

1. `scripts/mac.sh "npm run test:macos"` и `npm run build:macos` — зелёные.
2. Контактные листы: `scripts/scene-frames.sh teleport|window|takeover|vibe` (на Маке: запуск с
   `--background --debug-control`, `scene sheet`, `scp` на timoserver). Смотрю кадры сам **до**
   установки; плюс лист новых клипов из `cut2.py`.
3. Установка `scripts/mac.sh "bash scripts/install-macos.sh"` (фон, без окна). Живой прогон:
   `scene teleport` → через 1.5 с `screencapture -x` → `dump`: `stage.ignoresMouseEvents == true`,
   `isKey == false`, `regular == false`, обычных окон Capri нет, `frontmostPid` до и после совпадает;
   через 6 с `stage.isVisible == false`.
4. «×» в `scene window` закрывает сцену; клик мимо «×» уходит в окно под панелью.
5. Полноэкранное приложение → `director ambient` = `skip fullscreen`; `scene teleport` не показывает панель.
6. CPU (`ps -o %cpu`): 60 с без сцены < 1 %; во время сцены записать; через 1 с после — снова < 1 %.
7. Музыка: `music play Test|Track` → кивание и строка ♪ в раскрытом notch (`snapshot`). Затем один
   раз Тимофей сам переключает трек в Spotify — событие доходит при неактивном Capri (debug.log).
8. Запросов разрешений не появилось (Системные настройки → Конфиденциальность — Capri нигде не добавлен).
9. Ревью двумя агентами (качество + архитектура), исправить high/medium.

## Вне этого прохода

Непрерывное блуждание и перетаскивание, сцена поверх полноэкранных при `needsInput`, несколько
мониторов (только экран с notch), реальный BPM, другие плееры (браузер), MediaRemote-адаптер, звук,
клипы с прозрачностью (ключ по чёрному фону из сцены «рывок»).

## Вопросы Тимофею

- Персонаж на столе по умолчанию выключен (демо из меню доступно всегда) — так ок?
- Takeover над настоящим окном терминала или только в своей угловой области?
- Строка ♪ в раскрытом notch — постоянно, пока играет, или только 4 с после смены трека?

## Отличия реализации от плана

- Связка директора, сцен и музыки — отдельный `Capri/CharacterCenter.swift`, а не `AttentionCenter`:
  подписка на `store.$sessions`, переходы сессий, `needsInput` → `stage.abort()`, сон/смена пользователя →
  `stage.stop()`, кивание в notch, тексты сцен. `AttentionCenter` только определяет полноэкранный режим
  (`fullscreen`, `onFullscreen`) независимо от настройки «прятать notch»; при «всегда скрывать строку меню»
  персонаж считает полноэкранным любое окно переднего приложения на весь экран (`Fullscreen.frontCoversScreen`).
- «Спрятать персонажа на час» и «Персонаж ▸ Показать» — в общем меню `AppDelegate.makeMenu` (оно же в строке
  меню и по правому клику на notch), а не отдельным пунктом в `NotchController`.
- Имена клипов — константы `SceneClip` (CapriKit), общие для `SceneTimeline`, `ShowArt` и `CapriArt`.
- Кивание в notch идёт мимо общих лимитов, но не при паузе уведомлений, полноэкранном приложении и спящих экранах.
- Спокойная часть сцен (глаза на месте, молнии нет) показывается на 12 fps (`SceneTimeline.calm`), остальное — 24.
