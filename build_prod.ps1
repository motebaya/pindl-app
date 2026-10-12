<#
.SYNOPSIS
    PinDL Production Build Script for Windows
.DESCRIPTION
    This script builds the PinDL Flutter app for production/release.
    It can generate keystores, clean the project, and build release APKs.
    Supports two build flavors: lite (no FFmpeg) and ffmpeg (full HLS support).
    Supports per-ABI split builds for smaller APK sizes.

    Output: APKs are copied from build\app\outputs\flutter-apk into dist\ and
    renamed to PinDL-<flavor>-<abi>-v<version>-b<build>.apk, and dist\build.md
    is written with the build report (OS, host, toolchain, start/finish stamps
    in the build timezone - Asia/Jakarta by default - total build time, and a
    per-APK size/description table). If dist\ is not empty the script asks
    overwrite or cancel BEFORE building. dist\ is gitignored (local artifacts).
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

# Build output
#   $FLUTTER_APK_DIR = where `flutter build apk` writes its APKs (source)
#   $apkDir (Show-ApkInfo) = "dist" — the script copies + renames APKs there
#     and writes dist\build.md, the build report.
$FLUTTER_APK_DIR = "build\app\outputs\flutter-apk"
$DIST_DIR = "dist"
# Timezone for the build report timestamps (local timezone; Asia/Jakarta by
# default). Override for a run with e.g. $env:PINDL_BUILD_TZ = "Asia/Jakarta".
$BUILD_TIMEZONE = if ($env:PINDL_BUILD_TZ) { $env:PINDL_BUILD_TZ } else { "Asia/Jakarta" }

# Version + timing filled in by Read-AppVersion / Build-Release.
$script:VersionBase = $null
$script:VersionBuild = $null
$script:VersionTag = $null
$script:BuildStart = $null
$script:BuildCommand = $null

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
    Write-Host "Output:" -ForegroundColor Yellow
    Write-Host "  APKs are copied to dist\ as PinDL-<flavor>-<abi>-v<version>-b<build>.apk"
    Write-Host "  and dist\build.md records the build report (OS, host, toolchain,"
    Write-Host "  start/finish in the build timezone - Asia/Jakarta by default - total"
    Write-Host "  build time, per-APK sizes and descriptions)."
    Write-Host "  A non-empty dist\ asks overwrite / cancel first (or set"
    Write-Host "  `$env:PINDL_DIST_ACTION = 'overwrite'|'cancel' non-interactively)."
    Write-Host "  dist\ is gitignored - local build artifacts only."
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\build_prod.ps1 -GenerateKeyStore -Clean -BuildRelease -Flavor lite"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor ffmpeg"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor ffmpeg -SplitABI"
    Write-Host "  .\build_prod.ps1 -BuildRelease -Flavor all -SplitABI"
    Write-Host "  .\build_prod.ps1 -Clean"
    Write-Host ""
}

function Read-AppVersion {
    # Same derivation as CI: version: 3.1.1+8 -> base 3.1.1, build 8, tag v3.1.1-b8
    $line = Get-Content pubspec.yaml -ErrorAction Stop |
        Where-Object { $_ -match '^version:\s*\S' } |
        Select-Object -First 1
    if (-not $line) {
        Write-Host "Error: no 'version:' line found in pubspec.yaml" -ForegroundColor Red
        exit 1
    }
    $raw = ($line -replace '^version:\s*', '').Trim()
    $parts = $raw -split '\+'
    $script:VersionBase = $parts[0]
    $script:VersionBuild = if ($parts.Count -gt 1) { $parts[1] } else { '1' }
    $script:VersionTag = "v$($script:VersionBase)-b$($script:VersionBuild)"
}

