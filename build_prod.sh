#!/bin/bash

#######################################
# PinDL Production Build Script for Linux/macOS
#
# Supports two build flavors:
#   lite   - Minimal build without FFmpeg (smaller APK, no HLS conversion)
#   ffmpeg - Full build with FFmpeg (HLS -> MP4 conversion support)
#
# Supports per-ABI split builds (--splitABI) for smaller APK sizes.
# Supported ABIs: armeabi-v7a, arm64-v8a, x86, x86_64
#
# Output: APKs are copied from build/app/outputs/flutter-apk into dist/ and
#   renamed to PinDL-<flavor>-<abi>-v<version>-b<build>.apk, and dist/build.md
#   is written with the build report (OS, host, toolchain, start/finish stamps
#   in the build timezone - Asia/Jakarta by default - total build time, and a
#   per-APK size/description table). If dist/ is not empty the script asks
#   overwrite or cancel BEFORE building. dist/ is gitignored (local artifacts).
#
# Usage:
#   ./build_prod.sh --generatekeystore --clean --build-release --flavor lite
#   ./build_prod.sh --build-release --flavor ffmpeg --splitABI
#   ./build_prod.sh --build-release --flavor all --splitABI
#   ./build_prod.sh --clean
#######################################

set -e

# Configuration
KEYSTORE_NAME="pindl-release.jks"
KEYSTORE_PATH="android/$KEYSTORE_NAME"
KEY_PROPERTIES_PATH="android/key.properties"
KEY_ALIAS="pindl"
VALIDITY_DAYS=10000

# Build output
#   FLUTTER_APK_DIR = where `flutter build apk` writes its APKs (source)
#   DIST_DIR        = where the script copies + renames the APKs and writes
#                     build.md, the build report.
FLUTTER_APK_DIR="build/app/outputs/flutter-apk"
DIST_DIR="dist"
# Timezone for the build report timestamps (local timezone; Asia/Jakarta by
# default). Override for a run with e.g. PINDL_BUILD_TZ=Asia/Jakarta.
BUILD_TIMEZONE="${PINDL_BUILD_TZ:-Asia/Jakarta}"

# Version + timing (filled in by read_app_version / build_release)
VERSION_BASE=""
VERSION_BUILD=""
VERSION_TAG=""
BUILD_START_EPOCH=0
BUILD_COMMAND=""

# Supported ABIs (ffmpeg_kit_flutter_new_https)
# arm-v7a, arm-v7a-neon, arm64-v8a, x86, x86_64
# Flutter uses Android NDK ABI names: armeabi-v7a, arm64-v8a, x86, x86_64
SUPPORTED_ABIS=("armeabi-v7a" "arm64-v8a" "x86" "x86_64")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

show_help() {
    echo ""
    echo -e "${CYAN}PinDL Production Build Script${NC}"
    echo -e "${CYAN}=============================${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC}"
    echo "  ./build_prod.sh [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --generatekeystore  Generate a new release keystore"
    echo "  --clean             Clean the Flutter project"
    echo "  --build-release     Build the release APK"
    echo "  --flavor <name>     Build flavor: lite, ffmpeg, or all (required with --build-release)"
    echo "  --splitABI          Split APK per ABI (armeabi-v7a, arm64-v8a, x86, x86_64)"
    echo "  --help              Show this help message"
    echo ""
    echo -e "${YELLOW}Flavors:${NC}"
    echo "  lite     Minimal build without FFmpeg (smaller APK, no HLS conversion)"
    echo "  ffmpeg   Full build with FFmpeg (HLS -> MP4 conversion support)"
    echo "  all      Build both lite and ffmpeg APKs"
    echo ""
    echo -e "${YELLOW}Output:${NC}"
    echo "  APKs are copied to dist/ as PinDL-<flavor>-<abi>-v<version>-b<build>.apk"
    echo "  and dist/build.md records the build report (OS, host, toolchain,"
    echo "  start/finish in the build timezone - Asia/Jakarta by default - total"
    echo "  build time, per-APK sizes and descriptions)."
    echo "  A non-empty dist/ asks overwrite / cancel first (or set"
    echo "  PINDL_DIST_ACTION=overwrite|cancel non-interactively)."
    echo "  dist/ is gitignored - local build artifacts only."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./build_prod.sh --generatekeystore --clean --build-release --flavor lite"
    echo "  ./build_prod.sh --build-release --flavor ffmpeg"
    echo "  ./build_prod.sh --build-release --flavor ffmpeg --splitABI"
    echo "  ./build_prod.sh --build-release --flavor all --splitABI"
    echo "  ./build_prod.sh --clean"
    echo ""
}

