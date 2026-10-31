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

## Проход 2 (по отзыву 2026-10-31)

Отзыв Тимофея: окна должны быть функциональными и у каждого своя анимация Capri; персонажа можно двигать; при
ответе сессии через Capri она телепортируется к терминалу; строка трека — 4 с после смены и по наведению; Capri
сама включает/скипает/ставит на паузу треки; простой CPU ~2,5 % → < 1 %. Ответы на «Вопросы Тимофею» выше:
персонаж на столе по умолчанию выкл. — ок; «захват» может рисоваться поверх настоящего окна терминала (так и есть,
вариант `terminal`); строка ♪ — 4 с после смены трека и при наведении (п. 4).

### 2.0 Что меняется в рамках

- **Сцены по действию человека** (ответ сессии через Capri, вопрос помощнику, «включи …», кнопки музыки) —
  отдельная настройка «Capri отвечает на мои действия на столе» (`capri.characterOnAction`, **вкл.**). Они идут
  мимо лимитов директора (человек сам это сделал), но не при fullscreen, паузе, спящих экранах, «спрятан на час»,
  Reduce Motion. Фоновые сцены — по-прежнему `capri.character` (выкл.). Решение — новый
  `CharacterDirector.decideAction(_ ActionEvent, Input) -> Decision` (те же причины `skip`, без кулдаунов).
- **Сцена больше не всегда ≤ 8 с:** функциональное окно держится, пока над ним мышь/идёт перетаскивание, и по
  «📌» до «×» (потолок 10 мин). Без взаимодействия — обычная длина.
- **Клики:** панель по-прежнему `ignoresMouseEvents = true`, кроме «горячих» прямоугольников текущего кадра
  (глаза, заголовок, строки, кнопки). Ни `NSApp.activate`, ни `makeKey`, текстовых полей на столе нет.
- **Музыку Capri включает сама — единственное исключение из «компьютером не управляем»:** AppleScript только к
  Spotify / Музыке, только как прямое следствие действия человека (клик по кнопке Capri или его просьба
  помощнику). Через один `MusicController`. Агенты на Маке AppleScript к плеерам не запускают — проверка тестами
  и фейковым бэкендом (2.5).
- Запрет «не трогаем» из § 0 снимается для `SessionReducer.swift` (п. 6) и `Assistant.swift` (п. 5) — с тестами; `Codex.swift` не трогаем.

### 2.1 Окна и их анимации (п. 1)

Общее: окно — рамка `CAPRI//<ИМЯ> ▮` (как сейчас), раскрытие из линии глаз, «×» и «📌» в заголовке, перетаскивание
за заголовок или глаза (2.2). У каждого окна свой набор клипов, настроение и эффект — в `SceneTimeline` по
`SceneKind`; без клипа — фолбэк в скобках (`melt`, `tex_*` не нарезаны — эффект кодом).