function Resolve-BuildTimeZone {
    # Report timezone resolution: the configured IANA id (Asia/Jakarta by
    # default) resolves directly on PowerShell 7+ / .NET 6+; Windows PowerShell
    # 5.1 needs the Windows id for the same UTC+07:00 zone. If neither matches,
    # fall back to the machine's local zone and label it honestly.
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($BUILD_TIMEZONE)
        return [pscustomobject]@{ Tz = $tz; Label = $BUILD_TIMEZONE }
    } catch { }
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("SE Asia Standard Time")
        if ($tz.BaseUtcOffset -eq [TimeSpan]::FromHours(7)) {
            return [pscustomobject]@{ Tz = $tz; Label = $BUILD_TIMEZONE }
        }
    } catch { }
    $local = [System.TimeZoneInfo]::Local
    return [pscustomobject]@{ Tz = $local; Label = $local.Id }
}

function Format-BuildStamp {
    param([DateTime]$When)
    # e.g. 2026-10-13 00:41:12 +07:00 (Asia/Jakarta)
    $zone = Resolve-BuildTimeZone
    $utc = [DateTimeOffset]::new($When.ToUniversalTime(), [TimeSpan]::Zero)
    $local = $utc.ToOffset($zone.Tz.BaseUtcOffset)
    return "$($local.ToString('yyyy-MM-dd HH:mm:ss')) $($local.ToString('zzz')) ($($zone.Label))"
}

function Format-BuildDuration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return ("{0}h {1:00}m {2:00}s" -f [int][math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds)
    }
    if ($Duration.TotalMinutes -ge 1) {
        return ("{0}m {1:00}s" -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds)
    }
    return ("{0}s" -f [int][math]::Round($Duration.TotalSeconds))
}

function Get-ApkDescription {
    param([string]$FlavorName, [string]$Abi)
    $flavorDesc = switch ($FlavorName) {
        'ffmpeg' { 'FFmpeg build - HLS -> MP4 conversion (full video support)' }
        'lite' { 'Lite build - no FFmpeg; HLS-only videos are skipped with a reason' }
        default { "$FlavorName flavor" }
    }
    $abiDesc = switch ($Abi) {
        'universal' { 'all ABIs in one APK (largest, installs anywhere)' }
        'arm64-v8a' { '64-bit ARM (most modern devices)' }
        'armeabi-v7a' { '32-bit ARM (older / low-end devices)' }
        'x86_64' { '64-bit x86 (emulators)' }
        'x86' { '32-bit x86 (emulators)' }
        default { $Abi }
    }
    return "$flavorDesc; $abiDesc"
}