# Same derivation as CI: version: 3.1.1+8 -> base 3.1.1, build 8, tag v3.1.1-b8
read_app_version() {
    local raw
    raw=$(grep -E '^version:' pubspec.yaml | head -n 1 | awk '{print $2}' || true)
    if [ -z "$raw" ]; then
        echo -e "${RED}Error: no 'version:' line found in pubspec.yaml${NC}"
        exit 1
    fi
    VERSION_BASE="${raw%%+*}"
    VERSION_BUILD="${raw##*+}"
    if [ "$VERSION_BUILD" = "$raw" ]; then
        VERSION_BUILD="1"
    fi
    VERSION_TAG="v${VERSION_BASE}-b${VERSION_BUILD}"
}

# Resolve $BUILD_TIMEZONE into a TZ value the local date(1) can apply.
#   - Hosts with tzdata (Linux, macOS, Git Bash + tzdata): named zones work.
#   - Hosts without tzdata (typical Git Bash/MSYS): date collapses ANY named
#     zone to UTC - detected via an Asia/Tokyo probe (+0900, no DST ever).
#     Asia/Jakarta is fixed UTC+07:00, so the default still stamps correctly
#     through the POSIX TZ form; a custom zone falls back to the machine's
#     local clock and is labeled "local clock" instead of lying about it.
TZ_SPEC=""
TZ_LABEL=""
resolve_build_tz() {
    local probe
    probe=$(TZ=Asia/Tokyo date '+%z' 2>/dev/null || true)
    if [ "$probe" = "+0900" ]; then
        TZ_SPEC="$BUILD_TIMEZONE"
        TZ_LABEL="$BUILD_TIMEZONE"
        return
    fi
    if [ "$BUILD_TIMEZONE" = "Asia/Jakarta" ] && [ "$(TZ='<+07>-7' date '+%z' 2>/dev/null)" = "+0700" ]; then
        TZ_SPEC="<+07>-7"
        TZ_LABEL="$BUILD_TIMEZONE"
        return
    fi
    TZ_SPEC=""
    TZ_LABEL="local clock"
}

# e.g. 2026-10-13 00:41:12 +0700 (Asia/Jakarta)
build_timestamp() {
    if [ -n "$TZ_SPEC" ]; then
        TZ="$TZ_SPEC" date "+%Y-%m-%d %H:%M:%S %z ($TZ_LABEL)" 2>/dev/null || date "+%Y-%m-%d %H:%M:%S %z (local clock)"
    else
        date "+%Y-%m-%d %H:%M:%S %z ($TZ_LABEL)"
    fi
}

format_duration() {
    local total=$1
    if [ "$total" -ge 3600 ]; then
        printf '%dh %02dm %02ds' $((total / 3600)) $(((total % 3600) / 60)) $((total % 60))
    elif [ "$total" -ge 60 ]; then
        printf '%dm %02ds' $((total / 60)) $((total % 60))
    else
        printf '%ds' "$total"
    fi
}

# e.g. FFmpeg build - HLS -> MP4 conversion (full video support); 64-bit ARM (...)
apk_description() {
    local flavor="$1"
    local abi="$2"
    local flavor_desc abi_desc
    case "$flavor" in
        ffmpeg) flavor_desc="FFmpeg build - HLS -> MP4 conversion (full video support)" ;;
        lite) flavor_desc="Lite build - no FFmpeg; HLS-only videos are skipped with a reason" ;;
        *) flavor_desc="$flavor flavor" ;;
    esac
    case "$abi" in
        universal) abi_desc="all ABIs in one APK (largest, installs anywhere)" ;;
        arm64-v8a) abi_desc="64-bit ARM (most modern devices)" ;;
        armeabi-v7a) abi_desc="32-bit ARM (older / low-end devices)" ;;
        x86_64) abi_desc="64-bit x86 (emulators)" ;;
        x86) abi_desc="32-bit x86 (emulators)" ;;
        *) abi_desc="$abi" ;;
    esac
    printf '%s; %s' "$flavor_desc" "$abi_desc"
}