| Сцена (`SceneKind`) | Когда | Что внутри / что кликается | Клипы и эффекты |
|---|---|---|---|
| `teleport` (есть) | сессия доработала, фон | — (только перетаскивание глаз) | `tele_out`/`tele_in`, `look` с наклоном к курсору; новое: моргание `close` раз в ~2,5 с вместо глитча 1 |
| `window` → «статус» (есть) | фон, когда никто не ждёт | строка статуса; клик по ней — основное окно (`actions.window`) | `talk` пока печатает, `look` после, финал — `melt` (процедурное рассыпание) |
| `sessions` (новое) 300×(48+22·n) | фон, если кто-то ждёт или работает; меню «Показать ▸ Сессии» | до 4 строк: метка, имя, что делает, «сколько»; клик по строке — `actions.details(key)` (основное окно на сессии — явное действие), ⌥-клик — `store.openTerminal` | открытие `many` (много глаз = много сессий); ≥ 3 ждут — `crazy`; спокойно — `look`, взгляд наклоняется к строке под курсором; наведение на строку — глитч 1 на 3 кадра и зелёная полоса слева |
| `thinking` (новое) 220×110 | спросил помощника и свернул notch, пока `codex.chatBusy` | «думаю…» + `ThinkingDots`; клик — помощник в notch (`actions.assistant`) | `slits` (держит последний кадр), каждые 1,5 с `shut` → `slits`; сканлайн-вайп сверху вниз по кругу; без молний |
| `answer` (новое) 300×(80…200) | ответ помощника пришёл, а notch свёрнут; продолжение `thinking` (глитч-переход 0,25 с в том же окне) | текст ответа (до 6 строк, markdown как в `Bubble`), кнопки предложения «отправить» / «отмена» (`codex.confirm`/`cancel`), «весь разговор» (`actions.conversation`) | `appear` на открытие, `talk` пока печатается (18 букв/с), `shut` в конце; «отправлено» — `burst` один раз |
| `reply` (новое, п. 3) | человек отправил ответ сессии через Capri | — | см. 2.3: `tele_out` → молния к окну терминала → `tele_in` → `burst` (отправила) → `slits` (смотрит в терминал) + строка «→ votek2 ✓» → `tele_out` |
| `takeover` (есть) | фон, подпункт «захват» | — | `many` → `burst`, датамош, курсор, граффити — как было (поверх настоящего окна терминала, если он спереди) |
| `vibe` (есть) | музыка после тишины | — | `look`/`slits` на долю, ноты |
| `music` (новое, п. 5, этап C) 280×120 | «включи …», клик ⏯/⏭ по глазам на столе, меню | «♪ Artist — Track», ⏮ ⏯ ⏭, «ищу «X»…» пока ждём событие плеера | поиск — `slits` + сканлайн; трек пошёл — `burst` + кивки `look`/`slits` + ноты; пауза — держит последний кадр `close`; снова играет — `appear`; не вышло за 6 с — `crazy` + глитч 3, строка «не нашла» |

`SceneContent` расширяется: `rows: [SceneRow]` (ключ, имя, деталь, статус, `since`), `answer: String`,
`proposal: (title, label)?`, `music: (line, playing)?`, `query: String?`. Живые данные (`sessions`, `answer`,
`music`) обновляются во время сцены через `StageModel.content` (не через пересоздание `SceneRun`), длина окна —
по числу строк.

Отрисовка: арт и эффекты — как сейчас в `SceneCanvas`; содержимое окна (строки, кнопки, текст ответа) —
SwiftUI-слой поверх Canvas внутри того же `NSHostingView`, абсолютным `position` по прямоугольникам из
`SceneLayout` (обычные `Button` — панель принимает клик, когда курсор над «горячим» прямоугольником).

**Фон:** `pickAmbient` выбирает `teleport` / `window` / `sessions` (последнее — только если есть ждущие или
работающие; тогда вместо `window`). Остальные новые сцены — только по действию.

### 2.2 Перетаскивание и «горячие» точки (п. 2)

- **Горячие прямоугольники** — чистая функция `SceneLayout.hotspots(kind, frame, content) -> [SceneHotspot]`
  (`.drag` — глаза и заголовок; `.close`, `.pin`, `.row(key)`, `.button(id)`; глобальные координаты), только в
  «спокойной» фазе (`SceneTimeline.calm`) и не после обрыва. Тесты: в фазах перелёта — пусто; «×» совпадает с
  `closeRect`; строки не вылезают за окно.
- **Отслеживание мыши** — вместо таймера 30 Гц глобальный + локальный монитор `mouseMoved`/`leftMouseDragged`
  (как в `NotchController.installMonitors`; разрешений не требует), ставится на время сцены и снимается в
  `stop()`. Курсор над горячим прямоугольником → `ignoresMouseEvents = false`, ушёл → `true`. Клик мимо горячих
  точек уходит в окно под панелью (проверка — п. 4 старой «Проверки»). `StageCloseView` заменяет
  `StageHitView` (NSView, `acceptsFirstMouse = true`): `mouseDown` на `.drag` — начало перетаскивания, на
  кнопках — отдаёт событие SwiftUI-слою.
