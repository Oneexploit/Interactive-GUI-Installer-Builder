#!/bin/bash
# Interactive GUI Installer Builder
# Builds Linux self-extracting installers and macOS PKG/DMG packages.

set -euo pipefail

# ═══════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════

SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [[ "$SCRIPT_PATH" == */ServerDeployment ]]; then
    ROOT_DIR="$(dirname "$SCRIPT_PATH")"
else
    ROOT_DIR="$SCRIPT_PATH"
fi
cd "$ROOT_DIR"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Linux*)  HOST_PLATFORM="Linux" ;;
    Darwin*) HOST_PLATFORM="macOS" ;;
    *)       HOST_PLATFORM="Unknown" ;;
esac

info()  { echo "ℹ️  $*"; }
success(){ echo "✅ $*"; }
warn()  { echo "⚠️  $*"; }
error() { echo "❌ $*"; exit 1; }

ask() {
    local prompt="$1"
    local default_value="${2:-}"
    local answer

    if [ -n "$default_value" ]; then
        read -r -p "$prompt [$default_value]: " answer
        printf '%s' "${answer:-$default_value}"
    else
        read -r -p "$prompt: " answer
        printf '%s' "$answer"
    fi
}

ask_required() {
    local prompt="$1"
    local default_value="${2:-}"
    local answer

    while true; do
        answer="$(ask "$prompt" "$default_value")"
        if [ -n "$answer" ]; then
            printf '%s' "$answer"
            return 0
        fi
        warn "This value is required."
    done
}

ask_yes_no() {
    local prompt="$1"
    local default_value="${2:-Y}"
    local answer

    while true; do
        read -r -p "$prompt [$default_value]: " answer
        answer="${answer:-$default_value}"
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) warn "Please enter y or n." ;;
        esac
    done
}

make_slug() {
    local raw="$1"
    printf '%s' "$raw" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-//; s/-$//'
}

lowercase() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

abs_path() {
    local path="$1"
    if [ -z "$path" ]; then
        printf ''
    elif [ "$path" = "~" ]; then
        printf '%s' "$HOME"
    elif [[ "$path" == ~/* ]]; then
        printf '%s/%s' "$HOME" "${path#~/}"
    elif [[ "$path" = /* ]]; then
        printf '%s' "$path"
    else
        printf '%s/%s' "$ROOT_DIR" "$path"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

file_ext() {
    local file="$1"
    local base="${file##*/}"
    if [[ "$base" == *.* ]]; then
        printf '%s' "${base##*.}"
    else
        printf ''
    fi
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
}

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

validate_target() {
    local value="$1"
    case "$value" in
        auto|linux|macos|both) return 0 ;;
        *) return 1 ;;
    esac
}

print_header() {
    clear || true
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        Interactive GUI Installer Builder         ║"
    echo "║        Linux .run  |  macOS .pkg/.dmg            ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "🖥️  Host platform: $HOST_PLATFORM"
    echo "📂 Project root:   $ROOT_DIR"
    echo ""
}

# ═══════════════════════════════════════════════════
# Interactive configuration
# ═══════════════════════════════════════════════════

print_header

DEFAULT_APP_NAME="One-Exploit"
APP_SLUG_DEFAULT="$(make_slug "$DEFAULT_APP_NAME")"

APP_DISPLAY_NAME="$(ask_required "Application display name" "One-Exploit Trading Platform")"
APP_SLUG="$(ask_required "Application slug / file prefix (no spaces)" "$APP_SLUG_DEFAULT")"
APP_SLUG="$(make_slug "$APP_SLUG")"
[ -n "$APP_SLUG" ] || error "Application slug cannot be empty."

BINARY_NAME="$(ask_required "Main binary/executable name inside publish folder" "One-Exploit")"
VERSION="$(ask_required "Version" "2.0.5")"

ARG_TARGET="${1:-auto}"
if ! validate_target "$ARG_TARGET"; then
    warn "Unknown target argument '$ARG_TARGET'. Using auto."
    ARG_TARGET="auto"
fi

while true; do
    TARGET="$(ask_required "Target platform: auto, linux, macos, both" "$ARG_TARGET")"
    TARGET="$(lowercase "$TARGET")"
    if validate_target "$TARGET"; then
        break
    fi
    warn "Allowed values: auto, linux, macos, both"
done

