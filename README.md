<p align="center">
  <img src="branding/logo-256.png" width="128" alt="Termux IDE logo">
</p>

<h1 align="center">Termux IDE</h1>

<p align="center">
  Пиши и запускай код прямо на Android-телефоне.<br>
  Редактор на Flutter + настоящий терминал Termux.
</p>

<p align="center">
  <a href="https://github.com/GRUMM7506/termux-ide/releases/latest"><b>⬇ Скачать APK</b></a> ·
  <a href="#как-это-работает">Как это работает</a> ·
  <a href="#сборка">Сборка</a>
</p>

---

## Возможности

- **Редактор кода**: вкладки, подсветка (Dart, Kotlin, Java, Python, JS/TS, C/C++, Go, Rust, Shell, YAML, JSON, XML…), номера строк, автоотступ, undo/redo, панель символов `{ } ( ) ;` для экранной клавиатуры, Ctrl+S.
- **▶ Запуск в одно касание**: IDE сама определяет тип проекта (Flutter, Dart, Android/Gradle, Node.js, Python, Rust, Go, CMake, Make) или открытого файла и подбирает команду. Можно выбрать другой вариант или задать свою команду.
- **Интерактивный терминал**: полноценный PTY с цветами, вводом в программу (`input()`, `Scanner`, `readln()`), Ctrl/Esc/Tab/стрелками, несколькими вкладками. Для Flutter работают hot reload ⚡ и hot restart ↻.
- **Git как в VS Code**: панель «Git» с подготовленными изменениями и изменениями, просмотр diff, stage/unstage/отмена изменений, коммит (и «Коммит и Push»), pull/push/sync/fetch, ветки, история, stash, remote, вход в GitHub по токену, init и clone. Изменённые файлы подсвечиваются в дереве, текущая ветка видна под заголовком.
- **ИИ-агент как в VS Code**: панель «Агент» с **Claude Code** и **Codex** — агент видит проект, правит файлы и запускает команды (flutter, gradle, git) прямо в Termux. Вход **по подписке** (Claude Pro/Max, ChatGPT Plus/Pro), без API-ключей. Чат с ходом работы (чтение, правки, команды), режимы доступа (план / правки / авто / полный), выбор модели, продолжение чата, полный интерфейс агента в терминале. Изменённые агентом файлы сразу обновляются в редакторе, дереве и Git.
- **Языки и расширения**: Python, Node.js, C/C++, Java, Kotlin, Gradle, Go, Rust, Dart, Ruby, PHP, Git ставятся в Termux одной кнопкой.
- **Мастер первого запуска**: проводит через установку Termux, одну команду подготовки и разрешение. Сервер IDE ставится и обновляется сам.
- **Проекты**: шаблоны для 10+ языков, дерево файлов (создать, переименовать, удалить), сборка и установка APK.
- **Большой экран и Samsung DeX**: на планшете дерево файлов слева, в DeX/большом окне ещё и агент отдельной колонкой справа (как вторая боковая панель VS Code). Ширина колонок меняется перетаскиванием границы, панель скрывается по Ctrl+B. Мышь: правый клик по файлу или вкладке открывает меню, средний клик закрывает вкладку. С аппаратной клавиатурой экранные панели клавиш прячутся, а горячие клавиши работают как в VS Code: F5, Ctrl+S, Ctrl+W, Ctrl+Tab, Ctrl+\`, Ctrl+Shift+E/G/A и другие (полный список: меню ⋮ → «Горячие клавиши»). При переходе телефон ↔ DeX приложение не перезапускается: открытые файлы, терминалы и чат агента сохраняются.

## Установка

1. Скачай `TermuxIDE-*.apk` из [Releases](https://github.com/GRUMM7506/termux-ide/releases/latest).
2. Установи **Termux** с [F-Droid](https://f-droid.org/packages/com.termux/) или [GitHub](https://github.com/termux/termux-app/releases). Версия из Google Play не подходит.
3. Открой Termux IDE и следуй мастеру. Мастер попросит один раз выполнить в Termux:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/GRUMM7506/termux-ide/main/termux/install.sh | bash
   ```

   Команда включает `allow-external-apps` и ставит Python, на котором работает сервер IDE.

## Как это работает