- **Перетаскивание:** `mouseDragged` → `SceneRun.offset += Δ`; геометрия — чистая
  `SceneGeometry.moved(by:)` (сдвигает `target` и `area`, обрезает по `visible`; `home` не трогает). Панель —
  `bounds ∩ screen` пересчитывается и `setFrame` на каждом шаге (`SceneRun.origin` меняется, `SceneCanvas.local`
  уже это учитывает). Глаза при перетаскивании — `look` с глитчем 1 и лёгким сплющиванием по скорости.
- **После перетаскивания сцена держит место:** часы сцены — `SceneClock` (CapriKit, чистая): время таймлайна
  = стену минус «удержание»; пока мышь над горячей точкой, идёт перетаскивание или ≤ 3 с после последнего
  взаимодействия — время таймлайна стоит внутри спокойной фазы (клип идёт по стене, `clipT` от неё). Потом сцена
  доигрывает выход из **нового** места (молния домой из точки, куда отнесли). Таймер конца перевзводится
  (`scheduleEnd` по `SceneClock.remaining`).
- **«📌 остаться»:** удержание до «×», `needsInput`, fullscreen, сна или 10 мин. Место после перетаскивания на
  следующий показ не запоминаем (каждая сцена — от своей цели).
- **Notch:** раскрытие notch по-прежнему обрывает сцену, **кроме** закреплённой и окон `thinking`/`answer`/`music`
  (они и есть ответ на действие; при раскрытии помощника `answer` гаснет — он уже виден в notch).
- `dump.stage` += `offset`, `held`, `pinned`, `hotspots` (число), `tracking` (монитор стоит).

### 2.3 Телепорт к терминалу при ответе (п. 3)

- **Когда:** `SessionStore.send` успешен (ветка `sent`) → новый колбэк `onSent(key, action)`; путь любой —
  карточка помощника, notch, основное окно. Если notch раскрыт — ждём свёртывания (≤ 20 с, иначе не играем);
  основное окно — играем сразу. `decideAction(.replySent)`.
- **Куда (без записи экрана — названий окон нет):** `TerminalLocator` (CapriKit, чистый) по снимку таблицы
  процессов и списку окон:
  1. Локальная сессия (`transport == .local`): `tmux list-clients -t <%pane> -F '#{client_pid} #{client_activity}'`
     (асинхронно, таймаут 1 с) → самый свежий клиент → цепочка родителей до процесса с bundle id из
     `SceneLayout.terminals`.
  2. ssh-сессия: свои процессы `ssh`, в аргументах которых есть алиас хоста (как его запускает
     `TerminalOpener`: `ssh -t -- <host>`), самый свежий по времени старта → вверх до терминала.
  3. Окно: `CGWindowListCopyWindowInfo` (без `kCGWindowName`) — первое по z-порядку обычное окно этого pid на
     экране notch (≥ 200×120). Несколько окон одного терминала не различаем — берём верхнее (best effort).
  4. Иначе — верхнее окно любого терминала из `terminals`; иначе — угол.
  `Capri/ProcessTable.swift`: `sysctl(KERN_PROC_UID)` → pid, ppid, имя, время старта; `KERN_PROCARGS2` только
  для `ssh` своего пользователя. Разрешений не требует.
- **Сцена `reply` (≈ 4 с):** 0–0,3 `tele_out` в notch → 0,3–0,5 красная молния к цели (`SceneLayout.onWindow` —
  верхний край окна терминала; не помещается — внутрь окна у правого верхнего угла) → 0,5–0,9 `tele_in` →
  0,9–1,5 `burst` + кольцо-импульс от глаз → 1,5–3,4 `slits`, взгляд вниз в окно, печатается «→ <имя> ✓»
  (доставка подтвердилась, `onDelivered`) / «→ <имя> …» → 3,4–4,0 `tele_out`, домой. Не дошло (`refused` во
  время сцены) — `crazy` + глитч 3 и «не дошло».