if [ "$TARGET" = "auto" ]; then
    case "$HOST_PLATFORM" in
        Linux) TARGET="linux" ;;
        macOS) TARGET="macos" ;;
        *) error "Cannot auto-detect target platform. Choose linux or macos." ;;
    esac
fi

BUILD_LINUX=false
BUILD_MACOS=false
case "$TARGET" in
    linux) BUILD_LINUX=true ;;
    macos) BUILD_MACOS=true ;;
    both) BUILD_LINUX=true; BUILD_MACOS=true ;;
esac

if [ "$BUILD_MACOS" = true ] && [ "$HOST_PLATFORM" != "macOS" ]; then
    warn "macOS PKG/DMG can only be built on macOS because pkgbuild/productbuild/hdiutil are native macOS tools."
    if [ "$BUILD_LINUX" = false ]; then
        error "Run this script on macOS, or choose linux as target."
    fi
    warn "Continuing with Linux build only."
    BUILD_MACOS=false
fi

OUTPUT_DIR_INPUT="$(ask_required "Where should generated setup files be saved?" "Installers")"
OUTPUT_DIR="$(abs_path "$OUTPUT_DIR_INPUT")"
mkdir -p "$OUTPUT_DIR"

COMMON_ICON_INPUT="$(ask "Icon/image path for the app (PNG for Linux, ICNS/PNG for macOS; leave empty to skip)" "UNFXCO.UI/Assets/One-Exploit.png")"
ICON_PATH="$(abs_path "$COMMON_ICON_INPUT")"
if [ -n "$COMMON_ICON_INPUT" ] && [ ! -f "$ICON_PATH" ]; then
    warn "Icon was not found: $ICON_PATH"
    if ask_yes_no "Continue without icon?" "N"; then
        ICON_PATH=""
    else
        while true; do
            COMMON_ICON_INPUT="$(ask "Enter a valid icon/image path, or leave empty to skip" "")"
            ICON_PATH="$(abs_path "$COMMON_ICON_INPUT")"
            if [ -z "$COMMON_ICON_INPUT" ] || [ -f "$ICON_PATH" ]; then
                break
            fi
            warn "File not found: $ICON_PATH"
        done
    fi
fi

APP_COMMENT="$(ask "App comment/description" "Professional Trading Platform for Financial Markets")"
GENERIC_NAME="$(ask "Generic name" "Trading Platform")"
WEBSITE="$(ask "Website shown in README (optional)" "https://oneexploit.com")"

if [ "$BUILD_LINUX" = true ]; then
    DEFAULT_LINUX_BUILD_DIR="Build/Release/$VERSION/linux-x64"
    LINUX_BUILD_DIR="$(abs_path "$(ask_required "Linux publish/build folder" "$DEFAULT_LINUX_BUILD_DIR")")"
    LINUX_INSTALL_DIR="$(ask_required "Linux install path" "/opt/$APP_SLUG")"
    LINUX_SYMLINK_NAME="$(ask_required "Linux terminal command / symlink name" "$APP_SLUG")"
    DESKTOP_CATEGORIES="$(ask "Linux desktop categories" "Office;Finance;")"
    DESKTOP_KEYWORDS="$(ask "Linux desktop keywords" "trading;finance;forex;stocks;crypto;")"
fi

if [ "$BUILD_MACOS" = true ]; then
    DEFAULT_MACOS_BUILD_DIR="Build/Release/$VERSION/macos-x64"
    MACOS_BUILD_DIR="$(abs_path "$(ask_required "macOS publish/build folder" "$DEFAULT_MACOS_BUILD_DIR")")"
    APP_BUNDLE_NAME="$(ask_required "macOS .app bundle name" "$APP_SLUG.app")"
    MACOS_BUNDLE_ID_DEFAULT="com.oneexploit.$(lowercase "$APP_SLUG")"
    MACOS_BUNDLE_ID="$(ask_required "macOS bundle/package identifier" "$MACOS_BUNDLE_ID_DEFAULT")"
    MACOS_DMG_SIZE="$(ask_required "macOS DMG size" "500m")"
    MACOS_SIGN_IDENTITY="$(ask "macOS Developer ID signing identity (optional; leave empty to skip)" "")"
fi