# dist/ holds the build output. If a previous build (or anything else) left
# content behind, the user chooses overwrite (dist/ is cleared) or cancel
# (nothing is built, dist/ untouched).
confirm_dist_output() {
    [ -d "$DIST_DIR" ] || return 0
    local count
    count=$(find "$DIST_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] || return 0

    local response="$PINDL_DIST_ACTION"
    if [ -z "$response" ]; then
        echo ""
        echo -e "${YELLOW}Output folder '$DIST_DIR/' is not empty ($count item(s) from a previous build).${NC}"
        read -p "Overwrite or cancel? [o]verwrite / [c]ancel: " response || response=""
    fi
    case "$response" in
        o|overwrite)
            find "$DIST_DIR" -mindepth 1 -delete
            echo -e "${YELLOW}Cleared '$DIST_DIR/' ($count item(s) removed).${NC}"
            ;;
        *)
            echo -e "${YELLOW}Cancelled - nothing was built, '$DIST_DIR/' left untouched.${NC}"
            exit 0
            ;;
    esac
}

copy_build_artifacts() {
    local flavor_name="$1"
    local split="$2"

    if [ ! -d "$FLUTTER_APK_DIR" ]; then
        echo -e "${RED}Error: flutter output folder not found: $FLUTTER_APK_DIR${NC}"
        exit 1
    fi
    mkdir -p "$DIST_DIR"

    local copied=0
    local src base abi
    if [ "$split" = "true" ]; then
        # Flutter split outputs are ABI-first: app-<abi>-<flavor>-release.apk
        local sources=()
        shopt -s nullglob
        sources=("$FLUTTER_APK_DIR/app-"*"-${flavor_name}-release.apk")
        shopt -u nullglob
        for src in "${sources[@]}"; do
            base=$(basename "$src")
            abi=${base#app-}
            abi=${abi%-${flavor_name}-release.apk}
            cp -f "$src" "$DIST_DIR/PinDL-${flavor_name}-${abi}-${VERSION_TAG}.apk"
            copied=$((copied + 1))
        done
    else
        src="$FLUTTER_APK_DIR/app-${flavor_name}-release.apk"
        if [ -f "$src" ]; then
            cp -f "$src" "$DIST_DIR/PinDL-${flavor_name}-universal-${VERSION_TAG}.apk"
            copied=$((copied + 1))
        fi
    fi

    if [ "$copied" -eq 0 ]; then
        echo -e "${RED}Error: no APK produced for flavor '$flavor_name' in $FLUTTER_APK_DIR${NC}"
        exit 1
    fi
    echo -e "${GREEN}  -> $copied APK(s) copied to $DIST_DIR/ as PinDL-${flavor_name}-...-${VERSION_TAG}.apk${NC}"
}

# dist/build.md - the build report (rewritten on every build run).
write_build_report() {
    local split="$1"
    local now_epoch duration
    now_epoch=$(date +%s)
    duration=$((now_epoch - BUILD_START_EPOCH))

    local abi_mode
    if [ "$split" = "true" ]; then
        abi_mode="split-per-abi (armeabi-v7a, arm64-v8a, x86, x86_64)"
    else
        abi_mode="universal (all ABIs in one APK)"
    fi

    local os_line=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        os_line=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || os_line=""
    fi
    if [ -z "$os_line" ]; then
        os_line=$(uname -srm)
    else
        os_line="$os_line ($(uname -srm))"
    fi

    local host_line
    host_line="$(hostname 2>/dev/null || echo unknown) - user ${USER:-$(whoami 2>/dev/null || echo unknown)}"

    local flutter_line=""
    flutter_line=$(flutter --version 2>/dev/null | head -n 1 || true)

    local git_line=""
    if command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
        git_line="$(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
    fi

    local report="$DIST_DIR/build.md"
    {
        echo "# PinDL build report"
        echo ""
        echo "> Generated by \`build_prod.sh\` - rewritten on every build run."
        echo "> \`dist/\` is gitignored: the APKs and this report are local build artifacts."
        echo ""
        echo "## Build details"
        echo ""
        echo "| Field | Value |"
        echo "|---|---|"
        echo "| Project | PinDL (\`pindl\`) |"
        echo "| Version | \`${VERSION_BASE}+${VERSION_BUILD}\` - tag \`${VERSION_TAG}\` |"
        echo "| Flavors | \`${FLAVOR}\` |"
        echo "| ABI mode | $abi_mode |"
        echo "| Build command | \`${BUILD_COMMAND}\` |"
        echo "| Build from OS | $os_line |"
        echo "| Host | $host_line |"
        echo "| Timezone | $TZ_LABEL (build timezone; default Asia/Jakarta, override with \`PINDL_BUILD_TZ\`) |"
        [ -n "$flutter_line" ] && echo "| Toolchain | $flutter_line |"
        [ -n "$git_line" ] && echo "| Source | \`$git_line\` |"
        echo "| Started | $BUILD_START_STAMP |"
        echo "| Finished | $(build_timestamp) |"
        echo "| Total build time | $(format_duration "$duration") |"
        echo ""
        echo "## APKs"
        echo ""
        echo "| APK | Flavor | ABI | Size | Description |"
        echo "|---|---|---|---|---|"

        local apk stem flavor_col abi_col bytes size_col desc found=0
        shopt -s nullglob
        for apk in "$DIST_DIR"/PinDL-*.apk; do
            shopt -u nullglob
            found=1
            stem=$(basename "$apk" .apk)
            flavor_col="-"
            abi_col="-"
            if [[ "$stem" =~ ^PinDL-([^-]+)-(.+)-v[0-9]+\.[0-9]+\.[0-9]+-b[0-9]+$ ]]; then
                flavor_col="${BASH_REMATCH[1]}"
                abi_col="${BASH_REMATCH[2]}"
            fi
            bytes=$(wc -c < "$apk" | tr -d ' ')
            size_col="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1000000 }') MB ($bytes B)"
            if [ "$flavor_col" = "-" ]; then
                desc="unrecognized name"
            else
                desc=$(apk_description "$flavor_col" "$abi_col")
            fi
            echo "| \`$stem.apk\` | $flavor_col | $abi_col | $size_col | $desc |"
            shopt -s nullglob
        done
        shopt -u nullglob
        [ "$found" -eq 0 ] && echo "| (no APKs found) | | | | |"

        echo ""
        echo "_Only APKs present in \`dist/\` at report time are listed. Sizes are on-disk decimal MB (bytes / 1,000,000)._"
        echo ""
    } > "$report"

    echo ""
    echo -e "${GREEN}Build report written: $DIST_DIR/build.md${NC}"
}

generate_keystore() {
    echo ""
    echo -e "${CYAN}Generating Release Keystore...${NC}"
    echo ""
    
    if [ -f "$KEYSTORE_PATH" ]; then
        echo -e "${YELLOW}Keystore already exists at: $KEYSTORE_PATH${NC}"
        read -p "Do you want to overwrite it? (y/N): " response
        if [[ "$response" != "y" && "$response" != "Y" ]]; then
            echo -e "${YELLOW}Skipping keystore generation.${NC}"
            return
        fi
        rm -f "$KEYSTORE_PATH"
    fi
    
    # Prompt for passwords
    read -sp "Enter keystore password (min 6 chars): " store_password
    echo ""
    read -sp "Enter key password (min 6 chars): " key_password
    echo ""
    
    # Prompt for certificate details
    read -p "Enter your name (CN): " cn
    read -p "Enter organizational unit (OU) [optional]: " ou
    read -p "Enter organization (O) [optional]: " o
    read -p "Enter city/locality (L) [optional]: " l
    read -p "Enter state/province (ST) [optional]: " st
    read -p "Enter country code (C, e.g., US): " c
    
    # Build dname
    dname="CN=$cn"
    [ -n "$ou" ] && dname+=", OU=$ou"
    [ -n "$o" ] && dname+=", O=$o"
    [ -n "$l" ] && dname+=", L=$l"
    [ -n "$st" ] && dname+=", ST=$st"
    [ -n "$c" ] && dname+=", C=$c"
    
    echo ""
    echo -e "${CYAN}Generating keystore with keytool...${NC}"
    
    keytool -genkey -v \
        -keystore "$KEYSTORE_PATH" \
        -alias "$KEY_ALIAS" \
        -keyalg RSA \
        -keysize 2048 \
        -validity "$VALIDITY_DAYS" \
        -storepass "$store_password" \
        -keypass "$key_password" \
        -dname "$dname"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to generate keystore!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}Keystore generated successfully: $KEYSTORE_PATH${NC}"
    
    # Create key.properties
    echo -e "${CYAN}Creating key.properties...${NC}"
    
    cat > "$KEY_PROPERTIES_PATH" << EOF
storePassword=$store_password
keyPassword=$key_password
keyAlias=$KEY_ALIAS
storeFile=../$KEYSTORE_NAME
EOF
    
    echo -e "${GREEN}key.properties created successfully!${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Keep your keystore and passwords safe!${NC}"
    echo -e "${YELLOW}Add key.properties and *.jks to .gitignore!${NC}"
}