- Отладка: `scene reply [terminal|corner]`, `locate <host> <pane>` → debug.log (pid терминала, рамка окна, путь
  выбора), без ответа сессии и без записи в tmux.

### 2.4 Строка трека в раскрытом notch (п. 4)

- `NowPlayingState` (чистая) += `revealUntil`: смена/старт трека → `now + 4`. В `NotchUI`: `musicReveal`
  (по таймеру 4 с из `CharacterCenter`) и `musicHover`.
- Наведение — в `NotchController.mouseMoved` (уже есть глобальный монитор): курсор над глазами
  (`onCapriEyes`) или над полосой музыки (её прямоугольник `ExpandedView` сообщает через preference в
  координатах окна → `ui.musicStripRect`) → `musicHover = true`.
- `ExpandedView`: строка `MusicLine` видна, если `music != nil && (musicReveal || musicHover)`; иначе на её
  месте в шапке — только мини-эквалайзер 3 полоски (цель наведения, без текста). Высота капли не прыгает:
  строка всегда занимает место, меняется прозрачность (0,2 с).
- Свёрнутый notch: наведение на глаза уже даёт peek; если никто не ждёт и музыка известна — peek показывает
  `♪ Artist — Track` (этап A) и кнопки (этап C). «Ждёт меня» всегда выше.

### 2.5 Музыка: Capri сама включает (п. 5, этап C)

**CapriKit `Music.swift` (чистое, тесты):**
- `MusicCommand`: `.play(query)`, `.playURI(SpotifyURI)`, `.toggle`, `.pause`, `.resume`, `.next`, `.previous`.
  `MusicCommand.parse(_ text)` — локальный быстрый путь без Codex: «включи|поставь|play <X>», «пауза|стоп|
  останови», «продолжи|играй», «дальше|следующий|скип|next», «назад|предыдущий|prev»; `nil` — не музыка.
- `SpotifyURI.parse`: `spotify:(track|album|playlist|artist|episode|show):ID`, `https://open.spotify.com/(intl-xx/)?<type>/<ID>?si=…`.
- `MusicAction` из `<capri-action>{"music":"play","query":"…"}</capri-action>` и
  `{"music":"pause|resume|next|previous|toggle"}`: `Assistant.parse` возвращает ещё `music: [MusicCommand]`;
  `Assistant.rules` += строка про этот блок («только если человек сам попросил музыку»).
- **Защита от подсказок с экранов:** музыкальное действие модели выполняется, только если сам вопрос человека
  похож на просьбу о музыке (`MusicCommand.isMusicRequest(question)`); иначе отбрасывается (в debug.log).
- `MusicScript` — строки AppleScript с экранированием `"` и `\`: Spotify `playpause|pause|play|next track|
  previous track|play track "<uri>"`; Музыка `playpause|pause|play|next track|previous track` и поиск
  `set r to search library playlist 1 for "<q>"` → `play item 1 of r` (пусто → код «не нашла»).
- `SpotifyAPI`: `tokenRequest(clientID:secret:) -> URLRequest` (POST `https://accounts.spotify.com/api/token`,
  `grant_type=client_credentials`, Basic), `parseToken(Data) -> (token, expiresIn)`, `searchRequest(query:token:)`
  (GET `https://api.spotify.com/v1/search?type=track,playlist,album&limit=3&q=…`), `parseSearch(Data) -> SpotifyURI?`
  (трек, если запрос похож на «исполнитель — трек»; иначе первый по порядку track → playlist → album).

**Capri:**
- `MusicController` (`Capri/MusicController.swift`) — единственная точка. `perform(_ cmd, intent: MusicIntent)`,
  `MusicIntent = .button(String) | .assistant(question)`; другого входа нет, фон и директор его не вызывают.
  Плеер: источник текущего трека (`NowPlayingState`) → запущенный → Spotify, если установлен → Музыка.
  `pause/next/previous` к незапущенному плееру не шлём (не запускаем его ради паузы). Для `play` незапущенный
  плеер — `NSWorkspace.openApplication` с `activates = false, hides = true`, потом скрипт.
