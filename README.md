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
- **Языки и расширения**: Python, Node.js, C/C++, Java, Kotlin, Gradle, Go, Rust, Dart, Ruby, PHP, Git ставятся в Termux одной кнопкой.
- **Мастер первого запуска**: проводит через установку Termux, одну команду подготовки и разрешение. Сервер IDE ставится и обновляется сам.
- **Проекты**: шаблоны для 10+ языков, дерево файлов (создать, переименовать, удалить), сборка и установка APK.
- Работает в оконном режиме и на планшетах (дерево файлов слева).

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

- `assets/termux/server.py` — сервер только на стандартной библиотеке Python: HTTP API для файлов и WebSocket с PTY для терминалов. Слушает **только `127.0.0.1:8765`** и пускает по токену, который генерирует приложение.
- Приложение само кладёт сервер в `~/.termux-ide/` через Termux `RUN_COMMAND` и обновляет его, если версия изменилась.
- Лог сервера: `~/.termux-ide/server.log`.

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
  terminal_panel.dart  терминалы (xterm + PTY)
  runner.dart          определение проекта и команды запуска
  extensions.dart      языки и расширения
  server_manager.dart  установка и запуск сервера в Termux
assets/termux/         server.py, start.sh, install.sh
```

## Лицензия

MIT. Неофициальный проект, не связан с разработчиками Termux.