clean_project() {
    echo ""
    echo -e "${CYAN}Cleaning Flutter project...${NC}"
    
    flutter clean
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to clean project!${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}Getting dependencies...${NC}"
    flutter pub get
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to get dependencies!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Project cleaned successfully!${NC}"
}

build_flavor() {
    local flavor_name="$1"
    local split="$2"

    # Determine ENABLE_FFMPEG value based on flavor
    local enable_ffmpeg="false"
    if [ "$flavor_name" = "ffmpeg" ]; then
        enable_ffmpeg="true"
    fi

    echo ""
    echo -e "${CYAN}Building Release APK [$flavor_name]...${NC}"
    echo -e "${GRAY}  Flavor:        $flavor_name${NC}"
    echo -e "${GRAY}  ENABLE_FFMPEG: $enable_ffmpeg${NC}"
    echo -e "${GRAY}  Split ABI:     $split${NC}"
    
    # Check if key.properties exists
    if [ ! -f "$KEY_PROPERTIES_PATH" ]; then
        echo -e "${YELLOW}Warning: key.properties not found!${NC}"
        echo -e "${YELLOW}Building with debug signing config...${NC}"
    else
        echo -e "${GREEN}Using release signing config from key.properties${NC}"
    fi
    
    cd android
    ./gradlew --stop
    cd ..

    local flutter_args=("build" "apk" "--flavor" "$flavor_name" "--dart-define=ENABLE_FFMPEG=$enable_ffmpeg" "--release")
    if [ "$split" = "true" ]; then
        flutter_args+=("--split-per-abi")
    fi

    flutter "${flutter_args[@]}"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to build release APK [$flavor_name]!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}Release APK [$flavor_name] built successfully!${NC}"

    copy_build_artifacts "$flavor_name" "$split"
    show_apk_info "$flavor_name"
}

