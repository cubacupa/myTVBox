<#
.SYNOPSIS
  TVBox one-click update to TV (Windows / PowerShell).

.DESCRIPTION
  Does exactly three things: git pull -> build -> install -r (silent overwrite).
  It never force-stops or launches the app, and never touches the TV screen.

  Keep all messages in ASCII on purpose: PowerShell 5.1 mis-decodes UTF-8
  without BOM, so non-ASCII strings would come out garbled.

.PARAMETER TV_IP
  TV IP address on the LAN, e.g. 192.168.1.84. Required.

.PARAMETER NoPull
  Skip git pull, only build and push.

.PARAMETER DryRun
  Build only. Do not connect to the TV or install anything.

.PARAMETER DevEco
  DevEco Studio install directory.
  Default: C:\Program Files\Huawei\DevEco Studio

.PARAMETER JavaHome
  Override the bundled JBR path (dir that contains bin\java.exe).

.PARAMETER SdkRoot
  Override the HarmonyOS SDK root (the dir containing default\openharmony).

.PARAMETER Hdc
  Override the full path to hdc.exe.

.EXAMPLE
  .\scripts\update-tv.ps1 192.168.1.84

.EXAMPLE
  .\scripts\update-tv.ps1 192.168.1.84 -NoPull -DryRun

.EXAMPLE
  .\scripts\update-tv.ps1 192.168.1.84 -DevEco "D:\DevEco Studio"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$TV_IP,

  [switch]$NoPull,
  [switch]$DryRun,

  [string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio',
  [string]$JavaHome = '',
  [string]$SdkRoot = '',
  [string]$Hdc = ''
)

$ErrorActionPreference = 'Stop'

function Die {
  param([string]$Message)
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

function Ok {
  param([string]$Message)
  Write-Host "OK: $Message" -ForegroundColor Green
}

# ---------- First-time prerequisites (script cannot do these) ----------
# 1. Install DevEco Studio, sign in with the Huawei account.
# 2. Register the TV's UDID in AGC (hdc shell bm get --udid).
# 3. Open this project in DevEco: File > Project Structure > Signing Configs >
#    Automatically generate signature, once. This writes build-profile.json5.
# 4. TV: Developer mode + wireless debugging on, same LAN, note its IP.

# ---------- Locate toolchain ----------
if (-not (Test-Path $DevEco)) {
  $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  if (-not [string]::IsNullOrEmpty($pf86)) {
    $alt = Join-Path $pf86 'Huawei\DevEco Studio'
    if (Test-Path $alt) { $DevEco = $alt }
  }
}
if (-not (Test-Path $DevEco)) {
  Die "DevEco Studio not found at '$DevEco'. Pass -DevEco <path>."
}

if ([string]::IsNullOrEmpty($JavaHome)) { $JavaHome = Join-Path $DevEco 'jbr' }
if (-not (Test-Path (Join-Path $JavaHome 'bin\java.exe'))) {
  Die "JBR (java.exe) not found at '$JavaHome'. Pass -JavaHome <path>."
}

$HvigorW = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.bat'
if (-not (Test-Path $HvigorW)) {
  Die "hvigorw.bat not found at '$HvigorW'. Check the DevEco install."
}

if ([string]::IsNullOrEmpty($SdkRoot)) {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk'),
    (Join-Path $env:APPDATA 'Huawei\Sdk'),
    (Join-Path $DevEco 'sdk')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'default\openharmony'))) {
      $SdkRoot = $c
      break
    }
  }
}
if ([string]::IsNullOrEmpty($SdkRoot)) {
  Die "HarmonyOS SDK not found. Pass -SdkRoot <dir containing default\openharmony>."
}