```
┌──────────────── Termux IDE (Flutter) ─────────────┐        ┌──────────── Termux ────────────┐
│ редактор · дерево файлов · терминал (xterm)       │  HTTP  │ ~/.termux-ide/server.py         │
│                                                   │◄──────►│  • файлы проекта                │
│ RUN_COMMAND intent → запуск/обновление сервера    │   WS   │  • PTY-сессии (bash, flutter…)  │
└───────────────────────────────────────────────────┘        └─────────────────────────────────┘
```

- `assets/termux/server.py` — сервер только на стандартной библиотеке Python: HTTP API для файлов, WebSocket с PTY для терминалов и WebSocket с процессами на пайпах (JSONL) для ИИ-агентов. Слушает **только `127.0.0.1:8765`** и пускает по токену, который генерирует приложение.
- Приложение само кладёт сервер в `~/.termux-ide/` через Termux `RUN_COMMAND` и обновляет его, если версия изменилась.
- Лог сервера: `~/.termux-ide/server.log`.

## ИИ-агент (Claude Code / Codex)

Открой проект → кнопка 🤖 «Агент» (или вкладка «Агент» рядом с «Файлы» и «Git»).

1. **Установить.** Codex ставится из официального репозитория Termux (`pkg install codex`). У Claude Code нет официальной сборки под Android (с версии 2.1.113), поэтому IDE запускает установщик сообщества [claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android): он скачивает официальный linux-arm64 Claude Code и запускает его через `glibc-runner`. Установщик задаст два вопроса — если Termux у тебя не новый, на первый ответь `n`.
2. **Войти.** Кнопка «Войти» запускает `claude auth login` / `codex login` в терминале. Ссылку входа IDE откроет в браузере сама (сервер подменяет `xdg-open`/`$BROWSER`), а на экране появится плашка «Открыть / Скопировать». Claude после входа покажет код — вставь его кнопкой ⎘ на панели клавиш. Codex вернётся на `localhost:1455` сам.
3. **Работать.** Пиши задачу в чат. Сверху выбираются режим доступа и модель; чип с именем файла добавляет к запросу открытый файл. Если режим не разрешил команду, появится кнопка «Разрешить и продолжить». Меню ⋮: новый чат, «Открыть в терминале» (родной интерфейс агента со всеми командами вроде `/model`, `/compact`), «Продолжить этот чат в терминале», выход из аккаунта, обновление.

Под капотом — те же CLI, что используют расширения для VS Code, в неинтерактивном режиме: `claude -p --input-format stream-json --output-format stream-json` (один процесс на чат, `--resume` между запусками) и `codex exec --json` (`resume <id>` для продолжения). Токены хранит сам CLI в Termux (`~/.claude`, `~/.codex`), приложение их не видит.

## Сборка

```bash
flutter pub get
flutter build apk --release
```

Прямо в Termux (нужен Flutter для Termux):

```bash
bash tool/build_in_termux.sh
```

Скрипт подставляет ARM-`aapt2` для Gradle и, если в сборке Flutter нет release-артефактов, собирает debug-версию.

Релизы публикует GitHub Actions (`.github/workflows/build.yml`): достаточно поднять `version` в `pubspec.yaml` и запушить в `main`, после чего CI соберёт APK, поставит тег и создаст релиз. Для подписи нужны секреты `TIDE_KEYSTORE_BASE64` и `TIDE_KEYSTORE_PASSWORD`, без них APK подписывается debug-ключом.

## Структура

```
lib/
  main.dart            запуск, подключение к Termux
  onboarding.dart      мастер первого запуска
  projects_page.dart   проекты, шаблоны
  ide_page.dart        IDE: файлы, вкладки, запуск
  editor.dart          редактор и подсветка
  git.dart, git_panel.dart  Git: статус, diff, коммиты, ветки
  terminal_panel.dart  терминалы (xterm + PTY)
  runner.dart          определение проекта и команды запуска
  extensions.dart      языки и расширения
  agent.dart           ИИ-агент: Claude Code / Codex, чат и вход
  server_manager.dart  установка и запуск сервера в Termux
assets/termux/         server.py, start.sh, install.sh
packages/xterm/        xterm.dart 4.0.0 (MIT) с исправлением Enter на экранной клавиатуре
```

## Лицензия

MIT. Неофициальный проект, не связан с разработчиками Termux.