- Бэкенд — протокол `MusicBackend`: `AppleScriptBackend` (`/usr/bin/osascript -e …` в фоне с таймаутом 10 с:
  первый запрос разрешения Automation блокирует вызов, главный поток держать нельзя; атрибуция — к Capri как
  ответственному процессу) и `FakeMusicBackend` (пишет команды в debug.log). С `--debug-control` — **всегда
  фейк**, если нет `--real-music`. Перед запуском — `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded:
  false)` → в `dump` и подсказке «нужно разрешение» (без запроса).
- `Info.plist` (`scripts/build-macos.sh`) += `NSAppleEventsUsageDescription` («Capri включает, ставит на паузу и
  переключает треки в Spotify и Музыке, когда вы её об этом просите»). Риск: ad-hoc подпись меняется при каждой
  сборке — macOS может спрашивать разрешение заново после переустановки; записать в VALIDATION, как поведёт себя.
- `Capri/SpotifySearch.swift`: токен в памяти до `expiresIn − 60`; ключи — `Capri/Keychain.swift`
  (`kSecClassGenericPassword`, service `capri.spotify`, accounts `client-id`/`client-secret`). Настройки → «Музыка»:
  два поля (секрет — `SecureField`), «Проверить» (запрос токена), «Стереть»; в UserDefaults ничего.
- **«включи X» без ключей:** URI/ссылка → `play track`; иначе Spotify — `NSWorkspace.open(spotify:search:<X>,
  activates = false)` и честно: «Открыла поиск в Spotify — выбери трек. Чтобы включала сама, добавь ключи Spotify
  в настройках»; Музыка — поиск по библиотеке через AppleScript.
- **Поток «включи X»:** вопрос помощнику → `MusicCommand.parse` (без Codex) или блок от Codex → чат: «Включаю
  «X»» → сцена `music` (телепорт в окно, «ищу…») → команда → первое событие `NowPlayingMonitor` с новым треком —
  `burst` и строка трека; нет события за 6 с — «не нашла/не включилось».
- **Кнопки:** ⏮ ⏯ ⏭ в `MusicLine` раскрытого notch и в peek (видны при `musicReveal || musicHover`), под глазами
  на столе при наведении (горячая точка, любая сцена в спокойной фазе, если музыка известна), в окне `music`.
  Клик → `MusicController.perform(..., .button)` → кивок/`burst` в notch; на столе — короткий `music`, только
  если уже идёт сцена (из notch не телепортируемся ради паузы).
- Отладка: `music cmd play <q>|pause|next|previous` → `MusicController` с фейковым бэкендом (в debug.log —
  какой скрипт был бы запущен), `music search <q>` → только сборка запроса, без сети; `dump.nowPlaying` +=
  `backend`, `automation` (`granted|denied|notAsked|notRunning`), `spotifyKeys` (есть/нет).

### 2.6 CPU в простое (п. 6)

