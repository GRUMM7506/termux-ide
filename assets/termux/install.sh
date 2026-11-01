#!/data/data/com.termux/files/usr/bin/bash
# Termux IDE — подготовка Termux (один раз).
#   curl -fsSL https://raw.githubusercontent.com/GRUMM7506/termux-ide/main/termux/install.sh | bash
set -e
c() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

c "Разрешаю Termux IDE запускать команды (allow-external-apps)"
mkdir -p "$HOME/.termux"
P="$HOME/.termux/termux.properties"
touch "$P"
if grep -qE '^[[:space:]]*allow-external-apps' "$P"; then
  sed -i -E 's/^[[:space:]]*allow-external-apps.*/allow-external-apps = true/' "$P"
else
  echo 'allow-external-apps = true' >> "$P"
fi
termux-reload-settings 2>/dev/null || true

if ! command -v python >/dev/null 2>&1; then
  c "Устанавливаю Python (на нём работает сервер IDE)"
  export DEBIAN_FRONTEND=noninteractive
  pkg update -y
  pkg upgrade -y -o Dpkg::Options::=--force-confold
  pkg install -y python
fi

mkdir -p "$HOME/.termux-ide" "$HOME/projects"
printf '\n\033[1;32m✔ Готово! Вернись в Termux IDE и нажми «Подключить».\033[0m\n\n'
