#!/bin/bash

#######################################
# PinDL Production Build Script for Linux/macOS
# 
# Usage:
#   ./build_prod.sh --generatekeystore --clean --build-release
#   ./build_prod.sh --build-release
#   ./build_prod.sh --clean
#######################################

set -e

# Configuration
KEYSTORE_NAME="pindl-release.jks"
KEYSTORE_PATH="android/$KEYSTORE_NAME"
KEY_PROPERTIES_PATH="android/key.properties"
KEY_ALIAS="pindl"
VALIDITY_DAYS=10000

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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
    echo "  --help              Show this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./build_prod.sh --generatekeystore --clean --build-release"
    echo "  ./build_prod.sh --build-release"
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

build_release() {
    echo ""
    echo -e "${CYAN}Building Release APK...${NC}"
    
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
    flutter build apk --release
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to build release APK!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}Release APK built successfully!${NC}"
    echo -e "${CYAN}Location: build/app/outputs/flutter-apk/app-release.apk${NC}"
    
    # Show APK info
    apk_path="build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$apk_path" ]; then
        apk_size=$(du -h "$apk_path" | cut -f1)
        echo -e "${CYAN}APK Size: $apk_size${NC}"
    fi
}

# Parse arguments
GENERATE_KEYSTORE=false
CLEAN=false
BUILD_RELEASE=false

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
