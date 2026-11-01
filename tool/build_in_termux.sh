#!/data/data/com.termux/files/usr/bin/bash
# Собрать Termux IDE прямо в Termux (нужен Flutter для Termux).
#   bash tool/build_in_termux.sh
set -e
cd "$(dirname "$0")/.."
# Gradle качает aapt2 для x86 — подставляем ARM-версию из Termux.
if ! grep -qs aapt2FromMavenOverride "$HOME/.gradle/gradle.properties"; then
  command -v aapt2 >/dev/null || pkg install -y aapt2
  mkdir -p "$HOME/.gradle"
  echo "android.aapt2FromMavenOverride=$PREFIX/bin/aapt2" >> "$HOME/.gradle/gradle.properties"
fi
flutter pub get
# В сборках flutter для Termux часто нет release-артефактов движка — тогда собираем debug.
if flutter build apk --release; then
  APK=build/app/outputs/flutter-apk/app-release.apk
else
  flutter build apk --debug
  APK=build/app/outputs/flutter-apk/app-debug.apk
fi
echo "APK: $APK"
termux-open "$APK" 2>/dev/null || true
