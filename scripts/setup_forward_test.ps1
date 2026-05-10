# setup_forward_test.ps1
# One-shot setup for forward-testing the Tier-1 EA portfolio on a new system.
#
# What it does:
#   1. Detects MT5 installation (or accepts custom path)
#   2. Copies all Tier-1 EA .mq5 source files into MT5's MQL5\Experts folder
#   3. Compiles each EA via MetaEditor
#   4. Prints the chart-attachment checklist for the user
#
# Usage (PowerShell, run from repo root):
#   .\scripts\setup_forward_test.ps1
#   .\scripts\setup_forward_test.ps1 -MT5Path "C:\Program Files\MetaTrader 5"
#   .\scripts\setup_forward_test.ps1 -DataDir "C:\Users\me\AppData\Roaming\MetaQuotes\Terminal\XXX"
#
# Notes:
#   - Run AFTER logging into your broker in MT5 at least once
#   - Run AFTER cloning the repo: git clone https://github.com/Priyanshu123496/sminds-claude-mt5-robos.git

param(
    [string]$MT5Path  = "C:\Program Files\MetaTrader 5",
    [string]$DataDir  = "",
    [switch]$SkipCompile
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SMINDS MT5 Strategy Factory — Forward Test Setup" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Resolve repo paths ──
$repoRoot   = Split-Path -Parent $PSScriptRoot
$expertsSrc = Join-Path $repoRoot "Experts"
if (-not (Test-Path $expertsSrc)) {
    Write-Host "ERROR: Experts folder not found at $expertsSrc" -ForegroundColor Red
    Write-Host "Run this script from the cloned repo's scripts/ folder." -ForegroundColor Red
    exit 1
}

# ── Auto-detect MT5 data directory if not provided ──
if (-not $DataDir) {
    $candidates = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^[A-F0-9]{32}$' }
    if ($candidates.Count -eq 0) {
        Write-Host "ERROR: Could not auto-detect MT5 data directory." -ForegroundColor Red
        Write-Host "Open MT5 once (File -> Open Data Folder) and pass the path via -DataDir." -ForegroundColor Yellow
        exit 1
    } elseif ($candidates.Count -gt 1) {
        Write-Host "Multiple MT5 installations detected:" -ForegroundColor Yellow
        $candidates | ForEach-Object { Write-Host "  $($_.FullName)" }
        Write-Host "Pick one and re-run with -DataDir <full path>" -ForegroundColor Yellow
        exit 1
    }
    $DataDir = $candidates[0].FullName
    Write-Host "Auto-detected MT5 data dir:" -ForegroundColor Green
    Write-Host "  $DataDir"
}

$expertsDst = Join-Path $DataDir "MQL5\Experts"
if (-not (Test-Path $expertsDst)) {
    Write-Host "ERROR: MT5 Experts folder not found at $expertsDst" -ForegroundColor Red
    exit 1
}

# ── Tier-1 EA list (only graduates we want to forward-test) ──
$tier1 = @(
    "TTR-XI-V1a-prod-ready-v12.mq5",          # Gold trend follower (flagship)
    "SMINDS-Gold-Pullback-V1.mq5",            # Gold trend pullback
    "SMINDS-Gold-Scalper-V1.mq5",             # Gold high-freq scalper
    "SMINDS-Gold-Pyramid-V1.mq5",             # Gold trend confirmation amplifier
    "SMINDS-News-Event-V1.mq5",               # Gold event-driven volatility breakout
    "SMINDS-EMA-Stoch-Pullback-V1.mq5",       # USDCAD pullback
    "SMINDS-London-Breakout-V1.mq5",          # EURUSD/GBPUSD London breakout
    "SMINDS-BB-Squeeze-V1.mq5",               # Multi-pair BB squeeze
    "SMINDS-RSI-MeanRev-V1.mq5",              # Forex RSI mean reversion
    "SMINDS-Donchian-V1.mq5",                 # USDCAD Donchian
    "SMINDS-RangeBreakRetest-V1.mq5",         # Multi-symbol range break+retest
    "SMINDS-RoundNum-V1.mq5",                 # Round-number rejection
    "SMINDS-InsideBar-V1.mq5",                # Inside bar breakout
    "SMINDS-CCI-Reversal-V1.mq5",             # CCI extreme reversal
    "SMINDS-Pivot-V1.mq5"                     # Daily pivot reversion (GBPUSD)
)

# ── Copy ──
Write-Host ""
Write-Host "Copying EA source files to MT5..." -ForegroundColor Cyan
$copied = 0
$missing = @()
foreach ($file in $tier1) {
    $src = Join-Path $expertsSrc $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $expertsDst -Force
        Write-Host "  + $file" -ForegroundColor Green
        $copied++
    } else {
        Write-Host "  ! MISSING: $file" -ForegroundColor Yellow
        $missing += $file
    }
}
Write-Host "Copied $copied / $($tier1.Count) EAs"