function Confirm-DistOutput {
    # dist\ holds the build output. If a previous build (or anything else) left
    # content behind, the user chooses overwrite (dist\ is cleared) or cancel
    # (nothing is built, dist\ untouched).
    if (-not (Test-Path $DIST_DIR)) { return }
    $existing = @(Get-ChildItem -Path $DIST_DIR -Force)
    if ($existing.Count -eq 0) { return }

    $response = $env:PINDL_DIST_ACTION
    if (-not $response) {
        Write-Host ""
        Write-Host "Output folder '$DIST_DIR\' is not empty ($($existing.Count) item(s) from a previous build)." -ForegroundColor Yellow
        $response = Read-Host "Overwrite or cancel? [o]verwrite / [c]ancel"
    }
    if ($response -match '^(o|overwrite)$') {
        foreach ($item in $existing) { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
        Write-Host "Cleared '$DIST_DIR\' ($($existing.Count) item(s) removed)." -ForegroundColor Yellow
    } else {
        Write-Host "Cancelled - nothing was built, '$DIST_DIR\' left untouched." -ForegroundColor Yellow
        exit 0
    }
}

function Copy-BuildArtifacts {
    param(
        [Parameter(Mandatory)]
        [string]$FlavorName,
        [bool]$Split = $false
    )

    if (-not (Test-Path $FLUTTER_APK_DIR)) {
        Write-Host "Error: flutter output folder not found: $FLUTTER_APK_DIR" -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $DIST_DIR | Out-Null

    $copied = 0
    if ($Split) {
        # Flutter split outputs are ABI-first: app-<abi>-<flavor>-release.apk
        $sources = @(Get-ChildItem -Path $FLUTTER_APK_DIR -Filter "app-*-$FlavorName-release.apk" -File)
        foreach ($apk in $sources) {
            # Guard: never pick up the .apk.sha1 sidecar files (Win32 filter quirks)
            if (-not $apk.Name.EndsWith('.apk')) { continue }
            $abi = $apk.Name.Substring(
                "app-".Length,
                $apk.Name.Length - "app-".Length - "-$FlavorName-release.apk".Length
            )
            Copy-Item $apk.FullName (Join-Path $DIST_DIR "PinDL-$FlavorName-$abi-$($script:VersionTag).apk") -Force
            $copied++
        }
    } else {
        $source = Join-Path $FLUTTER_APK_DIR "app-$FlavorName-release.apk"
        if (Test-Path $source) {
            Copy-Item $source (Join-Path $DIST_DIR "PinDL-$FlavorName-universal-$($script:VersionTag).apk") -Force
            $copied++
        }
    }

    if ($copied -eq 0) {
        Write-Host "Error: no APK produced for flavor '$FlavorName' in $FLUTTER_APK_DIR" -ForegroundColor Red
        exit 1
    }
    Write-Host "  -> $copied APK(s) copied to $DIST_DIR\ as PinDL-$FlavorName-...-$($script:VersionTag).apk" -ForegroundColor Green
}

function Write-BuildReport {
    # dist\build.md - the build report (rewritten on every build run).
    $finished = Get-Date
    $started = if ($script:BuildStart) { $script:BuildStart } else { $finished }
    $duration = $finished - $started

    $zone = Resolve-BuildTimeZone
    $flutterLine = ''
    try {
        $flutterLine = ((flutter --version 2>$null) | Select-Object -First 1)
        # flutter prints UTF-8 bullets that Windows PowerShell decodes via
        # the OEM code page; keep the report line ASCII-safe.
        if ($flutterLine) { $flutterLine = $flutterLine.Trim() -replace '[^\x20-\x7E]', ' ' }
    } catch { }
    $gitLine = ''
    try {
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
        $sha = (git rev-parse --short HEAD 2>$null)
        if ($sha) { $gitLine = "$($branch.Trim()) @ $($sha.Trim())" }
    } catch { }

    $osLine = [System.Environment]::OSVersion.VersionString
    try {
        $productName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).ProductName
        if ($productName) { $osLine = "$productName ($osLine)" }
    } catch { }
    $hostLine = "$([System.Environment]::MachineName) - user $([System.Environment]::UserName)"

    $abiMode = if ($Split) { 'split-per-abi (armeabi-v7a, arm64-v8a, x86, x86_64)' } else { 'universal (all ABIs in one APK)' }

    $md = @()
    $md += '# PinDL build report'
    $md += ''
    $md += '> Generated by `build_prod.ps1` - rewritten on every build run.'
    $md += '> `dist/` is gitignored: the APKs and this report are local build artifacts.'
    $md += ''
    $md += '## Build details'
    $md += ''
    $md += '| Field | Value |'
    $md += '|---|---|'
    $md += "| Project | PinDL (``pindl``) |"
    $md += "| Version | ``$($script:VersionBase)+$($script:VersionBuild)`` - tag ``$($script:VersionTag)`` |"
    $md += "| Flavors | ``$Flavor`` |"
    $md += "| ABI mode | $abiMode |"
    $md += "| Build command | ``$($script:BuildCommand)`` |"
    $md += "| Build from OS | $osLine |"
    $md += "| Host | $hostLine |"
    $md += "| Timezone | $($zone.Label) (local build timezone; override with ``PINDL_BUILD_TZ``) |"
    if ($flutterLine) { $md += "| Toolchain | $flutterLine |" }
    if ($gitLine) { $md += "| Source | ``$gitLine`` |" }
    $md += "| Started | $(Format-BuildStamp $started) |"
    $md += "| Finished | $(Format-BuildStamp $finished) |"
    $md += "| Total build time | $(Format-BuildDuration $duration) |"
    $md += ''
    $md += '## APKs'
    $md += ''
    $md += '| APK | Flavor | ABI | Size | Description |'
    $md += '|---|---|---|---|---|'

    $apks = @(Get-ChildItem -Path $DIST_DIR -Filter 'PinDL-*.apk' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($apk in $apks) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($apk.Name)
        $match = [regex]::Match($stem, '^PinDL-(?<flavor>[^-]+)-(?<abi>.+)-v\d+\.\d+\.\d+-b\d+$')
        $flavorCol = if ($match.Success) { $match.Groups['flavor'].Value } else { '-' }
        $abiCol = if ($match.Success) { $match.Groups['abi'].Value } else { '-' }
        $bytes = $apk.Length
        $mb = [math]::Round($bytes / 1000000, 1).ToString('F1', [System.Globalization.CultureInfo]::InvariantCulture)
        $sizeCol = "$mb MB ($('{0:N0}' -f $bytes) B)"
        $desc = if ($match.Success) { Get-ApkDescription -FlavorName $flavorCol -Abi $abiCol } else { 'unrecognized name' }
        $md += "| ``$($apk.Name)`` | $flavorCol | $abiCol | $sizeCol | $desc |"
    }
    if ($apks.Count -eq 0) { $md += '| (no APKs found) | | | | |' }

    $md += ''
    $md += "_Only APKs present in ``dist/`` at report time are listed. Sizes are on-disk decimal MB (bytes / 1,000,000)._"
    $md += ''

    $reportPath = Join-Path (Get-Location).Path (Join-Path $DIST_DIR 'build.md')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($reportPath, ($md -join "`r`n"), $utf8NoBom)
    Write-Host ""
    Write-Host "Build report written: $DIST_DIR\build.md" -ForegroundColor Green
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

    Copy-BuildArtifacts -FlavorName $FlavorName -Split $Split
    Show-ApkInfo -FlavorName $FlavorName -IsSplit $Split
}

function Show-ApkInfo {
    param(
        [string]$FlavorName,
        [bool]$IsSplit
    )

    # Release APKs live in dist\ (copied + renamed by Copy-BuildArtifacts).
    $apkDir = "dist"

    $apks = @(Get-ChildItem -Path $apkDir -Filter "PinDL-$FlavorName-*.apk" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($apk in $apks) {
        $bytes = $apk.Length
        $mb = [math]::Round($bytes / 1000000, 1).ToString('F1', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-Host "  $apkDir\$($apk.Name) ($mb MB, $('{0:N0}' -f $bytes) B)" -ForegroundColor Cyan
    }
    if ($apks.Count -eq 0) {
        Write-Host "  (no PinDL-$FlavorName-*.apk in $apkDir\)" -ForegroundColor DarkGray
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

    Read-AppVersion
    $script:BuildStart = Get-Date

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

    Write-BuildReport -Split $doSplit
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

$script:BuildCommand = "$($MyInvocation.MyCommand.Name)"
if ($GenerateKeyStore) { $script:BuildCommand += " -GenerateKeyStore" }
if ($Clean) { $script:BuildCommand += " -Clean" }
if ($BuildRelease) { $script:BuildCommand += " -BuildRelease" }
if ($Flavor) { $script:BuildCommand += " -Flavor $Flavor" }
if ($SplitABI) { $script:BuildCommand += " -SplitABI" }

if ($BuildRelease) {
    # Validate flavor and settle the dist\ overwrite/cancel question BEFORE any
    # (potentially long) clean/build work starts.
    if (-not $Flavor) {
        Write-Host ""
        Write-Host "Error: -Flavor is required with -BuildRelease" -ForegroundColor Red
        Write-Host "  Use: -Flavor lite, -Flavor ffmpeg, or -Flavor all" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Confirm-DistOutput
}

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
