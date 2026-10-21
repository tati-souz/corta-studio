#!/bin/zsh
set -eu
cd "$(dirname "$0")"
# Requisitos: Mac com Apple Silicon e as Ferramentas de Linha de Comando do Xcode (xcode-select --install).
if [[ "$(uname -m)" != "arm64" ]]; then echo "O Corta Studio precisa de um Mac com Apple Silicon (M1 ou posterior)."; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then echo "Faltam as Ferramentas de Linha de Comando do Xcode. Rode: xcode-select --install"; exit 1; fi
# Compila numa pasta temporária e instala só em /Applications, para existir uma única cópia do app.
BUILD_DIR="${1:-${TMPDIR:-/tmp}/CortaStudio-build}"
rm -rf "$BUILD_DIR/Corta Studio.app"
mkdir -p "$BUILD_DIR/Corta Studio.app/Contents/MacOS" "$BUILD_DIR/Corta Studio.app/Contents/Resources"
APP_DIR="$BUILD_DIR/Corta Studio.app"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "${TMPDIR:-/tmp}/CortaStudio-module-cache" -framework AVKit -Xlinker -weak_framework -Xlinker ImagePlayground Sources/*.swift -o "$APP_DIR/Contents/MacOS/CortaStudio"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CortaStudio</string>
<key>CFBundleIdentifier</key><string>studio.corta.desktop</string>
<key>CFBundleName</key><string>Corta Studio</string>
<key>CFBundleDisplayName</key><string>Corta Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.14.0</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>O Corta Studio transcreve a fala dos vídeos escolhidos por você para criar legendas.</string>
<key>NSHumanReadableCopyright</key><string>Corta Studio — aplicativo independente. Usa o Claude Code com a assinatura do usuário.</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
echo "Aplicativo criado: $APP_DIR"
# Instala (substitui) a cópia em Aplicativos, que é a que o Spotlight e o Launchpad abrem.
if [[ "${INSTALAR:-1}" == "1" ]]; then
  osascript -e 'tell application id "studio.corta.desktop" to quit' 2>/dev/null || true
  rm -rf "/Applications/Corta Studio.app" && ditto "$APP_DIR" "/Applications/Corta Studio.app" && rm -rf "$APP_DIR"
  mkdir -p ../Biblioteca
  defaults write studio.corta.desktop CortaLibraryPath "$(cd ../Biblioteca && pwd)"
  echo "Instalado em /Applications/Corta Studio.app"
  # Garante o atalho no Dock (aponta sempre para a cópia de Aplicativos) e reabre a versão nova.
  if [[ "${DOCK:-1}" == "1" ]] && ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Applications/Corta%20Studio.app"; then
    defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Corta%20Studio.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>'
    killall Dock || true
  fi
  for i in 1 2 3 4 5 6 7 8; do pgrep -f "Corta Studio.app/Contents/MacOS/CortaStudio" >/dev/null || break; sleep 1; done
  open "/Applications/Corta Studio.app"
  echo "Versão nova aberta."
fi
