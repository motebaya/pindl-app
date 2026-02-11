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
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./build_prod.sh --generatekeystore --clean --build-release --flavor lite"
    echo "  ./build_prod.sh --build-release --flavor ffmpeg"
    echo "  ./build_prod.sh --build-release --flavor ffmpeg --splitABI"
    echo "  ./build_prod.sh --build-release --flavor all --splitABI"
    echo "  ./build_prod.sh --clean"
    echo ""
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

    show_apk_info "$flavor_name" "$split"
}

show_apk_info() {
    local flavor_name="$1"
    local is_split="$2"
    local apk_dir="build/app/outputs/flutter-apk"

    if [ "$is_split" = "true" ]; then
        for abi in "${SUPPORTED_ABIS[@]}"; do
            local apk_path="$apk_dir/app-${flavor_name}-${abi}-release.apk"
            if [ -f "$apk_path" ]; then
                local apk_size
                apk_size=$(du -h "$apk_path" | cut -f1)
                echo -e "${CYAN}  $abi : $apk_path ($apk_size)${NC}"
            fi
        done
    else
        local apk_path="$apk_dir/app-${flavor_name}-release.apk"
        if [ -f "$apk_path" ]; then
            local apk_size
            apk_size=$(du -h "$apk_path" | cut -f1)
            echo -e "${CYAN}  $apk_path ($apk_size)${NC}"
        fi
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

    if [ "$FLAVOR" = "all" ]; then
        build_flavor "lite" "$SPLIT_ABI"
        build_flavor "ffmpeg" "$SPLIT_ABI"
        
        echo ""
        echo -e "${GREEN}Both flavors built:${NC}"

        echo ""
        echo -e "${YELLOW}  [lite]${NC}"
        show_apk_info "lite" "$SPLIT_ABI"
        echo ""
        echo -e "${YELLOW}  [ffmpeg]${NC}"
        show_apk_info "ffmpeg" "$SPLIT_ABI"
    else
        build_flavor "$FLAVOR" "$SPLIT_ABI"
    fi
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
