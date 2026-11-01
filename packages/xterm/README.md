# xterm (vendored)

Copy of [xterm.dart](https://github.com/TerminalStudio/xterm.dart) v4.0.0 (MIT, © 2020 xuty) used by Termux IDE.

Local changes:
- `lib/src/terminal_view.dart`: the soft-keyboard action `TextInputAction.newline` (sent by Android
  for the Enter key when the input type is not multiline) is treated as Enter. Upstream handled only
  `TextInputAction.done`, so Enter on the on-screen keyboard did nothing.
