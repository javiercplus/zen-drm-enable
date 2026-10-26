#!/usr/bin/env bash
# Installs the Widevine CDM into Zen Browser by downloading it directly from Mozilla/Google.
# Usage: ./zen-widevine.sh [--no-gmp-sandbox]

set -euo pipefail

DISABLE_SANDBOX=0
[ "${1:-}" = "--no-gmp-sandbox" ] && DISABLE_SANDBOX=1

# Firefox version that is "simulated" when querying the update service.
# Zen is based on Firefox; adjust if needed.
FF_VERSION="${FF_VERSION:-128.0}"
BUILD_ID="20260101000000"
FF_CANDIDATES=(${FF_VERSION:-} 145.0 147.0 150.0 143.0 140.0)

get_attr() { sed -n "s/.*[[:space:]]$1=\"\([^\"]*\)\".*/\1/p" <<< "$2"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== [1/4] Querying and downloading Widevine CDM ==="

PKG_FILE="$WORKDIR/widevine.crx3"
WV_VERSION=""
for ffv in "${FF_CANDIDATES[@]}"; do
    [ -n "$ffv" ] || continue
    url="https://aus5.mozilla.org/update/3/GMP/${ffv}/${BUILD_ID}/Linux_x86_64-gcc3/en-US/release/Linux/default/default/update.xml"
    echo "-> Trying as Firefox $ffv ..."
    XML=$(curl -fsSL "$url" 2>/dev/null | tr '\n' ' ') || continue

    # Isolate the <addon id="gmp-widevinecdm" ...> ... </addon> block
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

    echo "   Version $v"
    for src in "$WV_URL" "$WV_MIRROR"; do
        [ -n "$src" ] || continue
        echo "   Downloading: $src"
        if curl -fSL --progress-bar -o "$PKG_FILE" "$src"; then
            CALC_HASH=$(sha512sum "$PKG_FILE" | cut -d' ' -f1)
            if [ "${CALC_HASH,,}" = "${WV_HASH,,}" ]; then
                WV_VERSION="$v"
                echo "   ✔ Downloaded and hash verified"
                break 2
            fi
            echo "   ✘ Hash mismatch"
        else
            echo "   ✘ Download failed"
        fi
    done
done

if [ -z "$WV_VERSION" ]; then
    echo "Error: could not download a valid Widevine package."
    exit 1
fi

# Extract the CRX3: skip the header (magic "Cr24" + version + size + protobuf header)
[ "$(head -c4 "$PKG_FILE")" = "Cr24" ] || { echo "Error: the file is not a valid CRX."; exit 1; }
HDR_LEN=$(od -An -t u4 -j 8 -N 4 "$PKG_FILE" | tr -d ' ')
ZIP_FILE="$WORKDIR/widevine.zip"
tail -c +$((12 + HDR_LEN + 1)) "$PKG_FILE" > "$ZIP_FILE"

EXTRACT_DIR="$WORKDIR/cdm"
mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"

CDM_SO=$(find "$EXTRACT_DIR" -name "libwidevinecdm.so" | head -n1)
if [ -z "$CDM_SO" ]; then
    echo "Error: the package does not contain libwidevinecdm.so."
    exit 1
fi
CDM_SRC_DIR=$(dirname "$CDM_SO")

echo ""
echo "=== [2/4] Detecting Zen Browser ==="

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
    read -rp "Zen not detected. Full path to the executable: " INPUT
    INPUT="${INPUT/#\~/$HOME}"
    [ -x "$INPUT" ] && ZEN_BIN="$INPUT" || echo "Invalid path: $INPUT"
done
echo "-> Zen detected at: $ZEN_BIN"

echo ""
echo "=== [3/4] GMP sandbox (optional) ==="

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
    echo "   ✔ Launcher created: $LAUNCHER (use it to open Zen)"
else
    echo "-> Skipped. If Widevine crashes, run again with --no-gmp-sandbox"
fi

echo ""
echo "=== [4/4] Installing Widevine into Zen profiles ==="

ZEN_PROFILES_DIR=""
for d in "$HOME/.config/zen" "$HOME/.zen" "$HOME/.var/app/app.zen_browser.zen/.zen"; do
    [ -d "$d" ] && { ZEN_PROFILES_DIR="$d"; break; }
done
if [ -z "$ZEN_PROFILES_DIR" ]; then
    read -rp "Path to the Zen profiles folder: " ZEN_PROFILES_DIR
    ZEN_PROFILES_DIR="${ZEN_PROFILES_DIR/#\~/$HOME}"
fi
echo "-> Profiles in: $ZEN_PROFILES_DIR"

pkill -x zen-bin 2>/dev/null || true
pkill -x zen 2>/dev/null || true
sleep 1

PROFILES_FOUND=0
for profile_dir in "$ZEN_PROFILES_DIR"/*; do
    [ -d "$profile_dir" ] && [ -f "$profile_dir/prefs.js" ] || continue
    PROFILES_FOUND=$((PROFILES_FOUND + 1))
    name=$(basename "$profile_dir")
    echo "--> Profile: $name"

    # Install CDM into gmp-widevinecdm/<version>/ (libwidevinecdm.so + manifest.json)
    TARGET="$profile_dir/gmp-widevinecdm/$WV_VERSION"
    rm -rf "$profile_dir/gmp-widevinecdm" "$profile_dir/gmp"
    mkdir -p "$TARGET"
    cp "$CDM_SO" "$TARGET/libwidevinecdm.so"
    chmod 755 "$TARGET/libwidevinecdm.so"
    if [ -f "$EXTRACT_DIR/manifest.json" ]; then
        cp "$EXTRACT_DIR/manifest.json" "$TARGET/manifest.json"
    else
        echo "Error: the package does not include manifest.json"; exit 1
    fi

    # Clean old prefs (also from prefs.js, in case leftovers remain from the original script)
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

    echo "   ✔ Installed Widevine $WV_VERSION"
done

if [ "$PROFILES_FOUND" -eq 0 ]; then
    echo "Warning: no profiles with prefs.js found in $ZEN_PROFILES_DIR."
    echo "Open Zen at least once to create the profile, then run the script again."
fi

echo ""
echo "=== Done! Widevine $WV_VERSION installed. Open Zen and check about:addons > Plugins ==="
