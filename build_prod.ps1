<#
.SYNOPSIS
    PinDL Production Build Script for Windows
.DESCRIPTION
    This script builds the PinDL Flutter app for production/release.
    It can generate keystores, clean the project, and build release APKs.
    Supports two build flavors: lite (no FFmpeg) and ffmpeg (full HLS support).
    Supports per-ABI split builds for smaller APK sizes.
.EXAMPLE
    .\build_prod.ps1 -GenerateKeyStore -Clean -BuildRelease -Flavor lite
    .\build_prod.ps1 -BuildRelease -Flavor ffmpeg
    .\build_prod.ps1 -BuildRelease -Flavor ffmpeg -SplitABI
    .\build_prod.ps1 -BuildRelease -Flavor all -SplitABI
    .\build_prod.ps1 -Clean
#>

param(
    [switch]$GenerateKeyStore,
    [switch]$Clean,
    [switch]$BuildRelease,
    [ValidateSet("lite", "ffmpeg", "all")]
    [string]$Flavor,
    [switch]$SplitABI,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# Configuration
$KEYSTORE_NAME = "pindl-release.jks"
$KEYSTORE_PATH = "android/$KEYSTORE_NAME"
$KEY_PROPERTIES_PATH = "android/key.properties"
$KEY_ALIAS = "pindl"
$VALIDITY_DAYS = 10000

# Supported ABIs (ffmpeg_kit_flutter_new_https)
# arm-v7a, arm-v7a-neon, arm64-v8a, x86, x86_64
# Flutter uses Android NDK ABI names: armeabi-v7a, arm64-v8a, x86, x86_64
$SUPPORTED_ABIS = @("armeabi-v7a", "arm64-v8a", "x86", "x86_64")

function Show-Help {
    Write-Host ""
    Write-Host "PinDL Production Build Script" -ForegroundColor Yellow
    Write-Host "    @github.com/motebaya" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\build_prod.ps1 [options]"
    Write-Host ""
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  -GenerateKeyStore  Generate a new release keystore"
    Write-Host "  -Clean             Clean the Flutter project"
    Write-Host "  -BuildRelease      Build the release APK"
    Write-Host "  -Flavor <name>     Build flavor: lite, ffmpeg, or all (required with -BuildRelease)"
    Write-Host "  -SplitABI          Split APK per ABI (armeabi-v7a, arm64-v8a, x86, x86_64)"
    Write-Host "  -Help              Show this help message"
    Write-Host ""
    Write-Host "Flavors:" -ForegroundColor Yellow
    Write-Host "  lite     Minimal build without FFmpeg (smaller APK, no HLS conversion)"
    Write-Host "  ffmpeg   Full build with FFmpeg (HLS -> MP4 conversion support)"
    Write-Host "  all      Build both lite and ffmpeg APKs"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\build_prod.ps1 -GenerateKeyStore -Clean -BuildRelease -Flavor lite"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor ffmpeg"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor ffmpeg -SplitABI"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor all -SplitABI"
    Write-Host "  .\build_prod.ps1 -Clean"
    Write-Host ""
}

function Generate-KeyStore {
    Write-Host ""
    Write-Host "Generating Release Keystore..." -ForegroundColor Cyan
    Write-Host ""
    
    if (Test-Path $KEYSTORE_PATH) {
        Write-Host "Keystore already exists at: $KEYSTORE_PATH" -ForegroundColor Yellow
        $response = Read-Host "Do you want to overwrite it? (y/N)"
        if ($response -ne "y" -and $response -ne "Y") {
            Write-Host "Skipping keystore generation." -ForegroundColor Yellow
            return
        }
        Remove-Item $KEYSTORE_PATH -Force
    }
    
    # Prompt for passwords
    $storePassword = Read-Host "Enter keystore password (min 6 chars)" -AsSecureString
    $keyPassword = Read-Host "Enter key password (min 6 chars)" -AsSecureString
    
    # Convert secure strings to plain text
    $storePwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($storePassword))
    $keyPwd = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($keyPassword))
    
    # Prompt for certificate details
    $cn = Read-Host "Enter your name (CN)"
    $ou = Read-Host "Enter organizational unit (OU) [optional]"
    $o = Read-Host "Enter organization (O) [optional]"
    $l = Read-Host "Enter city/locality (L) [optional]"
    $st = Read-Host "Enter state/province (ST) [optional]"
    $c = Read-Host "Enter country code (C, e.g., US)"
    
    # Build dname
    $dname = "CN=$cn"
    if ($ou) { $dname += ", OU=$ou" }
    if ($o) { $dname += ", O=$o" }
    if ($l) { $dname += ", L=$l" }
    if ($st) { $dname += ", ST=$st" }
    if ($c) { $dname += ", C=$c" }
    
    Write-Host ""
    Write-Host "Generating keystore with keytool..." -ForegroundColor Cyan
    
    $keytoolArgs = @(
        "-genkey",
        "-v",
        "-keystore", $KEYSTORE_PATH,
        "-alias", $KEY_ALIAS,
        "-keyalg", "RSA",
        "-keysize", "2048",
        "-validity", $VALIDITY_DAYS,
        "-storepass", $storePwd,
        "-keypass", $keyPwd,
        "-dname", $dname
    )
    
    & keytool @keytoolArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to generate keystore!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Keystore generated successfully: $KEYSTORE_PATH" -ForegroundColor Green
    
    # Create key.properties
    Write-Host "Creating key.properties..." -ForegroundColor Cyan
    
    $keyPropertiesContent = @"
