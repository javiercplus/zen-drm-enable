```bash
#!/usr/bin/env bash

set -e

echo "=== [1/4] Locating Widevine CDM (from Waterfox or Firefox) ==="

POSSIBLE_SOURCES=(
    "$HOME/.waterfox"
    "$HOME/.mozilla/firefox"
    "/opt/waterfox"
    "/usr/lib/waterfox"
    "/usr/lib/firefox"
)

SOURCE_WIDEVINE=""
SOURCE_GMP_WIDEVINE=""

for base_dir in "${POSSIBLE_SOURCES[@]}"; do
    if [ -d "$base_dir" ]; then
        for p in "$base_dir"/*; do
            if [ -d "$p/gmp-widevinecdm" ]; then
                if find "$p/gmp-widevinecdm" -name "libwidevinecdm.so" -quit 2>/dev/null; then
                    SOURCE_WIDEVINE="$p/gmp-widevinecdm"
                    if [ -d "$p/gmp/Linux_x86_64-gcc3/gmp-widevinecdm" ]; then
                        SOURCE_GMP_WIDEVINE="$p/gmp/Linux_x86_64-gcc3/gmp-widevinecdm"
                    fi
                    echo "-> Widevine found at: $SOURCE_WIDEVINE"
                    break 2
                fi
            fi
        done
    fi
done

if [ -z "$SOURCE_WIDEVINE" ]; then
    echo "Widevine was not found automatically in the standard locations."
    read -rp "Enter the full path to the 'gmp-widevinecdm' directory: " MANUAL_SRC
    if [ -d "$MANUAL_SRC" ] && find "$MANUAL_SRC" -name "libwidevinecdm.so" -quit 2>/dev/null; then
        SOURCE_WIDEVINE="$MANUAL_SRC"
    else
        echo "Error: The specified path does not contain 'libwidevinecdm.so'."
        exit 1
    fi
fi

echo ""
echo "=== [2/4] Detecting Zen Browser installation and executable ==="

ZEN_BIN=""
POSSIBLE_BINS=(
    "$HOME/.local/share/soar/bin/zen-browser"
    "/usr/bin/zen-browser"
    "/usr/bin/zen"
    "/usr/local/bin/zen-browser"
    "/usr/local/bin/zen"
    "/opt/zen-browser/zen"
    "/opt/zen/zen"
    "$HOME/.local/bin/zen"
    "$HOME/.local/bin/zen-browser"
)

if command -v zen-browser >/dev/null 2>&1; then
    ZEN_BIN=$(command -v zen-browser)
elif command -v zen >/dev/null 2>&1; then
    ZEN_BIN=$(command -v zen)
fi

if [ -z "$ZEN_BIN" ]; then
    for candidate in "${POSSIBLE_BINS[@]}"; do
        if [ -x "$candidate" ] || [ -f "$candidate" ]; then
            ZEN_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$ZEN_BIN" ]; then
    echo "Zen Browser's executable could not be detected automatically."
    while [ -z "$ZEN_BIN" ]; do
        read -rp "Please enter the full path to the Zen Browser executable: " USER_INPUT_BIN
        USER_INPUT_BIN="${USER_INPUT_BIN/#\~/$HOME}"
        if [ -x "$USER_INPUT_BIN" ] || [ -f "$USER_INPUT_BIN" ]; then
            ZEN_BIN="$USER_INPUT_BIN"
        else
            echo "Invalid path or file is not executable: $USER_INPUT_BIN"
        fi
    done
fi

echo "-> Zen executable detected at: $ZEN_BIN"

REAL_ZEN_BIN="$ZEN_BIN"
if [ -L "$ZEN_BIN" ]; then
    TARGET=$(readlink -f "$ZEN_BIN")

    if grep -q "zen-browser-wrapper" <<< "$ZEN_BIN" || grep -q "MOZ_DISABLE_GMP_SANDBOX" "$ZEN_BIN" 2>/dev/null; then
        REAL_ZEN_BIN="$TARGET"
    else
        REAL_ZEN_BIN="$TARGET"
    fi
fi

echo ""
echo "=== [3/4] Configuring sandbox compatibility (preventing Widevine crashes) ==="

IS_SOAR=0
SOAR_PACKAGE_DIR=""
for p in "$HOME"/.local/share/soar/packages/zen-browser-*; do
    if [ -d "$p" ]; then
        IS_SOAR=1
        SOAR_PACKAGE_DIR="$p"
        break
    fi
done

if [ "$IS_SOAR" -eq 1 ] && [ -n "$SOAR_PACKAGE_DIR" ]; then
    echo "-> Soar installation detected at: $SOAR_PACKAGE_DIR"
    echo "MOZ_DISABLE_GMP_SANDBOX=1" > "$SOAR_PACKAGE_DIR/zen-browser.env"

    WRAPPER_PATH="$HOME/.local/share/soar/bin/zen-browser-wrapper"
    cat << WRAPPER_EOF > "$WRAPPER_PATH"
#!/usr/bin/env bash
export MOZ_DISABLE_GMP_SANDBOX=1
exec "$SOAR_PACKAGE_DIR/zen-browser" "\$@"
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"
    ln -sf "$WRAPPER_PATH" "$HOME/.local/share/soar/bin/zen-browser"
    echo "   ✔ Soar wrapper configured successfully."
else
    echo "-> Checking environment for executable: $REAL_ZEN_BIN"

    if [[ "$REAL_ZEN_BIN" == "$HOME"* ]] && [ -f "$REAL_ZEN_BIN" ]; then
        ENV_FILE="${REAL_ZEN_BIN}.env"
        echo "MOZ_DISABLE_GMP_SANDBOX=1" >> "$ENV_FILE" 2>/dev/null || true
    fi

    mkdir -p "$HOME/.local/bin"
    cat << WRAPPER_EOF > "$HOME/.local/bin/zen-browser"
#!/usr/bin/env bash
export MOZ_DISABLE_GMP_SANDBOX=1
exec "$REAL_ZEN_BIN" "\$@"
WRAPPER_EOF
    chmod +x "$HOME/.local/bin/zen-browser"
    echo "   ✔ Safe launcher created at ~/.local/bin/zen-browser"
fi

echo ""
echo "=== [4/4] Applying Widevine to Zen Browser profiles ==="

ZEN_PROFILES_DIR=""
for candidate_dir in "$HOME/.config/zen" "$HOME/.zen"; do
    if [ -d "$candidate_dir" ]; then
        ZEN_PROFILES_DIR="$candidate_dir"
        break
    fi
done

if [ -z "$ZEN_PROFILES_DIR" ]; then
    echo "The default profile directory (~/.config/zen or ~/.zen) was not found."
    read -rp "Enter the path to the Zen profiles directory: " USER_PROFILES
    USER_PROFILES="${USER_PROFILES/#\~/$HOME}"
    ZEN_PROFILES_DIR="$USER_PROFILES"
fi

echo "-> Profiles directory: $ZEN_PROFILES_DIR"

killall -q zen zen-bin 2>/dev/null || true
sleep 1

PROFILES_FOUND=0
for profile_dir in "$ZEN_PROFILES_DIR"/*; do
    if [ -d "$profile_dir" ] && [ -f "$profile_dir/prefs.js" ]; then
        PROFILES_FOUND=$((PROFILES_FOUND + 1))
        profile_name=$(basename "$profile_dir")
        echo "--> Configuring profile: $profile_name"

        # 1. Copy Widevine components
        mkdir -p "$profile_dir/gmp-widevinecdm"
        cp -r "$SOURCE_WIDEVINE"/* "$profile_dir/gmp-widevinecdm/"

        if [ -n "$SOURCE_GMP_WIDEVINE" ]; then
            mkdir -p "$profile_dir/gmp/Linux_x86_64-gcc3/gmp-widevinecdm"
            cp -r "$SOURCE_GMP_WIDEVINE"/* "$profile_dir/gmp/Linux_x86_64-gcc3/gmp-widevinecdm/" 2>/dev/null || true
        fi

        cat << 'USERJS' > "$profile_dir/user.js"
// DRM / Widevine CDM configuration
user_pref("browser.eme.ui.enabled", true);
user_pref("browser.eme.ui.firstContentShown", true);
user_pref("media.eme.enabled", true);
user_pref("media.gmp-provider.enabled", true);
user_pref("media.gmp-widevinecdm.abi", "x86_64-gcc3");
user_pref("media.gmp-widevinecdm.autoupdate", false);
user_pref("media.gmp-widevinecdm.enabled", true);
user_pref("media.gmp-widevinecdm.hashValue", "e578b2eed7ac887e13efd559e917e488ece43beb49db40a133c18f57bf9f6ed5da5434534e70f7fc3cf4eefdb9c766164b6559c513e1738e899d84d7943d577a");
user_pref("media.gmp-widevinecdm.lastDownload", 1792254175);
user_pref("media.gmp-widevinecdm.lastInstallStart", 1792254169);
user_pref("media.gmp-widevinecdm.lastUpdate", 1792254175);
user_pref("media.gmp-widevinecdm.version", "4.10.3050.0");
user_pref("media.gmp-widevinecdm.visible", true);
USERJS

        sed -i '/media.eme.enabled/d;/media.gmp-widevinecdm/d;/media.gmp-provider/d;/browser.eme.ui/d' "$profile_dir/prefs.js"
        cat << 'PREFS' >> "$profile_dir/prefs.js"
user_pref("browser.eme.ui.enabled", true);
user_pref("browser.eme.ui.firstContentShown", true);
user_pref("media.eme.enabled", true);
user_pref("media.gmp-provider.enabled", true);
user_pref("media.gmp-widevinecdm.abi", "x86_64-gcc3");
user_pref("media.gmp-widevinecdm.autoupdate", false);
user_pref("media.gmp-widevinecdm.enabled", true);
user_pref("media.gmp-widevinecdm.hashValue", "e578b2eed7ac887e13efd559e917e488ece43beb49db40a133c18f57bf9f6ed5da5434534e70f7fc3cf4eefdb9c766164b6559c513e1738e899d84d7943d577a");
user_pref("media.gmp-widevinecdm.lastDownload", 1792254175);
user_pref("media.gmp-widevinecdm.lastInstallStart", 1792254169);
user_pref("media.gmp-widevinecdm.lastUpdate", 1792254175);
user_pref("media.gmp-widevinecdm.version", "4.10.3050.0");
user_pref("media.gmp-widevinecdm.visible", true);
PREFS

        echo "   ✔ Profile '$profile_name' configured successfully."
    fi
done

if [ "$PROFILES_FOUND" -eq 0 ]; then
    echo "Warning: No profiles containing 'prefs.js' were found in $ZEN_PROFILES_DIR."
    echo "If you have just installed Zen, open it at least once to generate a profile, then run this script again."
fi

echo ""
echo "=== Done! Widevine DRM has been configured for Zen Browser ==="
```