echo ""
echo "════════════════════════════════════════════════"
echo "Configuration summary"
echo "════════════════════════════════════════════════"
echo "App name:      $APP_DISPLAY_NAME"
echo "Slug:          $APP_SLUG"
echo "Version:       $VERSION"
echo "Binary:        $BINARY_NAME"
echo "Target:        $TARGET"
echo "Output:        $OUTPUT_DIR"
if [ -n "$ICON_PATH" ]; then
    echo "Icon:          $ICON_PATH"
else
    echo "Icon:          none"
fi
if [ "$BUILD_LINUX" = true ]; then
    echo "Linux build:   $LINUX_BUILD_DIR"
    echo "Linux install: $LINUX_INSTALL_DIR"
fi
if [ "$BUILD_MACOS" = true ]; then
    echo "macOS build:   $MACOS_BUILD_DIR"
    echo "macOS bundle:  $APP_BUNDLE_NAME"
    echo "macOS ID:      $MACOS_BUNDLE_ID"
fi
echo ""
ask_yes_no "Start building with this configuration?" "Y" || { echo "Cancelled."; exit 0; }

# ═══════════════════════════════════════════════════
# Linux builder
# ═══════════════════════════════════════════════════

build_linux_installer() {
    echo ""
    echo "════════════════════════════════════════════════"
    echo "🐧 Building Linux installer"
    echo "════════════════════════════════════════════════"
    echo ""

    [ -d "$LINUX_BUILD_DIR" ] || error "Linux build folder not found: $LINUX_BUILD_DIR"
    [ -f "$LINUX_BUILD_DIR/$BINARY_NAME" ] || error "Binary not found: $LINUX_BUILD_DIR/$BINARY_NAME"

    local temp_dir payload_dir archive_file installer_file launcher_file icon_payload_name icon_install_name ext
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_SLUG}-linux.XXXXXX")"
    payload_dir="$temp_dir/payload"
    mkdir -p "$payload_dir"

    echo "[1/4] 📦 Preparing payload..."
    cp -a "$LINUX_BUILD_DIR/." "$payload_dir/"
    chmod +x "$payload_dir/$BINARY_NAME"

    icon_payload_name=""
    icon_install_name=""
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        ext="$(file_ext "$ICON_PATH")"
        [ -n "$ext" ] || ext="png"
        icon_payload_name="$APP_SLUG-icon.$ext"
        icon_install_name="$APP_SLUG.$ext"
        cp "$ICON_PATH" "$payload_dir/$icon_payload_name"
    fi

    archive_file="$temp_dir/${APP_SLUG}-${VERSION}-linux-gui.tar.gz"
    tar czf "$archive_file" -C "$payload_dir" .

    echo "[2/4] 📝 Creating self-extracting installer..."
    installer_file="$OUTPUT_DIR/${APP_SLUG}-${VERSION}-Linux-GUI.run"

    local q_version q_install_dir q_binary q_display q_slug q_symlink q_icon_payload q_icon_install q_comment q_generic q_categories q_keywords q_website
    q_version="$(shell_quote "$VERSION")"
    q_install_dir="$(shell_quote "$LINUX_INSTALL_DIR")"
    q_binary="$(shell_quote "$BINARY_NAME")"
    q_display="$(shell_quote "$APP_DISPLAY_NAME")"
    q_slug="$(shell_quote "$APP_SLUG")"
    q_symlink="$(shell_quote "$LINUX_SYMLINK_NAME")"
    q_icon_payload="$(shell_quote "$icon_payload_name")"
    q_icon_install="$(shell_quote "$icon_install_name")"
    q_comment="$(shell_quote "$APP_COMMENT")"
    q_generic="$(shell_quote "$GENERIC_NAME")"
    q_categories="$(shell_quote "$DESKTOP_CATEGORIES")"
    q_keywords="$(shell_quote "$DESKTOP_KEYWORDS")"
    q_website="$(shell_quote "$WEBSITE")"

    cat > "$installer_file" << INSTALLER_HEADER
#!/bin/bash
# ${APP_DISPLAY_NAME} Linux GUI Installer
# Self-extracting installer generated by Interactive GUI Installer Builder.

set -e

