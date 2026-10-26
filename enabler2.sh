#!/usr/bin/env bash
# Instala Widevine CDM en Zen Browser descargándolo directamente de Mozilla/Google.
# Uso: ./zen-widevine.sh [--no-gmp-sandbox]

set -euo pipefail

DISABLE_SANDBOX=0
[ "${1:-}" = "--no-gmp-sandbox" ] && DISABLE_SANDBOX=1

# Versión de Firefox que se "simula" al consultar el servicio de actualizaciones.
# Zen está basado en Firefox; ajusta si hace falta.
FF_VERSION="${FF_VERSION:-128.0}"
BUILD_ID="20240101000000"
GMP_UPDATE_URL="https://aus5.mozilla.org/update/3/GMP/${FF_VERSION}/${BUILD_ID}/Linux_x86_64-gcc3/en-US/release/Linux/default/default/update.xml"

# ---------- Dependencias ----------
for cmd in curl unzip sha512sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: falta '$cmd'. Instálalo e intenta de nuevo."; exit 1; }
done

# Extrae un atributo de una etiqueta <addon ...>
get_attr() { sed -n "s/.*[[:space:]]$1=\"\([^\"]*\)\".*/\1/p" <<< "$2"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== [1/4] Consultando y descargando Widevine CDM ==="

XML=$(curl -fsSL "$GMP_UPDATE_URL" | tr '\n' ' ')
ADDON=$(grep -o '<addon [^>]*gmp-widevinecdm[^>]*>' <<< "$XML" | head -n1 || true)

if [ -z "$ADDON" ]; then
    echo "Error: no se pudo obtener la información de Widevine desde Mozilla."
    echo "URL consultada: $GMP_UPDATE_URL"
    exit 1
fi

WV_URL=$(get_attr URL "$ADDON")
WV_HASH_FN=$(get_attr hashFunction "$ADDON")
WV_HASH=$(get_attr hashValue "$ADDON")
WV_VERSION=$(get_attr version "$ADDON")

if [ -z "$WV_URL" ] || [ -z "$WV_HASH" ] || [ -z "$WV_VERSION" ]; then
    echo "Error: respuesta inesperada del servidor de actualizaciones."
    exit 1
fi

echo "-> Versión: $WV_VERSION"
echo "-> URL:     $WV_URL"

ZIP_FILE="$WORKDIR/widevine.zip"
curl -fSL --progress-bar -o "$ZIP_FILE" "$WV_URL"

if [ "${WV_HASH_FN,,}" != "sha512" ]; then
    echo "Error: función hash no soportada ($WV_HASH_FN)."
    exit 1
fi
CALC_HASH=$(sha512sum "$ZIP_FILE" | cut -d' ' -f1)
if [ "${CALC_HASH,,}" != "${WV_HASH,,}" ]; then
    echo "Error: el hash SHA-512 no coincide. Descarga corrupta o manipulada."
    exit 1
fi
echo "   ✔ Hash verificado"

EXTRACT_DIR="$WORKDIR/cdm"
mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"

CDM_SO=$(find "$EXTRACT_DIR" -name "libwidevinecdm.so" | head -n1)
if [ -z "$CDM_SO" ]; then
    echo "Error: el paquete descargado no contiene libwidevinecdm.so."
    exit 1
fi
CDM_SRC_DIR=$(dirname "$CDM_SO")

echo ""
echo "=== [2/4] Detectando Zen Browser ==="

ZEN_BIN=""
if command -v zen-browser >/dev/null 2>&1; then
    ZEN_BIN=$(command -v zen-browser)
elif command -v zen >/dev/null 2>&1; then
    ZEN_BIN=$(command -v zen)
else
    for candidate in \
        "$HOME/.local/share/soar/bin/zen-browser" \
        /opt/zen-browser/zen /opt/zen/zen /usr/lib/zen-browser/zen \
        "$HOME/.local/bin/zen" "$HOME/.local/bin/zen-browser"; do
        if [ -x "$candidate" ]; then ZEN_BIN="$candidate"; break; fi
    done
fi

while [ -z "$ZEN_BIN" ]; do
    read -rp "No se detectó Zen. Ruta completa al ejecutable: " INPUT
    INPUT="${INPUT/#\~/$HOME}"
    [ -x "$INPUT" ] && ZEN_BIN="$INPUT" || echo "Ruta no válida: $INPUT"
done
echo "-> Zen detectado en: $ZEN_BIN"

echo ""
echo "=== [3/4] Sandbox de GMP (opcional) ==="

if [ "$DISABLE_SANDBOX" -eq 1 ]; then
    REAL_ZEN_BIN=$(readlink -f "$ZEN_BIN")
    LAUNCHER="$HOME/.local/bin/zen-widevine"
    mkdir -p "$HOME/.local/bin"
    cat > "$LAUNCHER" << EOF
#!/usr/bin/env bash
export MOZ_DISABLE_GMP_SANDBOX=1
exec "$REAL_ZEN_BIN" "\$@"
EOF
    chmod +x "$LAUNCHER"
    echo "   ✔ Lanzador creado: $LAUNCHER (úsalo para abrir Zen)"
else
    echo "-> Omitido. Si Widevine crashea, vuelve a ejecutar con --no-gmp-sandbox"
fi

echo ""
echo "=== [4/4] Instalando Widevine en los perfiles de Zen ==="

ZEN_PROFILES_DIR=""
for d in "$HOME/.config/zen" "$HOME/.zen" "$HOME/.var/app/app.zen_browser.zen/.zen"; do
    [ -d "$d" ] && { ZEN_PROFILES_DIR="$d"; break; }
done
if [ -z "$ZEN_PROFILES_DIR" ]; then
    read -rp "Ruta a la carpeta de perfiles de Zen: " ZEN_PROFILES_DIR
    ZEN_PROFILES_DIR="${ZEN_PROFILES_DIR/#\~/$HOME}"
fi
echo "-> Perfiles en: $ZEN_PROFILES_DIR"

pkill -x zen-bin 2>/dev/null || true
pkill -x zen 2>/dev/null || true
sleep 1

PROFILES_FOUND=0
for profile_dir in "$ZEN_PROFILES_DIR"/*; do
    [ -d "$profile_dir" ] && [ -f "$profile_dir/prefs.js" ] || continue
    PROFILES_FOUND=$((PROFILES_FOUND + 1))
    name=$(basename "$profile_dir")
    echo "--> Perfil: $name"

    # Instalar CDM en gmp-widevinecdm/<versión>/ (estructura que espera Firefox)
    TARGET="$profile_dir/gmp-widevinecdm/$WV_VERSION"
    rm -rf "$profile_dir/gmp-widevinecdm"
    mkdir -p "$TARGET"
    cp -r "$CDM_SRC_DIR"/. "$TARGET/"
    chmod 755 "$TARGET/libwidevinecdm.so"

    # user.js: se conservan las líneas ajenas y se reemplazan solo las de Widevine
    USERJS="$profile_dir/user.js"
    touch "$USERJS"
    sed -i '/media\.eme\.enabled/d;/media\.gmp-widevinecdm/d;/media\.gmp-provider/d;/browser\.eme\.ui/d' "$USERJS"
    cat >> "$USERJS" << EOF
user_pref("browser.eme.ui.enabled", true);
user_pref("media.eme.enabled", true);
user_pref("media.gmp-provider.enabled", true);
user_pref("media.gmp-widevinecdm.enabled", true);
user_pref("media.gmp-widevinecdm.visible", true);
user_pref("media.gmp-widevinecdm.abi", "x86_64-gcc3");
user_pref("media.gmp-widevinecdm.version", "$WV_VERSION");
user_pref("media.gmp-widevinecdm.autoupdate", false);
EOF

    echo "   ✔ Instalado Widevine $WV_VERSION"
done

if [ "$PROFILES_FOUND" -eq 0 ]; then
    echo "Aviso: no se encontraron perfiles con prefs.js en $ZEN_PROFILES_DIR."
    echo "Abre Zen al menos una vez para crear el perfil y vuelve a ejecutar el script."
fi

echo ""
echo "=== ¡Listo! Widevine $WV_VERSION instalado. Abre Zen y comprueba en about:addons > Plugins ==="