show_apk_info() {
    local flavor_name="$1"
    # Release APKs live in dist/ (copied + renamed by copy_build_artifacts).
    local apk_dir="$DIST_DIR"

    local found=0 apk bytes mb
    shopt -s nullglob
    for apk in "$apk_dir"/PinDL-"$flavor_name"-*.apk; do
        shopt -u nullglob
        found=1
        bytes=$(wc -c < "$apk" | tr -d ' ')
        mb=$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1000000 }')
        echo -e "${CYAN}  $apk_dir/$(basename "$apk") ($mb MB, $bytes B)${NC}"
        shopt -s nullglob
    done
    shopt -u nullglob
    if [ "$found" -eq 0 ]; then
        echo -e "${GRAY}  (no PinDL-$flavor_name-*.apk in $apk_dir/)${NC}"
    fi
}

build_release() {
    if [ -z "$FLAVOR" ]; then
        echo ""
        echo -e "${RED}Error: --flavor is required with --build-release${NC}"
        echo -e "${YELLOW}  Use: --flavor lite, --flavor ffmpeg, or --flavor all${NC}"
        echo ""
        exit 1
    fi

    # Validate flavor value
    if [[ "$FLAVOR" != "lite" && "$FLAVOR" != "ffmpeg" && "$FLAVOR" != "all" ]]; then
        echo -e "${RED}Error: Invalid flavor '$FLAVOR'. Must be: lite, ffmpeg, or all${NC}"
        exit 1
    fi

    read_app_version
    resolve_build_tz
    BUILD_START_EPOCH=$(date +%s)
    BUILD_START_STAMP=$(build_timestamp)

    if [ "$FLAVOR" = "all" ]; then
        build_flavor "lite" "$SPLIT_ABI"
        build_flavor "ffmpeg" "$SPLIT_ABI"
        
        echo ""
        echo -e "${GREEN}Both flavors built:${NC}"

        echo ""
        echo -e "${YELLOW}  [lite]${NC}"
        show_apk_info "lite"
        echo ""
        echo -e "${YELLOW}  [ffmpeg]${NC}"
        show_apk_info "ffmpeg"
    else
        build_flavor "$FLAVOR" "$SPLIT_ABI"
    fi

    write_build_report "$SPLIT_ABI"
}