Профиль: снимки экранов приходят каждые 2 с на меняющуюся панель и раз в 10 с повтором неизменного
(`capri-hook send_screens`, `screen_resend` нужен reducer'у — подтвердить «ждёт ввода»), каждый — полный
`JSONDecoder` 60 строк + `ScreenClassifier.classify`; плюс скрытые `ExpandedView`/`AssistantView`/`PeekLineView`
пересчитывают `body` на каждое изменение `store`/`clock`.

1. **Повторы экрана не разбираем.** `StreamMessage.screenFingerprint(line) -> (pane, ts, payload: Substring)?` —
   без JSON: `pane`, `ts` и хвост строки от `"lines":` (хук пишет поля в постоянном порядке; не нашли — обычный
   путь). `HostCollector` хранит последний хвост по панели (точное сравнение байт, не хэш); совпал — новое
   сообщение `.screenSame(pane, ts)` вместо декодирования. Кэш сбрасывается при новом соединении и чистится по
   `panes`.
2. **Reducer:** `CapriInput.screenSame(host:pane:ts:)`; `CapriState.screenMemo[host pane] = (agent, lines,
   ScreenState)` пишется в `applyScreen`. `screenSame` прогоняет ту же логику `applyScreen` с сохранённой
   классификацией (тайминги `pendingIdle`/`screenLag` те же, т.к. `ts` новый); если агент сессии сменился —
   классифицирует сохранённые строки заново; нет памяти — игнор. Тест: последовательность `screen` + N×`screenSame`
   даёт то же состояние, что N×`screen` с теми же строками (на всех фикстурах `screens-ansi`).
3. **`DetailStore.setScreen`** публикует только при смене `raw` (ts — в непубликуемом словаре); `screenSame` его
   не трогает.
4. **Скрытые слои notch:** `HostGate: ObservableObject { @Published var live }` и обёртка `Gated(gate) { … }` для
   `ExpandedView`, `AssistantView`, `PeekLineView`: `FadingHost.set(shown:)` включает `live` до показа и
   выключает в `completionHandler` после скрытия — внутренний вид снимается целиком вместе с подписками на
   `store`/`clock`/`codex`. Высоты (`expandedHeight`, `assistantHeight`) остаются в `NotchUI` от прошлого показа.
   `TopRowView` — всегда виден, не трогаем.
5. Замер (обычный `--background`, notch свёрнут, сцены нет, живые сессии на timoserver и quiz):
   `ssh timomac 'P=$(pgrep -x Capri); top -l 31 -s 2 -pid $P -stats cpu'`, первую выборку отбросить, среднее
   остальных 30. До/после — в VALIDATION. Цель < 1 %. Если нет — `Instruments`/`sample` ещё раз и следующий кандидат
   (секундный `tick` → `state.sessions != before.sessions`).

### 2.7 Тесты (CapriKit)

- A: `screenFingerprint` (порядок полей, экранированные кавычки в строках, битая строка → nil), эквивалентность
  `screenSame` ↔ `screen`, `NowPlayingState.revealUntil`.
- B: `hotspots` по фазам, `SceneGeometry.moved` (обрезка по экрану), `SceneClock` (удержание, пин, потолок
  10 мин, обрыв), таймлайны новых сцен (клип на каждой фазе — свой, как в таблице 2.1; фолбэки без клипов),
  `TerminalLocator` (локальный tmux-клиент, ssh по алиасу, несколько окон, нет терминала → угол),
  `decideAction` (fullscreen/скрыт/пауза — skip, лимиты не действуют), `pickAmbient` с `sessions`.
- C: `MusicCommand.parse` (рус./англ., с кавычками, «включи» без аргумента), `SpotifyURI.parse`, `MusicScript`
  экранирование, `SpotifyAPI` запросы и разбор обезличенных ответов, `Assistant.parse` с музыкальным блоком,
  отказ без музыкальной просьбы в вопросе.

### 2.8 Этапы (по очереди, каждый — тесты, сборка, живая проверка, VALIDATION)

**A. CPU и строка трека.**
`CapriKit/CapriEvent.swift` (`screenFingerprint`), `CapriKit/HostCollector.swift` (кэш хвостов, `.screenSame`),
`CapriKit/SessionReducer.swift` (`CapriInput.screenSame`, `screenMemo`), `CapriKit/NowPlayingParser.swift`
(`revealUntil`), `Capri/SessionStore.swift` (`DetailStore.setScreen`, `screenSame`), `Capri/NotchController.swift`
(`HostGate` в `FadingHost`, наведение на глаза/полосу музыки), `Capri/NotchViews.swift` (`Gated`, `MusicLine`
по `musicReveal || musicHover`, мини-эквалайзер, ♪ в peek), `Capri/CharacterCenter.swift` (таймер 4 с),
тесты `PipelineTests`/новый `ScreenDedupTests`, `NowPlayingTests`. Проверка: замер CPU до/после, `music play` →
строка 4 с и пропала (`snapshot`), наведение на глаза — снова видна.

**B. Окна, перетаскивание, телепорт к терминалу.**
`CapriKit/SceneTimeline.swift` (`sessions`, `thinking`, `answer`, `reply`, `SceneClock`, `SceneGeometry.moved`,
`SceneLayout.hotspots`, новые клипы в старых сценах), `CapriKit/CharacterDirector.swift` (`decideAction`,
`pickAmbient`), новый `CapriKit/TerminalLocator.swift`, `Capri/CharacterStage.swift` (`StageHitView`, монитор
мыши вместо таймера, перетаскивание, пин, SwiftUI-слой окон, живой `content`), новый `Capri/StageWindows.swift`
(виды содержимого окон), новый `Capri/ProcessTable.swift`, `Capri/CharacterCenter.swift` (`onSent` → `reply`,
`codex.$chatBusy` → `thinking`/`answer`, действия строк), `Capri/SessionStore.swift` (`onSent`),
`Capri/AppDelegate.swift` (wiring, «Показать ▸ Сессии/Думает/Ответ/К терминалу»), `Capri/SettingsView.swift`
(`capri.characterOnAction`), `Capri/NotchController+Debug.swift` (`dump`, `locate`), `scripts/scene-frames.sh`
(новые сцены), тесты `SceneTimelineTests`, `CharacterDirectorTests`, новый `TerminalLocatorTests`.
Проверка: листы всех новых сцен посмотреть самому; вживую — клик мимо горячих точек уходит в окно под панелью,
`isKey == false`, `frontmostPid` не меняется после клика по строке/перетаскивания; перетаскивание держит место;
`scene reply` на тестовой `capri-test-` tmux-сессии в Terminal (ответ — только в свою тестовую сессию).

**C. Музыка.**
новый `CapriKit/Music.swift`, `CapriKit/Assistant.swift` (музыкальный блок, правило), новые `Capri/MusicController.swift`,
`Capri/SpotifySearch.swift`, `Capri/Keychain.swift`, `Capri/CodexService.swift` (локальный путь «включи», выполнение
музыкальных действий с проверкой вопроса), `Capri/AssistantViews.swift` (строка «▶ включаю …» в чате),
`Capri/NotchViews.swift` и `Capri/NotchController.swift` (кнопки ⏮ ⏯ ⏭, их горячие прямоугольники),
`CapriKit/SceneTimeline.swift` + `Capri/CharacterStage.swift`/`StageWindows.swift` (сцена `music`, кнопки под
глазами), `Capri/CharacterCenter.swift` (окно `music`, ожидание события плеера 6 с), `Capri/SettingsView.swift`
(ключи Spotify), `Capri/AppDelegate.swift`, `scripts/build-macos.sh` (`NSAppleEventsUsageDescription`), тесты
`MusicTests`, `AssistantTests`. Проверка — только фейковым бэкендом (`music cmd …`, debug.log); настоящий
AppleScript к Spotify/Музыке первым запускает сам Тимофей (кнопка в notch), агент — нет.

### 2.9 Отличия реализации этапа A от плана

- Отпечаток экрана — байты после `ts` целиком (с `session`, `command`, `agent`, `pid`), а не хвост от `"lines":`:
  смена агента панели тоже даёт полный разбор. Сравнение — на `Data`, до перевода в `String`.
- Сессия «только по экрану» обновляет `lastEventAt` только при изменении (статус, запрос, набранный текст, tmux/cwd):
  иначе каждый повтор экрана переиздавал список сессий.
- Главной причиной CPU оказался не разбор экранов, а значок строки меню: `button.title` ставился на каждое
  изменение сессий тем же значением → перерисовка значка и его сцены. Исправлено (только при смене); то же для
  `panel.ignoresMouseEvents` в мониторе мыши. Итог: 3,7 % → 0,6–0,8 %.
- Полоса музыки — `MusicLine` всегда на месте (эквалайзер виден), прозрачность только у текста.
- `ScreenAge` в основном окне читает время снимка из непубликуемого словаря `DetailStore.seenAt` на тике часов.

### 2.10 Отличия реализации этапа B от плана

- Новые сцены и всё чистое для них — в `CapriKit/SceneWindows.swift` (раскладка окон, таймлайны `sessions`/`thinking`/
  `answer`/`reply`, `SceneLayout.hotspots`, `SceneClock`, `SceneText.wrap`), а не в `SceneTimeline.swift`; параметры
  кадра собраны в `SceneOptions` (старый `frame(text:lines:)` — обёртка).
- Содержимое окон рисуется в том же Canvas сцены (`Capri/StageWindows.swift`), а не SwiftUI-кнопками: клики ловит
  AppKit-вид `StageHitView` по тем же прямоугольникам (`SceneLayout.hit`), кнопка срабатывает по отпусканию над ней.
  Так листы (`ImageRenderer`) и живой показ совпадают, а в неключевой панели не нужен фокус SwiftUI.
- Окно сессий 300×(98+22·n): над строками — глаза 112×56 (в плане 48+22·n без места под глаза). Ответ — 300×(116+14·строк),
  глаза 80×40; предложение — последней строкой ответа, кнопки внизу.
- Наклон глаз к строке под курсором не сделан (курсор берётся на старте сцены); подсветка строки — зелёная полоса.
- `decideAction` не записывает запуск в лимиты фона; «сцена идёт» не мешает (новая заменяет старую).
- `CGWindowList` и таблица процессов читаются в фоне; tmux-клиенты — `tmux list-clients` с таймаутом 1 с.

### 2.11 Отличия реализации этапа C от плана

- AppleScript — `/usr/bin/osascript` в фоне (по `-e` на строку), а не `NSAppleScript`; скрипты — `tell application id …`.
- Состояние разрешения «Автоматизация» не через `AEDeterminePermissionToAutomateTarget` (на Маке вис в фоне), а по итогу
  последнего настоящего скрипта (`granted`/`denied`).
- Фейковый бэкенд выдаёт и события плеера (через `musicEvent`), чтобы окно музыки проверялось целиком без Тимофея.
- Окно музыки 280×124: глаза 80×40 по центру, строка трека, ⏮ ⏯ ⏭ внизу; смены состояния — `SceneMusicMark` (время
  таймлайна и стены: при удержании клип нового состояния начинается с клика); длина — ≥ 8 с и ≥ 5 с после последней смены
  (потолок 40 с).
- Кнопки под глазами — у телепорта, вайба и ответа терминалу (не у окон и не у захвата), появляются при наведении на глаза;
  клик — окно музыки на месте глаз (`around`).
- Peek: клики по кнопкам ловит `NotchController` по рамкам из `PeekMusicKey` (иначе клик по peek раскрывает notch).
- Музыкальные блоки от модели — не больше двух за ответ; `isMusicRequest` без «включи/поставь» (их ловит `parse`).
- В `CapriEffects.swift` выражение клиньев разбито на части: после добавления файлов этапа C отладочная сборка упиралась
  в «unable to type-check this expression in reasonable time».
- Правки по ревью этапа C: «поставь»/«запусти» — музыка только с музыкальным словом или кавычками, голые «продолжи» —
  только при известной музыке, `isMusicRequest` — целые слова; ⏯ плеер не запускает. Кнопки и строки окон сцен — после
  0,4 с наведения; обрезанный текст ответа отправляется только из помощника («прочитать ↗»). Удержание наведением —
  потолок 60 с, стоящая сцена — 4 fps. Таймаут `osascript` до первого ответа плеера — 90 с, застрявшие нажатия
  отбрасываются. Команды файла `control` настоящий плеер не трогают. Таблица процессов — по `KERN_PROC_RUID`.
- Цель § 2.0 «простой CPU < 1 %» на этапе C не достигнута (см. VALIDATION: 2,0–2,4 % на нагруженном Маке).