if ([string]::IsNullOrEmpty($Hdc)) {
  $Hdc = Join-Path $SdkRoot 'default\openharmony\toolchains\hdc.exe'
  if (-not (Test-Path $Hdc)) {
    $found = Get-Command hdc.exe -ErrorAction SilentlyContinue
    if ($found) { $Hdc = $found.Source }
  }
}
if (-not (Test-Path $Hdc)) {
  Die "hdc.exe not found. Pass -Hdc <full path to hdc.exe>."
}

$Log = Join-Path $env:TEMP 'tvbox-update-build.log'

# ---------- Repo ----------
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
& git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die "$Root is not a git repo." }

# Auto-sign writes local signing config into these two files. They are not
# committed. Stash them before pull, restore after. Any other change = stop.
$otherDirty = & git status --porcelain | Where-Object {
  $_ -notmatch '^.. (build-profile\.json5|entry/build-profile\.json5|scripts/)'
}
if ($otherDirty) {
  $otherDirty | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  Die "Uncommitted changes found. Commit or revert them first; this script will not discard work."
}

# ---------- Pull ----------
if ($NoPull) {
  Ok "Skipping git pull (-NoPull)."
} else {
  $stashed = $false
  & git diff --quiet -- build-profile.json5 entry/build-profile.json5 2>$null
  if ($LASTEXITCODE -ne 0) {
    & git stash push -q -m 'tvbox-update: local signing config' -- build-profile.json5 entry/build-profile.json5
    if ($LASTEXITCODE -ne 0) { Die "git stash failed." }
    $stashed = $true
    Ok "Local signing config stashed."
  }
  & git pull --ff-only
  if ($LASTEXITCODE -ne 0) { Die "git pull failed (local commits or diverged branch). Resolve manually." }
  Ok "Code updated."
  if ($stashed) {
    & git stash pop -q
    if ($LASTEXITCODE -ne 0) { Die "Failed to restore signing config. Run: git stash list / git stash pop" }
    Ok "Local signing config restored."
  }
}

# ---------- Build ----------
# Redirect to a log file, never pipe to Select-Object -First: a broken pipe
# can kill hvigor mid-packaging and leave a stale HAP behind.
Write-Host "-> Building. Log: $Log"
$env:JAVA_HOME = $JavaHome
$env:DEVECO_SDK_HOME = $SdkRoot
& $HvigorW assembleHap --mode module -p product=default -p buildMode=debug --no-daemon *> $Log
$buildRc = $LASTEXITCODE
if ($buildRc -ne 0) {
  Get-Content $Log | Select-String -Pattern 'ERROR|BUILD' | Select-Object -Last 20 | ForEach-Object {
    Write-Host $_ -ForegroundColor Red
  }
  Die "Build failed (exit $buildRc). Full log: $Log"
}
Get-Content $Log | Select-String -Pattern 'BUILD' | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
Ok "Build OK."

$Hap = Join-Path $Root 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not (Test-Path $Hap)) {
  Die "Signed HAP not found: $Hap. Do the first-time auto-sign in DevEco."
}

if ($DryRun) {
  Ok "Dry-run: build done, TV untouched."
  exit 0
}

# ---------- Silent install ----------
# hdc drops its connection between external calls, so start/tconn/list/install
# must happen in this one process, back to back.
& taskkill /F /IM hdc.exe 2>$null | Out-Null
& $Hdc start -r *> $null
& $Hdc tconn "${TV_IP}:5555" *> $null
if ($LASTEXITCODE -ne 0) {
  Die "Cannot connect to ${TV_IP}:5555. Check TV wireless debugging and IP."
}

$targets = & $Hdc list targets 2>$null
if (-not ($targets -match [regex]::Escape($TV_IP))) {
  $targets | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  Die "Device $TV_IP not in the target list."
}

Write-Host "-> Installing (app not launched): $Hap"
& $Hdc -t "${TV_IP}:5555" install -r $Hap
if ($LASTEXITCODE -ne 0) {
  Die "Install failed. The TV may have shown a confirmation dialog; check the screen."
}
Ok "Pushed to $TV_IP. TV screen was not interrupted."
