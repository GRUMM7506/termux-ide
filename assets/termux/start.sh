#!/data/data/com.termux/files/usr/bin/bash
# Termux IDE: запуск сервера. Обычно его вызывает само приложение.
DIR="$HOME/.termux-ide"
LOG="$DIR/server.log"
TOKEN="${1:-$(cat "$DIR/token" 2>/dev/null)}"
if [ -z "$TOKEN" ]; then
  echo "usage: start.sh <token>   (токен знает приложение)"
  exit 1
fi
mkdir -p "$DIR"
umask 077
echo "$TOKEN" > "$DIR/token"
# Не даём логу разрастаться.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then : > "$LOG"; fi
if ! command -v python >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] python не найден — выполни в Termux: pkg install python" >> "$LOG"
  exit 1
fi
cd "$HOME" || exit 1
echo "[$(date '+%F %T')] start" >> "$LOG"
exec python "$DIR/server.py" "$TOKEN" >> "$LOG" 2>&1
