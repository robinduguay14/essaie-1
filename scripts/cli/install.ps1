#Requires -Version 5.1
<#
.SYNOPSIS
    Installs OmniRoute (https://github.com/diegosouzapw/OmniRoute) on Windows.

.DESCRIPTION
    Thin wrapper around `npm install -g omniroute` — OmniRoute ships as a single
    npm package (dashboard + API on one port), so there is no separate binary
    release to fetch. This script:
      1. Checks for a supported Node.js version (>=22.22.2 <23 || >=24.0.0 <27,
         mirroring the "engines" field in package.json) and offers to install
         the Node.js LTS via winget if it is missing or out of range.
      2. Runs `npm install -g omniroute`.
      3. Prints the quick-start steps (dashboard URL, connecting a free
         provider, verifying the install) so first run needs no extra lookup.

    Intended usage (once published under a stable URL), mirroring other CLI
    installers:

        irm https://omniroute.dev/install.ps1 | iex

    Until then, run it locally:

        pwsh -File scripts/cli/install.ps1

.PARAMETER Version
    npm dist-tag or exact version to install, e.g. "latest", "next", "3.9.0".
    Defaults to "latest".

.PARAMETER SkipNodeCheck
    Skip the Node.js version check/install step entirely and go straight to
    `npm install -g`. Use this if you manage Node.js yourself (nvm-windows,
    Volta, fnm, ...).

.PARAMETER SkipPostinstall
    Sets OMNIROUTE_SKIP_POSTINSTALL=1 for the npm install, skipping the
    native (better-sqlite3) build warm-up. Useful on slow/headless machines —
    OmniRoute falls back transparently to a pure-JS SQLite engine at runtime.

.PARAMETER Yes
    Do not prompt before installing Node.js via winget; assume yes.

.EXAMPLE
    pwsh -File scripts/cli/install.ps1

.EXAMPLE
    pwsh -File scripts/cli/install.ps1 -Version next -SkipPostinstall -Yes
#>

[CmdletBinding()]
param(
    [string]$Version = "latest",
    [switch]$SkipNodeCheck,
    [switch]$SkipPostinstall,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Node engines range from package.json: ">=22.22.2 <23 || >=24.0.0 <27"
$script:NodeRanges = @(
    @{ Min = [version]"22.22.2"; MaxExclusive = [version]"23.0.0" }
    @{ Min = [version]"24.0.0"; MaxExclusive = [version]"27.0.0" }
)

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Red
}

function Test-NodeVersionInRange {
    param([version]$Candidate)
    foreach ($range in $script:NodeRanges) {
        if ($Candidate -ge $range.Min -and $Candidate -lt $range.MaxExclusive) {
            return $true
        }
    }
    return $false
}

function Get-InstalledNodeVersion {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $raw = (& node --version).Trim().TrimStart("v")
        return [version]$raw
    } catch {
        return $null
    }
}

function Install-NodeViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Fail "winget is not available on this machine."
        Write-Warn2 "Install Node.js 22.x or 24.x manually from https://nodejs.org/ (LTS), then re-run this script."
        exit 1
    }

    if (-not $Yes) {
        $answer = Read-Host "Install Node.js LTS via winget now? [Y/n]"
        if ($answer -and $answer -notmatch '^[Yy]') {
            Write-Warn2 "Skipping Node.js install. Install a supported version manually and re-run."
            exit 1
        }
    }

    Write-Step "Installing Node.js LTS via winget (OpenJS.NodeJS.LTS)..."
    & winget install --id OpenJS.NodeJS.LTS --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "winget install failed (exit code $LASTEXITCODE)."
        Write-Warn2 "Install Node.js 22.x or 24.x manually from https://nodejs.org/, then re-run this script."
        exit 1
    }

    # winget updates PATH for new shells, not the current one — refresh from
    # the registry so `node`/`npm` resolve without reopening the terminal.
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Test-Node {
    if ($SkipNodeCheck) {
        Write-Step "Skipping Node.js version check (-SkipNodeCheck)."
        return
    }

    Write-Step "Checking for a supported Node.js version (>=22.22.2 <23 or >=24.0.0 <27)..."
    $installed = Get-InstalledNodeVersion

    if ($installed -and (Test-NodeVersionInRange $installed)) {
        Write-Ok "Found Node.js v$installed"
        return
    }

    if ($installed) {
        Write-Warn2 "Found Node.js v$installed, which is outside the supported range."
    } else {
        Write-Warn2 "Node.js was not found on PATH."
    }

    Install-NodeViaWinget

    $installed = Get-InstalledNodeVersion
    if (-not $installed -or -not (Test-NodeVersionInRange $installed)) {
        Write-Fail "Node.js install did not produce a supported version on PATH."
        Write-Warn2 "Open a new terminal and re-run this script, or install manually from https://nodejs.org/."
        exit 1
    }
    Write-Ok "Node.js v$installed is ready."
}

function Install-OmniRoute {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Fail "npm was not found on PATH even after the Node.js check. Open a new terminal and try again."
        exit 1
    }

    if ($SkipPostinstall) {
        $env:OMNIROUTE_SKIP_POSTINSTALL = "1"
    }

    Write-Step "Installing omniroute@$Version globally via npm..."
    & npm install -g "omniroute@$Version"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "npm install failed (exit code $LASTEXITCODE)."
        Write-Warn2 "See docs/guides/TROUBLESHOOTING.md#npm-install-warnings-eresolve--peer--deprecated for common ERESOLVE/peer-dep warnings."
        exit 1
    }
}

function Show-NextSteps {
    Write-Host ""
    Write-Host "OmniRoute installed." -ForegroundColor Green
    Write-Host ""
    Write-Host "  1) Run it:"
    Write-Host "       omniroute" -ForegroundColor White
    Write-Host "     Dashboard: http://localhost:20128   API: http://localhost:20128/v1"
    Write-Host ""
    Write-Host "  2) Connect a free provider (no signup):"
    Write-Host "     Dashboard -> Providers -> connect 'Kiro AI' or 'OpenCode Free'."
    Write-Host ""
    Write-Host "  3) Point your coding tool at the API:"
    Write-Host "       Base URL: http://localhost:20128/v1"
    Write-Host "       API Key:  (copy from Dashboard -> Endpoints)"
    Write-Host "       Model:    auto"
    Write-Host ""
    Write-Host "  4) Verify:"
    Write-Host "       curl http://localhost:20128/v1/models -H `"Authorization: Bearer YOUR_KEY`"" -ForegroundColor White
    Write-Host ""
    Write-Host "Docs: https://github.com/diegosouzapw/OmniRoute#-quick-start"
}

Write-Host ""
Write-Host "OmniRoute installer for Windows" -ForegroundColor Cyan
Write-Host "================================"

Test-Node
Install-OmniRoute
Show-NextSteps
