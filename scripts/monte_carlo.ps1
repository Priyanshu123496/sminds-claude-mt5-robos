# Monte Carlo robustness tester for MT5 backtest reports.
# Uses the summary stats (win count, loss count, avg/largest win, avg/largest loss)
# to generate plausible trade-sequence simulations.
#
# Approach: parametric MC. Models wins as truncated-normal in [0, largest_win]
# with mean=avg_win, std derived from (largest-avg)/2. Same for losses.
# Generates N synthetic trade sequences, shuffles each, builds equity curve,
# tracks final equity and max drawdown.
#
# Output: % of sims profitable, median final equity, 5th-percentile equity,
#         95th-percentile max-DD, equity distribution summary.
#
# Usage: .\monte_carlo.ps1 -ReportName "bt_smesp1_m15v2_USDCAD_M15" -Sims 5000
param(
    [string]$ReportName  = "bt_smesp1_m15v2_USDCAD_M15",
    [int]   $Sims        = 5000,
    [int]   $StartEquity = 10000,
    [string]$ReportsDir  = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
)

$reportPath = Join-Path $ReportsDir "$ReportName.htm"
if (-not (Test-Path $reportPath)) {
    Write-Host "Report not found: $reportPath" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# Parse summary stats from MT5 HTML report (UTF-16 encoded)
# ─────────────────────────────────────────────────────────────────
$bytes = [System.IO.File]::ReadAllBytes($reportPath)
$txt = [System.Text.Encoding]::Unicode.GetString($bytes)

function GetVal($txt, $label) {
    $idx = $txt.IndexOf($label); if ($idx -lt 0) { return $null }
    $bStart = $txt.IndexOf('<b>', $idx); if ($bStart -lt 0 -or ($bStart - $idx) -gt 300) { return $null }
    $bEnd = $txt.IndexOf('</b>', $bStart); if ($bEnd -lt 0) { return $null }
    return $txt.Substring($bStart + 3, $bEnd - $bStart - 3).Trim()
}

# Strip "(X.XX%)" or "(N)" parenthetical from value, normalize spaces
function CleanNum($s) {
    if ($null -eq $s) { return $null }
    # strip parens content
    $s = $s -replace '\s*\(.*\)\s*', ''
    # strip thin spaces (Unicode 0x202F or 0x00A0) that MT5 uses as thousands sep
    $s = $s -replace '\s', ''
    return [double]$s
}

# Extract count from "22 (51.16%)" pattern
function ExtractCount($s) {
    if ($null -eq $s) { return $null }
    if ($s -match '^(\d+)') { return [int]$Matches[1] }
    return $null
}

$totalTrades   = ExtractCount (GetVal $txt 'Total Trades')
$profitTrades  = ExtractCount (GetVal $txt 'Profit Trades (% of total)')
$lossTrades    = ExtractCount (GetVal $txt 'Loss Trades (% of total)')
$avgWin        = CleanNum (GetVal $txt 'Average profit trade')
$avgLoss       = CleanNum (GetVal $txt 'Average loss trade')
$largestWin    = CleanNum (GetVal $txt 'Largest profit trade')
$largestLoss   = CleanNum (GetVal $txt 'Largest loss trade')
$netProfit     = CleanNum (GetVal $txt 'Total Net Profit')
$maxDDReport   = GetVal $txt 'Equity Drawdown Maximal'

if (-not $profitTrades -or -not $lossTrades -or -not $avgWin -or -not $avgLoss) {
    Write-Host "Could not parse required stats from report" -ForegroundColor Red
    Write-Host "  Profit trades : $profitTrades"
    Write-Host "  Loss trades   : $lossTrades"
    Write-Host "  Avg win       : $avgWin"
    Write-Host "  Avg loss      : $avgLoss"
    exit 1
}

# Sanity / fallbacks for std estimation
if (-not $largestWin)  { $largestWin = $avgWin * 2.0 }
if (-not $largestLoss) { $largestLoss = $avgLoss * 2.0 }

# Estimate std-dev: assume largest is ~2 std from mean (rough)
$stdWin  = [Math]::Max(($largestWin - $avgWin) / 2.0, $avgWin * 0.2)
$stdLoss = [Math]::Max(([Math]::Abs($largestLoss) - [Math]::Abs($avgLoss)) / 2.0, [Math]::Abs($avgLoss) * 0.2)

Write-Host ""
Write-Host "═══════════════ Monte Carlo Robustness Test ═══════════════" -ForegroundColor Cyan
Write-Host "Report           : $ReportName"
Write-Host "Trades (W/L)     : $profitTrades wins / $lossTrades losses (total $totalTrades)"
Write-Host "Avg win / loss   : `$$avgWin / `$$avgLoss"
Write-Host "Largest win/loss : `$$largestWin / `$$largestLoss"
Write-Host "Std win / loss   : ~`$$([Math]::Round($stdWin,2)) / ~`$$([Math]::Round($stdLoss,2))"
Write-Host "Original net     : `$$netProfit  (DD: $maxDDReport)"
Write-Host "Sim count        : $Sims  (start equity: `$$StartEquity)"
Write-Host "─────────────────────────────────────────────────────────────"

# ─────────────────────────────────────────────────────────────────
# Box-Muller normal RNG
# ─────────────────────────────────────────────────────────────────
$rng = New-Object System.Random
function NextNormal($mean, $std) {
    $u1 = $rng.NextDouble()
    $u2 = $rng.NextDouble()
    if ($u1 -le 0) { $u1 = 1e-10 }
    $z = [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
    return $mean + $z * $std
}

# ─────────────────────────────────────────────────────────────────
# Run simulations
# ─────────────────────────────────────────────────────────────────
$finalEquities = New-Object 'System.Collections.Generic.List[double]'
$maxDDs        = New-Object 'System.Collections.Generic.List[double]'
$positiveCount = 0
$ruinCount     = 0   # account dropped below 30% of start (catastrophic DD)

for ($s = 0; $s -lt $Sims; $s++) {
    # Build synthetic trade list
    $trades = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt $profitTrades; $i++) {
        $w = NextNormal $avgWin $stdWin
        if ($w -lt 0) { $w = 0.0 }
        if ($w -gt $largestWin) { $w = $largestWin }
        $trades.Add($w)
    }
    for ($i = 0; $i -lt $lossTrades; $i++) {
        $l = NextNormal $avgLoss $stdLoss
        if ($l -gt 0) { $l = 0.0 }
        if ($l -lt $largestLoss) { $l = $largestLoss }
        $trades.Add($l)
    }
    # Shuffle (Fisher-Yates)
    $arr = $trades.ToArray()
    for ($i = $arr.Length - 1; $i -gt 0; $i--) {
        $j = $rng.Next($i + 1)
        $tmp = $arr[$i]; $arr[$i] = $arr[$j]; $arr[$j] = $tmp
    }
    # Equity curve & DD
    $eq = $StartEquity
    $peak = $eq
    $worstDD = 0.0
    foreach ($t in $arr) {
        $eq += $t
        if ($eq -gt $peak) { $peak = $eq }
        $dd = ($peak - $eq) / $peak
        if ($dd -gt $worstDD) { $worstDD = $dd }
        if ($eq -lt $StartEquity * 0.30) {
            # treat as ruin marker but continue simulation
        }
    }
    $finalEquities.Add($eq)
    $maxDDs.Add($worstDD)
    if ($eq -gt $StartEquity) { $positiveCount++ }
    if ($worstDD -gt 0.50) { $ruinCount++ }
}

# ─────────────────────────────────────────────────────────────────
# Statistics
# ─────────────────────────────────────────────────────────────────
function Percentile($list, $p) {
    $arr = $list.ToArray() | Sort-Object
    $idx = [int]([Math]::Floor(($arr.Length - 1) * $p))
    return $arr[$idx]
}

$pctPositive = $positiveCount / $Sims * 100.0
$pctRuin     = $ruinCount / $Sims * 100.0
$medEquity   = Percentile $finalEquities 0.5
$p05Equity   = Percentile $finalEquities 0.05
$p95Equity   = Percentile $finalEquities 0.95
$medDD       = Percentile $maxDDs 0.5
$p95DD       = Percentile $maxDDs 0.95

Write-Host ""
Write-Host "Result distribution ($Sims simulations):" -ForegroundColor Yellow
$colorProfit = if ($pctPositive -ge 80) { 'Green' } else { if ($pctPositive -ge 60) { 'Yellow' } else { 'Red' } }
$colorRuin   = if ($pctRuin     -le 5)  { 'Green' } else { if ($pctRuin     -le 15) { 'Yellow' } else { 'Red' } }
Write-Host ("  P(profitable)        : {0,6:N1}%" -f $pctPositive) -ForegroundColor $colorProfit
Write-Host ("  P(>50% drawdown)     : {0,6:N1}%" -f $pctRuin)     -ForegroundColor $colorRuin
Write-Host ""
Write-Host "Final equity (after $totalTrades trades):"
Write-Host ("  5th percentile  : `${0,10:N2}" -f $p05Equity)
Write-Host ("  Median          : `${0,10:N2}" -f $medEquity)
Write-Host ("  95th percentile : `${0,10:N2}" -f $p95Equity)
Write-Host ""
Write-Host "Max equity drawdown:"
Write-Host ("  Median          : {0,5:N2}%" -f ($medDD * 100))
Write-Host ("  95th percentile : {0,5:N2}%" -f ($p95DD * 100))
Write-Host "─────────────────────────────────────────────────────────────"

# Verdict
if ($pctPositive -ge 80 -and $pctRuin -le 10) {
    Write-Host "VERDICT: ROBUST EDGE - strategy passes Monte Carlo robustness gate." -ForegroundColor Green
}
elseif ($pctPositive -ge 60 -and $pctRuin -le 20) {
    Write-Host "VERDICT: MODERATE EDGE - proceed with caution, smaller risk allocation." -ForegroundColor Yellow
}
else {
    Write-Host "VERDICT: WEAK / NO EDGE - strategy may be over-fit, do not deploy." -ForegroundColor Red
}
Write-Host ""
