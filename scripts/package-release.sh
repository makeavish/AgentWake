#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentWake"
BUNDLE_ID="com.makeavish.AgentWake"
MIN_SYSTEM_VERSION="13.0"
HOOK_ADAPTER_NAME="AgentWakeHookAdapter"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/release-artifacts"
VERSION=""
SIGN_MODE="ad-hoc"
ALLOW_DIRTY=false

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh --version VERSION [--output-dir DIR] [--no-sign] [--allow-dirty]

Builds a release AgentWake.app bundle and ZIP artifact.

VERSION may be v0.1.0 or 0.1.0. The app bundle version uses the numeric form.
The release artifact does not install or register privileged helpers.
EOF
}

require_clean_dir_target() {
    local path="$1"
    if [[ -L "$path" ]]; then
        echo "Output directory must not be a symlink: $path" >&2
        exit 2
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
        echo "Output path exists and is not a directory: $path" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --no-sign)
            SIGN_MODE="none"
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "--version is required" >&2
    usage >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^v?[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "Version must look like v0.1.0 or 0.1.0: $VERSION" >&2
    exit 2
fi

SHORT_VERSION="${VERSION#v}"
TAG_VERSION="v$SHORT_VERSION"
if [[ "$ALLOW_DIRTY" != true && -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    echo "Refusing to package from a dirty working tree. Commit changes first, or pass --allow-dirty for local smoke artifacts only." >&2
    exit 2
fi
BUILD_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || date -u +%Y%m%d%H%M)"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_SHORT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

require_clean_dir_target "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

ARTIFACT_ROOT="$OUTPUT_DIR/$APP_NAME-$TAG_VERSION"
APP_BUNDLE="$ARTIFACT_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
HOOK_ADAPTER_BINARY="$APP_MACOS/$HOOK_ADAPTER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$TAG_VERSION-macos.zip"
SHA_PATH="$ZIP_PATH.sha256"
MANIFEST_PATH="$OUTPUT_DIR/$APP_NAME-$TAG_VERSION-manifest.txt"

if [[ -e "$ARTIFACT_ROOT" || -e "$ZIP_PATH" || -e "$SHA_PATH" || -e "$MANIFEST_PATH" ]]; then
    echo "Release artifact already exists for $TAG_VERSION in $OUTPUT_DIR" >&2
    exit 2
fi

cd "$ROOT_DIR"

swift build -c release --product "$APP_NAME"
swift build -c release --product "$HOOK_ADAPTER_NAME"
BUILD_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/$HOOK_ADAPTER_NAME" "$HOOK_ADAPTER_BINARY"
chmod +x "$APP_BINARY" "$HOOK_ADAPTER_BINARY"
cp "$ROOT_DIR/README.md" "$APP_RESOURCES/README.md"
cp "$ROOT_DIR/CHANGELOG.md" "$APP_RESOURCES/CHANGELOG.md"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

if [[ "$SIGN_MODE" == "ad-hoc" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_BINARY" >/dev/null
    /usr/bin/codesign --force --sign - --timestamp=none "$HOOK_ADAPTER_BINARY" >/dev/null
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
    /usr/bin/codesign --verify --strict "$APP_BUNDLE" >/dev/null
fi

(
    cd "$ARTIFACT_ROOT"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

/usr/bin/shasum -a 256 "$ZIP_PATH" >"$SHA_PATH"

cat >"$MANIFEST_PATH" <<EOF
artifactFormat=agentwake-release-artifact-v1
appName=$APP_NAME
bundleIdentifier=$BUNDLE_ID
version=$TAG_VERSION
shortVersion=$SHORT_VERSION
buildVersion=$BUILD_VERSION
gitCommit=$GIT_COMMIT
gitShortCommit=$GIT_SHORT_COMMIT
signing=$SIGN_MODE
dirtyTree=$ALLOW_DIRTY
bagMode=unavailable
helperInstalled=false
zipPath=$ZIP_PATH
sha256Path=$SHA_PATH
appBundle=$APP_BUNDLE
EOF

printf 'Release artifact written:\n'
printf '  app: %s\n' "$APP_BUNDLE"
printf '  zip: %s\n' "$ZIP_PATH"
printf '  sha256: %s\n' "$SHA_PATH"
printf '  manifest: %s\n' "$MANIFEST_PATH"