# ── Compile via MetaEditor ──
if (-not $SkipCompile) {
    $metaeditor = Join-Path $MT5Path "MetaEditor64.exe"
    if (-not (Test-Path $metaeditor)) {
        Write-Host ""
        Write-Host "WARNING: MetaEditor64.exe not found at $metaeditor" -ForegroundColor Yellow
        Write-Host "Skipping compile. Will be compiled on first chart attachment." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "Compiling EAs via MetaEditor..." -ForegroundColor Cyan
        foreach ($file in $tier1) {
            $mq5 = Join-Path $expertsDst $file
            if (Test-Path $mq5) {
                $log = [System.IO.Path]::ChangeExtension($mq5, ".compile.log")
                & $metaeditor /compile:$mq5 /log:$log | Out-Null
                # Read compile log to check result
                if (Test-Path $log) {
                    $bytes = [System.IO.File]::ReadAllBytes($log)
                    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                        $logText = [System.Text.Encoding]::Unicode.GetString($bytes)
                    } else {
                        $logText = [System.Text.Encoding]::UTF8.GetString($bytes)
                    }
                    if ($logText -match 'Result: 0 errors') {
                        Write-Host "  ✓ $file" -ForegroundColor Green
                    } else {
                        $err = ($logText -split "`n" | Where-Object { $_ -match 'error' } | Select-Object -First 1)
                        Write-Host "  ✗ $file  $($err.Trim())" -ForegroundColor Red
                    }
                }
            }
        }
    }
}

# ── Print chart-attachment checklist ──
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  CHART ATTACHMENT CHECKLIST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Open MT5. For each row below, do:" -ForegroundColor White
Write-Host "  1. File -> New Chart -> select symbol -> set timeframe" -ForegroundColor Gray
Write-Host "  2. Drag EA from Navigator (left panel) onto the chart" -ForegroundColor Gray
Write-Host "  3. In the popup: Common tab -> Allow Algo Trading -> OK" -ForegroundColor Gray
Write-Host "  4. Verify the smiley face in chart top-right corner" -ForegroundColor Gray
Write-Host ""

$charts = @(
    @{ Symbol = "XAUUSD"; TF = "M15"; EA = "TTR-XI-V1a-prod-ready-v12";    Magic = 94736312; Note = "Gold flagship trend follower" }
    @{ Symbol = "XAUUSD"; TF = "M15"; EA = "SMINDS-Gold-Pullback-V1";       Magic = 94736330; Note = "Gold pullback continuation" }
    @{ Symbol = "XAUUSD"; TF = "M15"; EA = "SMINDS-Gold-Pyramid-V1";        Magic = 94736350; Note = "Gold trend confirmation" }
    @{ Symbol = "XAUUSD"; TF = "M5";  EA = "SMINDS-Gold-Scalper-V1";        Magic = 94736340; Note = "Gold high-freq scalper" }
    @{ Symbol = "XAUUSD"; TF = "H1";  EA = "SMINDS-News-Event-V1";          Magic = 94736360; Note = "Gold event-driven" }
    @{ Symbol = "USDCAD"; TF = "M15"; EA = "SMINDS-EMA-Stoch-Pullback-V1";  Magic = 96200001; Note = "Forex pullback" }
    @{ Symbol = "EURUSD"; TF = "M15"; EA = "SMINDS-London-Breakout-V1";     Magic = 96400001; Note = "London open breakout" }
    @{ Symbol = "GBPUSD"; TF = "M15"; EA = "SMINDS-BB-Squeeze-V1";          Magic = 96500001; Note = "Bollinger squeeze" }
    @{ Symbol = "EURUSD"; TF = "M15"; EA = "SMINDS-RangeBreakRetest-V1";    Magic = 97000001; Note = "Range break + retest" }
    @{ Symbol = "EURUSD"; TF = "M15"; EA = "SMINDS-InsideBar-V1";           Magic = 97400001; Note = "Inside bar @ 3% risk" }
    @{ Symbol = "EURUSD"; TF = "M15"; EA = "SMINDS-CCI-Reversal-V1";        Magic = 97500001; Note = "CCI extreme" }
    @{ Symbol = "GBPUSD"; TF = "M15"; EA = "SMINDS-Pivot-V1";               Magic = 97600001; Note = "Daily pivot reversion" }
    @{ Symbol = "EURUSD"; TF = "M15"; EA = "SMINDS-RoundNum-V1";            Magic = 97300001; Note = "Round-number rejection" }
)

$charts | Format-Table @{L="#";E={[array]::IndexOf($charts,$_)+1}}, Symbol, TF, EA, Magic, Note -AutoSize

Write-Host ""
Write-Host "ACCOUNT SETUP" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────────"
Write-Host "  Recommended: Demo account, $10,000 starting balance"
Write-Host "  Tools -> Options -> Expert Advisors:"
Write-Host "    [x] Allow Algo Trading"
Write-Host "    [x] Allow imports of external experts"
Write-Host "  Leverage: 1:100 minimum (1:500 ideal for Gold)"
Write-Host "  Margin: ~$3,500 will be in use at peak with all 13 EAs running"
Write-Host ""

if ($missing.Count -gt 0) {
    Write-Host "MISSING SOURCE FILES (re-pull repo to fix):" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow }
    Write-Host ""
}

Write-Host "Setup complete. Open MT5 and attach EAs per checklist above." -ForegroundColor Green
Write-Host ""
