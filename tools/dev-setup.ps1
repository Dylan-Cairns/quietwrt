Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" }
function Write-Skip  { param([string]$Message) Write-Host "    (skip) $Message" }
function Write-Done  { param([string]$Message) Write-Host "    $Message" }

# --- scoop ---

Write-Step 'Checking for scoop'
if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Skip 'scoop already installed'
} else {
    Write-Done 'Installing scoop'
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression

    $scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
    if ($env:PATH -notlike "*$scoopShims*") {
        $env:PATH = "$scoopShims;$env:PATH"
    }
}

# --- lua ---

Write-Step 'Checking for lua'
$luaExe = Join-Path $env:USERPROFILE 'scoop\apps\lua\current\bin\lua.exe'
if (Test-Path $luaExe) {
    Write-Skip 'lua already installed'
} else {
    Write-Done 'Installing lua'
    scoop install lua
}

$scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
if ($env:PATH -notlike "*$scoopShims*") {
    $env:PATH = "$scoopShims;$env:PATH"
}

# --- luarocks ---

Write-Step 'Checking for luarocks'
$luarocksExe = Join-Path $env:USERPROFILE 'scoop\apps\luarocks\current\luarocks.exe'
if (Test-Path $luarocksExe) {
    Write-Skip 'luarocks already installed'
} else {
    Write-Done 'Installing luarocks'
    scoop install luarocks
}

$luarocksShims = Join-Path $env:USERPROFILE 'scoop\apps\luarocks\current\rocks\bin'
if ($env:PATH -notlike "*$luarocksShims*") {
    $env:PATH = "$luarocksShims;$env:PATH"
}

# --- luarocks config ---
# luarocks cannot detect lua through scoop shims; it needs the real exe path.

Write-Step 'Configuring luarocks lua path'
Write-Done "Pointing luarocks at $luaExe"
& $luarocksExe --local config variables.LUA $luaExe | Out-Null

# --- luaunit ---

Write-Step 'Checking for luaunit'
$luaunit54 = Join-Path $env:APPDATA 'luarocks\share\lua\5.4\luaunit.lua'
if (Test-Path $luaunit54) {
    Write-Skip 'luaunit already installed'
} else {
    Write-Done 'Installing luaunit'
    & $luarocksExe --local install luaunit
}

# --- run tests ---

Write-Step 'Running tests'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    & $luaExe tests\run.lua
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Tests failed.' -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host 'Dev setup complete.' -ForegroundColor Green
