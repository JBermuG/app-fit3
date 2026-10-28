#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [1/4] Verificando XcodeGen ==="
if ! command -v xcodegen &> /dev/null; then
    echo "XcodeGen no está instalado. Instalando con Homebrew..."
    brew install xcodegen
fi

echo "=== [2/4] Generando proyecto GalaxyFit3.xcodeproj ==="
xcodegen generate

echo "=== [3/4] Compilando GalaxyFit3.app (iOS 15.0+, Release, Sin Firma) ==="
xcodebuild clean build \
    -project GalaxyFit3.xcodeproj \
    -scheme GalaxyFit3 \
    -sdk iphoneos \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

APP_PATH="build/Build/Products/Release-iphoneos/GalaxyFit3.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: No se encontró $APP_PATH tras la compilación."
    exit 1
fi

echo "=== [4/4] Empaquetando GalaxyFit3.ipa ==="
rm -rf Payload GalaxyFit3.ipa
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -r9 GalaxyFit3.ipa Payload
rm -rf Payload

echo "========================================================"
echo "✅ ¡Éxito! Archivo generado en: $SCRIPT_DIR/GalaxyFit3.ipa"
echo "Listo para instalar con AltStore, SideStore o Sideloadly."
echo "========================================================"
