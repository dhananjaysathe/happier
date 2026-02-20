#!/usr/bin/env bash
#
# build-ios-sideload.sh — Build an unsigned Happier IPA on macOS
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhananjaysathe/happier/dev/tools/build-ios-sideload.sh \
#     -o /tmp/build.sh && chmod +x /tmp/build.sh && /tmp/build.sh
#
# Prerequisites: Xcode (full app, not just CLI tools) installed from the App Store.
# Everything else (Homebrew, Node, CocoaPods) is installed automatically.
#
set -euo pipefail

REPO_URL="https://github.com/dhananjaysathe/happier.git"
BRANCH="dev"
BUILD_DIR="$HOME/happier-ios-build"
SERVER_URL="https://happier.dsathe.pp.ua"
APP_ENV="production"
IPA_DEST="$HOME/Desktop/Happier.ipa"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

step() { printf "\n${BLUE}==>${NC} ${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}WARNING:${NC} %s\n" "$*"; }
die()  { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; exit 1; }

# ── Pre-flight checks ───────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This script must be run on macOS."

if ! xcode-select -p &>/dev/null; then
    die "Xcode is not installed. Please install it from the App Store first."
fi

# Verify it's the full Xcode, not just CLI tools
XCODE_PATH="$(xcode-select -p)"
if [[ "$XCODE_PATH" != *"Xcode.app"* ]]; then
    die "Full Xcode app is required (not just Command Line Tools).\n  Current path: $XCODE_PATH\n  Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

step "Pre-flight checks passed"

# ── Install Homebrew if needed ───────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    step "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

# ── Install Node.js if needed ────────────────────────────────────────────────
if ! command -v node &>/dev/null || [[ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 22 ]]; then
    step "Installing Node.js 22..."
    brew install node@22
    brew link --overwrite node@22 2>/dev/null || true
fi
echo "  Node $(node -v)"

# ── Enable Corepack (Yarn) ───────────────────────────────────────────────────
step "Enabling Corepack for Yarn..."
corepack enable 2>/dev/null || sudo corepack enable
corepack prepare yarn@1.22.22 --activate 2>/dev/null || true
echo "  Yarn $(yarn -v)"

# ── Install CocoaPods if needed ──────────────────────────────────────────────
if ! command -v pod &>/dev/null; then
    step "Installing CocoaPods..."
    brew install cocoapods
fi
echo "  CocoaPods $(pod --version)"

# ── Clone or update the repo ─────────────────────────────────────────────────
if [[ -d "$BUILD_DIR/.git" ]]; then
    step "Updating existing repo in $BUILD_DIR..."
    git -C "$BUILD_DIR" fetch origin "$BRANCH"
    git -C "$BUILD_DIR" checkout "$BRANCH"
    git -C "$BUILD_DIR" reset --hard "origin/$BRANCH"
else
    step "Cloning repo to $BUILD_DIR..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$BUILD_DIR"
fi

cd "$BUILD_DIR"

# ── Install JS dependencies ─────────────────────────────────────────────────
step "Installing dependencies (this may take a few minutes)..."
export YARN_PRODUCTION="false"
export npm_config_production="false"
export HAPPIER_INSTALL_SCOPE="ui,protocol,agents"
export HAPPIER_UI_VENDOR_WEB_ASSETS="0"
export HAPPIER_EMBEDDED_POLICY_ENV="$APP_ENV"
yarn install --frozen-lockfile --ignore-engines

# ── Expo prebuild ────────────────────────────────────────────────────────────
step "Running Expo prebuild for iOS..."
export APP_ENV="$APP_ENV"
export EXPO_PUBLIC_HAPPY_SERVER_URL="$SERVER_URL"
cd apps/ui
npx expo prebuild --platform ios --no-install
cd ios

# ── Detect Xcode scheme ─────────────────────────────────────────────────────
step "Detecting Xcode scheme..."
WORKSPACE="$(ls -d *.xcworkspace 2>/dev/null | head -1)"
if [[ -z "$WORKSPACE" ]]; then
    die "No .xcworkspace found in apps/ui/ios"
fi

SCHEME_LIST="$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null)"
SCHEME="$(echo "$SCHEME_LIST" | sed -n '/Schemes:/,/^$/{ /Schemes:/d; /^$/d; p; }' | head -1 | xargs)"
if [[ -z "$SCHEME" ]]; then
    die "Could not detect Xcode scheme"
fi
echo "  Workspace: $WORKSPACE"
echo "  Scheme:    $SCHEME"

# ── CocoaPods install ────────────────────────────────────────────────────────
step "Installing CocoaPods dependencies..."
pod install

# ── Build unsigned archive ───────────────────────────────────────────────────
ARCHIVE_PATH="$BUILD_DIR/build/Happier.xcarchive"

step "Building unsigned archive (this takes 15-20 minutes)..."
xcodebuild -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    | tail -1

# ── Package IPA ──────────────────────────────────────────────────────────────
step "Packaging IPA..."
PAYLOAD_DIR="$BUILD_DIR/build/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -r "$ARCHIVE_PATH/Products/Applications/"*.app "$PAYLOAD_DIR/"
cd "$BUILD_DIR/build"
zip -r -q Happier.ipa Payload

# ── Copy to Desktop ──────────────────────────────────────────────────────────
cp -f "$BUILD_DIR/build/Happier.ipa" "$IPA_DEST"

SIZE_MB=$(( $(wc -c < "$IPA_DEST" | tr -d '[:space:]') / 1024 / 1024 ))

step "Done!"
echo ""
printf "  ${GREEN}Happier.ipa${NC} saved to: ${BLUE}%s${NC}\n" "$IPA_DEST"
printf "  Size: %d MB\n" "$SIZE_MB"
echo ""
echo "  Send this file back and you're done!"
echo ""
echo "  To clean up:  rm -rf $BUILD_DIR $IPA_DEST"
echo ""
