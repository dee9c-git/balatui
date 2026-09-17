# Builds the Balatui Windows installer by hand.
#
# Requirements:
#   - Rust toolchain (cargo)
#   - Inno Setup 6+  (winget install JRSoftware.InnoSetup, or https://jrsoftware.org/isinfo.php)
#
# Usage:
#   ./build-installer.ps1
# Output:
#   packaging\windows\output\BalatuiSetup-<version>.exe

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:WinDir = $PSScriptRoot

function Get-ProjectVersion {
    $toml = Get-Content -LiteralPath (Join-Path $script:Root "Cargo.toml") -Raw
    if ($toml -match 'version\s*=\s*"([^"]+)"') {
        return $Matches[1]
    }
    Write-Warning "Could not parse version from Cargo.toml, falling back to 0.1.0"
    return "0.1.0"
}

function Find-ISCC {
    if ($env:ISCC -and (Test-Path -LiteralPath $env:ISCC)) {
        return $env:ISCC
    }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe"
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    return $null
}

Write-Host "==> Balatui installer build" -ForegroundColor Cyan

Write-Host "Generating icon..."
& (Join-Path $script:WinDir "generate-icon.ps1")

Write-Host "Building release binary..."
Push-Location $script:Root
try {
    cargo build --release --locked
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
}
finally {
    Pop-Location
}

$exe = Join-Path $script:Root "target\release\balatui.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Build output not found: $exe"
}

$version = Get-ProjectVersion
Write-Host "Version: $version"

$iscc = Find-ISCC
if (-not $iscc) {
    throw "Inno Setup not found. Install it with: winget install JRSoftware.InnoSetup"
}
Write-Host "Using ISCC: $iscc"

$outputDir = Join-Path $script:WinDir "output"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

& $iscc (Join-Path $script:WinDir "balatui.iss") "/DMyAppVersion=$version" "/O$outputDir"
if ($LASTEXITCODE -ne 0) { throw "ISCC compile failed with exit code $LASTEXITCODE" }

$setup = Join-Path $outputDir "BalatuiSetup-$version.exe"
if (-not (Test-Path -LiteralPath $setup)) {
    throw "Installer not found after compile: $setup"
}

Write-Host ""
Write-Host "==> Done" -ForegroundColor Green
Write-Host "Installer: $setup"
Write-Host "SHA-256:   $((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Test the installer on a clean machine/VM (verify the Start Menu shortcut opens balatui in a terminal)."
Write-Host "  2. Upload to GitHub Releases:"
Write-Host "     gh release create v$version $setup --title 'Balatui v$version' --generate-notes"