storePassword=$storePwd
keyPassword=$keyPwd
keyAlias=$KEY_ALIAS
storeFile=../$KEYSTORE_NAME
"@
    
    Set-Content -Path $KEY_PROPERTIES_PATH -Value $keyPropertiesContent
    
    Write-Host "key.properties created successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT: Keep your keystore and passwords safe!" -ForegroundColor Yellow
    Write-Host "Add key.properties and *.jks to .gitignore!" -ForegroundColor Yellow
}

function Clean-Project {
    Write-Host ""
    Write-Host "Cleaning Flutter project..." -ForegroundColor Cyan
    
    flutter clean
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to clean project!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Getting dependencies..." -ForegroundColor Cyan
    flutter pub get
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to get dependencies!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Project cleaned successfully!" -ForegroundColor Green
}

function Build-Flavor {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("lite", "ffmpeg")]
        [string]$FlavorName,
        [bool]$Split = $false
    )

    # Determine ENABLE_FFMPEG value based on flavor
    if ($FlavorName -eq "ffmpeg") {
        $enableFfmpeg = "true"
    } else {
        $enableFfmpeg = "false"
    }

    Write-Host ""
    Write-Host "Building Release APK [$FlavorName]..." -ForegroundColor Cyan
    Write-Host "  Flavor:        $FlavorName" -ForegroundColor DarkGray
    Write-Host "  ENABLE_FFMPEG: $enableFfmpeg" -ForegroundColor DarkGray
    Write-Host "  Split ABI:     $Split" -ForegroundColor DarkGray
    
    # Check if key.properties exists
    if (-not (Test-Path $KEY_PROPERTIES_PATH)) {
        Write-Host "Warning: key.properties not found!" -ForegroundColor Yellow
        Write-Host "Building with debug signing config..." -ForegroundColor Yellow
    } else {
        Write-Host "Using release signing config from key.properties" -ForegroundColor Green
    }
    
    cd android
    ./gradlew --stop
    cd ..

    $flutterArgs = @(
        "build", "apk",
        "--flavor", $FlavorName,
        "--dart-define=ENABLE_FFMPEG=$enableFfmpeg",
        "--release"
    )
    if ($Split) {
        $flutterArgs += "--split-per-abi"
    }

    & flutter @flutterArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to build release APK [$FlavorName]!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Release APK [$FlavorName] built successfully!" -ForegroundColor Green

    Show-ApkInfo -FlavorName $FlavorName -IsSplit $Split
}

function Show-ApkInfo {
    param(
        [string]$FlavorName,
        [bool]$IsSplit
    )

    $apkDir = "build\app\outputs\flutter-apk"

    if ($IsSplit) {
        foreach ($abi in $SUPPORTED_ABIS) {
            $apkPath = "$apkDir\app-$FlavorName-$abi-release.apk"
            if (Test-Path $apkPath) {
                $apkSize = [math]::Round((Get-Item $apkPath).Length / 1MB, 2)
                Write-Host "  $abi : $apkPath ($apkSize MB)" -ForegroundColor Cyan
            }
        }
    } else {
        $apkPath = "$apkDir\app-$FlavorName-release.apk"
        if (Test-Path $apkPath) {
            $apkSize = [math]::Round((Get-Item $apkPath).Length / 1MB, 2)
            Write-Host "  $apkPath ($apkSize MB)" -ForegroundColor Cyan
        }
    }
}

function Build-Release {
    if (-not $Flavor) {
        Write-Host ""
        Write-Host "Error: -Flavor is required with -BuildRelease" -ForegroundColor Red
        Write-Host "  Use: -Flavor lite, -Flavor ffmpeg, or -Flavor all" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    $doSplit = [bool]$SplitABI

    if ($Flavor -eq "all") {
        Build-Flavor -FlavorName "lite" -Split $doSplit
        Build-Flavor -FlavorName "ffmpeg" -Split $doSplit
        
        Write-Host ""
        Write-Host "Both flavors built:" -ForegroundColor Green
        Write-Host ""
        Write-Host "  [lite]" -ForegroundColor Yellow
        Show-ApkInfo -FlavorName "lite" -IsSplit $doSplit
        Write-Host ""
        Write-Host "  [ffmpeg]" -ForegroundColor Yellow
        Show-ApkInfo -FlavorName "ffmpeg" -IsSplit $doSplit
    } else {
        Build-Flavor -FlavorName $Flavor -Split $doSplit
    }
}

# Main execution
if ($Help) {
    Show-Help
    exit 0
}

if (-not $GenerateKeyStore -and -not $Clean -and -not $BuildRelease) {
    Show-Help
    exit 0
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Magenta
Write-Host "   PinDL Production Build Script" -ForegroundColor Magenta
Write-Host "==========================================" -ForegroundColor Magenta

if ($GenerateKeyStore) {
    Generate-KeyStore
}

if ($Clean) {
    Clean-Project
}

if ($BuildRelease) {
    Build-Release
}

Write-Host ""
Write-Host "All tasks completed!" -ForegroundColor Green
Write-Host ""
cd android
./gradlew --stop
cd ..