# Parse arguments
GENERATE_KEYSTORE=false
CLEAN=false
BUILD_RELEASE=false
FLAVOR=""
SPLIT_ABI=false

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --generatekeystore)
            GENERATE_KEYSTORE=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --build-release)
            BUILD_RELEASE=true
            shift
            ;;
        --flavor)
            if [ -z "$2" ] || [[ "$2" == --* ]]; then
                echo -e "${RED}Error: --flavor requires a value (lite, ffmpeg, or all)${NC}"
                exit 1
            fi
            FLAVOR="$2"
            shift 2
            ;;
        --splitABI)
            SPLIT_ABI=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
echo ""
echo -e "${MAGENTA}==========================================${NC}"
echo -e "${MAGENTA}   PinDL Production Build Script${NC}"
echo -e "${MAGENTA}==========================================${NC}"

BUILD_COMMAND="./build_prod.sh"
[ "$GENERATE_KEYSTORE" = true ] && BUILD_COMMAND+=" --generatekeystore"
[ "$CLEAN" = true ] && BUILD_COMMAND+=" --clean"
[ "$BUILD_RELEASE" = true ] && BUILD_COMMAND+=" --build-release"
[ -n "$FLAVOR" ] && BUILD_COMMAND+=" --flavor $FLAVOR"
[ "$SPLIT_ABI" = true ] && BUILD_COMMAND+=" --splitABI"

if [ "$BUILD_RELEASE" = true ]; then
    # Validate flavor and settle the dist/ overwrite/cancel question BEFORE any
    # (potentially long) clean/build work starts.
    if [ -z "$FLAVOR" ]; then
        echo ""
        echo -e "${RED}Error: --flavor is required with --build-release${NC}"
        echo -e "${YELLOW}  Use: --flavor lite, --flavor ffmpeg, or --flavor all${NC}"
        echo ""
        exit 1
    fi
    if [[ "$FLAVOR" != "lite" && "$FLAVOR" != "ffmpeg" && "$FLAVOR" != "all" ]]; then
        echo -e "${RED}Error: Invalid flavor '$FLAVOR'. Must be: lite, ffmpeg, or all${NC}"
        exit 1
    fi
    confirm_dist_output
fi

if [ "$GENERATE_KEYSTORE" = true ]; then
    generate_keystore
fi

if [ "$CLEAN" = true ]; then
    clean_project
fi

if [ "$BUILD_RELEASE" = true ]; then
    build_release
fi

echo ""
echo -e "${GREEN}All tasks completed!${NC}"
echo ""
