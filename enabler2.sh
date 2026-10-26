#!/usr/bin/env bash
# Instala Widevine CDM en Zen Browser descargándolo directamente de Mozilla/Google.
# Uso: ./zen-widevine.sh [--no-gmp-sandbox]

set -euo pipefail

DISABLE_SANDBOX=0
[ "${1:-}" = "--no-gmp-sandbox" ] && DISABLE_SANDBOX=1

# Versión de Firefox que se "simula" al consultar el servicio de actualizaciones.
# Zen está basado en Firefox; ajusta si hace falta.
FF_VERSION="${FF_VERSION:-128.0}"
BUILD_ID="20260101000000"
FF_CANDIDATES=(${FF_VERSION:-} 145.0 147.0 150.0 143.0 140.0)

get_attr() { sed -n "s/.*[[:space:]]$1=\"\([^\"]*\)\".*/\1/p" <<< "$2"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== [1/4] Consultando y descargando Widevine CDM ==="

PKG_FILE="$WORKDIR/widevine.crx3"
WV_VERSION=""
for ffv in "${FF_CANDIDATES[@]}"; do
    [ -n "$ffv" ] || continue
    url="https://aus5.mozilla.org/update/3/GMP/${ffv}/${BUILD_ID}/Linux_x86_64-gcc3/en-US/release/Linux/default/default/update.xml"
    echo "-> Probando como Firefox $ffv ..."
    XML=$(curl -fsSL "$url" 2>/dev/null | tr '\n' ' ') || continue

    # Aísla el bloque <addon id="gmp-widevinecdm" ...> ... </addon>
    BLOCK=$(sed -n 's/.*\(<addon id="gmp-widevinecdm".*\)/\1/p' <<< "$XML" | sed 's#</addon>.*#</addon>#')
    [ -n "$BLOCK" ] || continue
    ADDON=$(grep -o '<addon [^>]*>' <<< "$BLOCK" | head -n1)

    WV_URL=$(get_attr URL "$ADDON")
    WV_HASH_FN=$(get_attr hashFunction "$ADDON")
    WV_HASH=$(get_attr hashValue "$ADDON")
    v=$(get_attr version "$ADDON")
    WV_MIRROR=$(grep -o '<mirror URL="[^"]*"' <<< "$BLOCK" | head -n1 | sed 's/.*URL="\([^"]*\)"/\1/')
    [ -n "$WV_URL" ] && [ -n "$WV_HASH" ] && [ -n "$v" ] || continue
    [ "${WV_HASH_FN,,}" = "sha512" ] || continue

    echo "   Versión $v"
    for src in "$WV_URL" "$WV_MIRROR"; do
        [ -n "$src" ] || continue
        echo "   Descargando: $src"
        if curl -fSL --progress-bar -o "$PKG_FILE" "$src"; then
            CALC_HASH=$(sha512sum "$PKG_FILE" | cut -d' ' -f1)
            if [ "${CALC_HASH,,}" = "${WV_HASH,,}" ]; then
                WV_VERSION="$v"
                echo "   ✔ Descargado y hash verificado"
                break 2
            fi
            echo "   ✘ Hash no coincide"
        else
            echo "   ✘ Descarga fallida"
        fi
    done
done

if [ -z "$WV_VERSION" ]; then
    echo "Error: no se pudo descargar un Widevine válido."
    exit 1
fi

# Extraer el CRX3: saltar la cabecera (magic "Cr24" + versión + tamaño + cabecera protobuf)
[ "$(head -c4 "$PKG_FILE")" = "Cr24" ] || { echo "Error: el archivo no es un CRX válido."; exit 1; }
HDR_LEN=$(od -An -t u4 -j 8 -N 4 "$PKG_FILE" | tr -d ' ')
ZIP_FILE="$WORKDIR/widevine.zip"
tail -c +$((12 + HDR_LEN + 1)) "$PKG_FILE" > "$ZIP_FILE"

EXTRACT_DIR="$WORKDIR/cdm"
mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"

CDM_SO=$(find "$EXTRACT_DIR" -name "libwidevinecdm.so" | head -n1)
if [ -z "$CDM_SO" ]; then
    echo "Error: el paquete no contiene libwidevinecdm.so."
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

       # Instalar CDM en gmp-widevinecdm/<versión>/ (libwidevinecdm.so + manifest.json)
    TARGET="$profile_dir/gmp-widevinecdm/$WV_VERSION"
    rm -rf "$profile_dir/gmp-widevinecdm" "$profile_dir/gmp"
    mkdir -p "$TARGET"
    cp "$CDM_SO" "$TARGET/libwidevinecdm.so"
    chmod 755 "$TARGET/libwidevinecdm.so"
    if [ -f "$EXTRACT_DIR/manifest.json" ]; then
        cp "$EXTRACT_DIR/manifest.json" "$TARGET/manifest.json"
    else
        echo "Error: el paquete no trae manifest.json"; exit 1
    fi

    # Limpiar prefs viejas (también de prefs.js, por si quedó basura del script original)
    for f in "$profile_dir/user.js" "$profile_dir/prefs.js"; do
        [ -f "$f" ] && sed -i '/media\.eme\.enabled/d;/media\.gmp-widevinecdm/d;/media\.gmp-provider/d;/browser\.eme\.ui/d' "$f"
    done

    NOW=$(date +%s)
    cat >> "$profile_dir/user.js" << EOF
user_pref("browser.eme.ui.enabled", true);
user_pref("media.eme.enabled", true);
user_pref("media.gmp-provider.enabled", true);
user_pref("media.gmp-widevinecdm.enabled", true);
user_pref("media.gmp-widevinecdm.visible", true);
user_pref("media.gmp-widevinecdm.abi", "x86_64-gcc3");
user_pref("media.gmp-widevinecdm.version", "$WV_VERSION");
user_pref("media.gmp-widevinecdm.lastInstallStart", $((NOW - 5)));
user_pref("media.gmp-widevinecdm.lastDownload", $NOW);
user_pref("media.gmp-widevinecdm.lastUpdate", $NOW);
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