VERSION=$q_version
INSTALL_DIR=$q_install_dir
BINARY_NAME=$q_binary
APP_DISPLAY_NAME=$q_display
APP_SLUG=$q_slug
SYMLINK_NAME=$q_symlink
ICON_PAYLOAD_NAME=$q_icon_payload
ICON_INSTALL_NAME=$q_icon_install
APP_COMMENT=$q_comment
GENERIC_NAME=$q_generic
DESKTOP_CATEGORIES=$q_categories
DESKTOP_KEYWORDS=$q_keywords
WEBSITE=$q_website

echo "╔══════════════════════════════════════════════════╗"
echo "║        \${APP_DISPLAY_NAME} Installer"
echo "║        Version: \${VERSION}"
echo "╚══════════════════════════════════════════════════╝"
echo ""

if [ "\$EUID" -ne 0 ]; then
    echo "❌ This installer must be run as root."
    echo "Please run: sudo bash \$0"
    exit 1
fi

echo "📂 Installation directory: \$INSTALL_DIR"
echo ""
read -r -p "Continue installation? [Y/n] " -n 1 REPLY
echo
if [[ ! \$REPLY =~ ^[Yy]$ ]] && [[ -n \$REPLY ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo "[1/6] 📦 Extracting files..."
mkdir -p "\$INSTALL_DIR"
ARCHIVE_LINE=\$(awk '/^__ARCHIVE_BEGIN__/ {print NR + 1; exit 0; }' "\$0")
tail -n +\$ARCHIVE_LINE "\$0" | tar xzf - -C "\$INSTALL_DIR"

echo "[2/6] 🔐 Setting permissions..."
chmod +x "\$INSTALL_DIR/\$BINARY_NAME"
chown -R root:root "\$INSTALL_DIR"
chmod -R 755 "\$INSTALL_DIR"

echo "[3/6] 🎨 Installing icon..."
mkdir -p "/usr/share/pixmaps"
ICON_DESKTOP_LINE=""
if [ -n "\$ICON_PAYLOAD_NAME" ] && [ -f "\$INSTALL_DIR/\$ICON_PAYLOAD_NAME" ]; then
    cp "\$INSTALL_DIR/\$ICON_PAYLOAD_NAME" "/usr/share/pixmaps/\$ICON_INSTALL_NAME"
    chmod 644 "/usr/share/pixmaps/\$ICON_INSTALL_NAME"
    ICON_DESKTOP_LINE="Icon=/usr/share/pixmaps/\$ICON_INSTALL_NAME"
fi

echo "[4/6] 🔗 Creating terminal command..."
mkdir -p "/usr/local/bin"
ln -sf "\$INSTALL_DIR/\$BINARY_NAME" "/usr/local/bin/\$SYMLINK_NAME"

echo "[5/6] 🖥️  Creating desktop entry..."
DESKTOP_FILE="/usr/share/applications/\${APP_SLUG}.desktop"
cat > "\$DESKTOP_FILE" << DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=\${APP_DISPLAY_NAME}
GenericName=\${GENERIC_NAME}
Comment=\${APP_COMMENT}
Exec=/usr/local/bin/\${SYMLINK_NAME}
Terminal=false
Categories=\${DESKTOP_CATEGORIES}
StartupNotify=true
Keywords=\${DESKTOP_KEYWORDS}
DESKTOP_EOF

if [ -n "\$ICON_DESKTOP_LINE" ]; then
    echo "\$ICON_DESKTOP_LINE" >> "\$DESKTOP_FILE"
fi
chmod 644 "\$DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
fi

echo "[6/6] 🗑️  Creating uninstaller..."
cat > "\$INSTALL_DIR/uninstall.sh" << UNINSTALL_EOF
#!/bin/bash
set -e

if [ "\\\$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash \\\$0"
    exit 1
fi

echo "Uninstalling \$APP_DISPLAY_NAME..."
rm -rf "\$INSTALL_DIR"
rm -f "/usr/local/bin/\$SYMLINK_NAME"
rm -f "/usr/share/applications/\$APP_SLUG.desktop"
if [ -n "\$ICON_INSTALL_NAME" ]; then
    rm -f "/usr/share/pixmaps/\$ICON_INSTALL_NAME"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
fi

echo "\$APP_DISPLAY_NAME has been uninstalled."
UNINSTALL_EOF

chmod +x "\$INSTALL_DIR/uninstall.sh"

echo ""
echo "✅ Installation completed successfully!"
echo ""
echo "📖 How to run:"
echo "   • From terminal: \$SYMLINK_NAME"
echo "   • From applications menu: search for '\$APP_DISPLAY_NAME'"
echo ""
echo "🗑️  To uninstall: sudo bash \$INSTALL_DIR/uninstall.sh"
if [ -n "\$WEBSITE" ]; then
    echo "🌐 Website: \$WEBSITE"
fi
echo ""

exit 0

__ARCHIVE_BEGIN__
INSTALLER_HEADER

    echo "[3/4] 🔗 Appending payload archive..."
    cat "$archive_file" >> "$installer_file"
    chmod +x "$installer_file"

    echo "[4/4] ✅ Creating desktop launcher for the installer..."
    launcher_file="$OUTPUT_DIR/${APP_SLUG}-installer.desktop"
    cat > "$launcher_file" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Install $APP_DISPLAY_NAME
Comment=$APP_DISPLAY_NAME Installer
Exec=bash -c 'cd "\$(dirname "%k")" && pkexec env DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY bash ./${APP_SLUG}-${VERSION}-Linux-GUI.run'
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    chmod +x "$launcher_file"

    rm -rf "$temp_dir"

    success "Linux installer created: $installer_file"
    success "Linux installer launcher created: $launcher_file"
    echo ""
    echo "How to use:"
    echo "  sudo bash $(basename "$installer_file")"
    echo "  or double-click: $(basename "$launcher_file")"
}

# ═══════════════════════════════════════════════════
# macOS builder
# ═══════════════════════════════════════════════════

convert_png_to_icns() {
    local png_file="$1"
    local output_icns="$2"
    local iconset_dir

    require_cmd sips
    require_cmd iconutil

    iconset_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_SLUG}-icon.XXXXXX")/AppIcon.iconset"
    mkdir -p "$iconset_dir"

    sips -z 16 16     "$png_file" --out "$iconset_dir/icon_16x16.png" >/dev/null
    sips -z 32 32     "$png_file" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$png_file" --out "$iconset_dir/icon_32x32.png" >/dev/null
    sips -z 64 64     "$png_file" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$png_file" --out "$iconset_dir/icon_128x128.png" >/dev/null
    sips -z 256 256   "$png_file" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$png_file" --out "$iconset_dir/icon_256x256.png" >/dev/null
    sips -z 512 512   "$png_file" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$png_file" --out "$iconset_dir/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$png_file" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$iconset_dir" -o "$output_icns"
    rm -rf "$(dirname "$iconset_dir")"
}

build_macos_installers() {
    echo ""
    echo "════════════════════════════════════════════════"
    echo "🍎 Building macOS installers"
    echo "════════════════════════════════════════════════"
    echo ""

    [ "$HOST_PLATFORM" = "macOS" ] || error "macOS installers must be built on macOS."
    require_cmd pkgbuild
    require_cmd productbuild
    require_cmd hdiutil

    [ -d "$MACOS_BUILD_DIR" ] || error "macOS build folder not found: $MACOS_BUILD_DIR"
    [ -f "$MACOS_BUILD_DIR/$BINARY_NAME" ] || error "Binary not found: $MACOS_BUILD_DIR/$BINARY_NAME"

    local temp_dir app_dir pkg_root component_pkg final_pkg dmg_name temp_dmg mount_dir icon_name icon_ext readme_file
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_SLUG}-macos.XXXXXX")"
    app_dir="$temp_dir/$APP_BUNDLE_NAME"
    pkg_root="$temp_dir/pkg-root"

    echo "[1/5] 📦 Creating .app bundle..."
    mkdir -p "$app_dir/Contents/MacOS"
    mkdir -p "$app_dir/Contents/Resources"
    cp -a "$MACOS_BUILD_DIR/." "$app_dir/Contents/MacOS/"
    chmod +x "$app_dir/Contents/MacOS/$BINARY_NAME"

    icon_name=""
    if [ -n "$ICON_PATH" ] && [ -f "$ICON_PATH" ]; then
        icon_ext="$(lowercase "$(file_ext "$ICON_PATH")")"
        if [ "$icon_ext" = "icns" ]; then
            cp "$ICON_PATH" "$app_dir/Contents/Resources/AppIcon.icns"
            icon_name="AppIcon"
        elif [ "$icon_ext" = "png" ]; then
            convert_png_to_icns "$ICON_PATH" "$app_dir/Contents/Resources/AppIcon.icns"
            icon_name="AppIcon"
        else
            warn "macOS icon should be .icns or .png. Skipping icon: $ICON_PATH"
        fi
    fi

    local plist_display plist_binary plist_bundle_id plist_version plist_icon_key plist_icon_value
    plist_display="$(xml_escape "$APP_DISPLAY_NAME")"
    plist_binary="$(xml_escape "$BINARY_NAME")"
    plist_bundle_id="$(xml_escape "$MACOS_BUNDLE_ID")"
    plist_version="$(xml_escape "$VERSION")"
    plist_icon_key=""
    plist_icon_value=""
    if [ -n "$icon_name" ]; then
        plist_icon_key="    <key>CFBundleIconFile</key>"
        plist_icon_value="    <string>$icon_name</string>"
    fi

    cat > "$app_dir/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$plist_display</string>
    <key>CFBundleDisplayName</key>
    <string>$plist_display</string>
    <key>CFBundleExecutable</key>
    <string>$plist_binary</string>
    <key>CFBundleIdentifier</key>
    <string>$plist_bundle_id</string>
    <key>CFBundleShortVersionString</key>
    <string>$plist_version</string>
    <key>CFBundleVersion</key>
    <string>$plist_version</string>
$plist_icon_key
$plist_icon_value
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
</dict>
</plist>
PLIST_EOF

    if [ -n "$MACOS_SIGN_IDENTITY" ]; then
        require_cmd codesign
        echo "[2/5] ✍️  Signing app bundle..."
        codesign --deep --force --sign "$MACOS_SIGN_IDENTITY" "$app_dir"
    else
        echo "[2/5] ✍️  Signing skipped."
        warn "For public distribution, sign and notarize with Apple Developer ID."
    fi

    echo "[3/5] 📋 Creating PKG installer..."
    mkdir -p "$pkg_root/Applications"
    cp -R "$app_dir" "$pkg_root/Applications/"

    component_pkg="$temp_dir/${APP_SLUG}-component.pkg"
    final_pkg="$OUTPUT_DIR/${APP_SLUG}-${VERSION}-macOS-GUI.pkg"

    pkgbuild --root "$pkg_root" \
             --identifier "$MACOS_BUNDLE_ID" \
             --version "$VERSION" \
             --install-location "/" \
             "$component_pkg"

    productbuild --package "$component_pkg" "$final_pkg"

    echo "[4/5] 💿 Creating DMG..."
    dmg_name="$OUTPUT_DIR/${APP_SLUG}-${VERSION}-macOS.dmg"
    temp_dmg="$temp_dir/temp.dmg"
    mount_dir="$temp_dir/mount"
    mkdir -p "$mount_dir"

    hdiutil create -size "$MACOS_DMG_SIZE" -fs HFS+ -volname "$APP_SLUG" "$temp_dmg" >/dev/null
    hdiutil attach "$temp_dmg" -mountpoint "$mount_dir" -nobrowse -quiet
    cp -R "$app_dir" "$mount_dir/"
    ln -s /Applications "$mount_dir/Applications"

    readme_file="$mount_dir/README.txt"
    cat > "$readme_file" << README_EOF
$APP_DISPLAY_NAME
Version: $VERSION

Installation:
1. Drag $APP_BUNDLE_NAME to the Applications folder.
2. Open it from Launchpad or Applications.

README_EOF
    if [ -n "$WEBSITE" ]; then
        echo "Website: $WEBSITE" >> "$readme_file"
    fi

    hdiutil detach "$mount_dir" -quiet
    hdiutil convert "$temp_dmg" -format UDZO -o "$dmg_name" -quiet

    echo "[5/5] 🧹 Cleaning up..."
    rm -rf "$temp_dir"

    success "macOS PKG created: $final_pkg"
    success "macOS DMG created: $dmg_name"
}

# ═══════════════════════════════════════════════════
# Run selected builders
# ═══════════════════════════════════════════════════

if [ "$BUILD_LINUX" = true ]; then
    build_linux_installer
fi

if [ "$BUILD_MACOS" = true ]; then
    build_macos_installers
fi

echo ""
echo "════════════════════════════════════════════════"
echo "✨ Installer build completed"
echo "════════════════════════════════════════════════"
echo "📂 Output files: $OUTPUT_DIR"
echo ""
