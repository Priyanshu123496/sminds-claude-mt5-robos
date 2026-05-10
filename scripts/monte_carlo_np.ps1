# Non-parametric Monte Carlo robustness tester for MT5 backtest reports.
#
# Parses the Deals table in the HTML report to extract the ACTUAL per-trade
# P&L (profit + commission + swap) for every closed trade, then shuffles
# this real distribution N times to estimate equity-curve robustness.
#
# This is strictly more accurate than the parametric version (monte_carlo.ps1)
# because it preserves the real distribution shape, including fat tails and
# whatever clustering exists in the trade outcomes.
#
# Usage: .\monte_carlo_np.ps1 -ReportName "bt_smesp1_m15v2_USDCAD_M15" -Sims 5000
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

# Read UTF-16 encoded MT5 report
$bytes = [System.IO.File]::ReadAllBytes($reportPath)
$txt = [System.Text.Encoding]::Unicode.GetString($bytes)

# ─────────────────────────────────────────────────────────────────
# Parse the Deals table
# ─────────────────────────────────────────────────────────────────
# Find the Deals table header (second 'Deals' occurrence — first is summary)
$dealsHeaderIdx = -1
$pos = 0
$count = 0
while ($true) {
    $i = $txt.IndexOf('Deals', $pos)
    if ($i -lt 0) { break }
    $count++
    if ($count -eq 2) { $dealsHeaderIdx = $i; break }
    $pos = $i + 1
}
if ($dealsHeaderIdx -lt 0) {
    Write-Host "Could not find Deals table in report" -ForegroundColor Red
    exit 1
}

$dealsSection = $txt.Substring($dealsHeaderIdx)

# Each trade row has 13 <td> cells. Pattern for a single row:
#   <tr ...><td>time</td><td>deal#</td><td>SYMBOL</td><td>type</td><td>direction</td>
#   <td>vol</td><td>price</td><td>order</td><td>comm</td><td>swap</td><td>profit</td>
#   <td>balance</td><td>comment</td></tr>
# We want rows where direction == 'out' (closing deal — this is where P&L lives).

# Match each <tr ...>...</tr> block first, then parse cells inside.
$rowPattern = '<tr[^>]*>(.*?)</tr>'
$cellPattern = '<td[^>]*>(.*?)</td>'

$tradePnL = New-Object 'System.Collections.Generic.List[double]'
$rowMatches = [regex]::Matches($dealsSection, $rowPattern, 'Singleline')

foreach ($rm in $rowMatches) {
    $rowInner = $rm.Groups[1].Value
    $cellMatches = [regex]::Matches($rowInner, $cellPattern, 'Singleline')
    if ($cellMatches.Count -lt 12) { continue }

    # Cell index reference:
    # 0 time | 1 deal | 2 symbol | 3 type | 4 direction | 5 volume
    # 6 price | 7 order | 8 commission | 9 swap | 10 profit | 11 balance | 12 comment
    $direction = ($cellMatches[4].Groups[1].Value -replace '<[^>]+>','').Trim()
    if ($direction -ne 'out') { continue }

    function ParseNum($s) {
        $s = $s -replace '<[^>]+>',''
        $s = $s -replace '\s',''     # strip thin/regular spaces (thousands sep)
        $s = $s -replace '&nbsp;',''
        if ([string]::IsNullOrEmpty($s)) { return 0.0 }
        try { return [double]$s } catch { return 0.0 }
    }

    $commission = ParseNum $cellMatches[8].Groups[1].Value
    $swap       = ParseNum $cellMatches[9].Groups[1].Value
    $profit     = ParseNum $cellMatches[10].Groups[1].Value
    $totalPnL   = $profit + $commission + $swap
    $tradePnL.Add($totalPnL)
}

if ($tradePnL.Count -lt 5) {
    Write-Host "Too few closed trades parsed ($($tradePnL.Count)). Cannot run MC." -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# Summary stats from the actual distribution
# ─────────────────────────────────────────────────────────────────
$total = ($tradePnL | Measure-Object -Sum).Sum
$wins  = ($tradePnL | Where-Object { $_ -gt 0 }).Count
$losses= ($tradePnL | Where-Object { $_ -lt 0 }).Count
$winsArr  = @($tradePnL | Where-Object { $_ -gt 0 })
$lossesArr= @($tradePnL | Where-Object { $_ -lt 0 })
$avgWin   = if ($winsArr.Count -gt 0)   { ($winsArr   | Measure-Object -Average).Average } else { 0 }
$avgLoss  = if ($lossesArr.Count -gt 0) { ($lossesArr | Measure-Object -Average).Average } else { 0 }

Write-Host ""
Write-Host "═══════════════ Non-Parametric Monte Carlo ═══════════════" -ForegroundColor Cyan
Write-Host "Report           : $ReportName"
Write-Host "Trades parsed    : $($tradePnL.Count) closed deals (W:$wins L:$losses)"
Write-Host "Net (sum P&L)    : `$$([Math]::Round($total, 2))"
Write-Host "Avg win / loss   : `$$([Math]::Round($avgWin,2)) / `$$([Math]::Round($avgLoss,2))"
Write-Host "Sim count        : $Sims  (start equity: `$$StartEquity)"
Write-Host "─────────────────────────────────────────────────────────────"

# ─────────────────────────────────────────────────────────────────
# Run non-parametric MC: shuffle real trades, build equity curve
# ─────────────────────────────────────────────────────────────────
$rng = New-Object System.Random
$pnlArr = $tradePnL.ToArray()
$n = $pnlArr.Length

$finalEquities = New-Object 'System.Collections.Generic.List[double]'
$maxDDs        = New-Object 'System.Collections.Generic.List[double]'
$positiveCount = 0
$ruinCount     = 0

# Pre-allocate working buffer for in-place shuffle
$buf = New-Object double[] $n
for ($s = 0; $s -lt $Sims; $s++) {
    # Copy original
    [Array]::Copy($pnlArr, $buf, $n)
    # Fisher-Yates shuffle
    for ($i = $n - 1; $i -gt 0; $i--) {
        $j = $rng.Next($i + 1)
        $tmp = $buf[$i]; $buf[$i] = $buf[$j]; $buf[$j] = $tmp
    }
    # Equity walk
    $eq = [double]$StartEquity
    $peak = $eq
    $worstDD = 0.0
    for ($k = 0; $k -lt $n; $k++) {
        $eq += $buf[$k]
        if ($eq -gt $peak) { $peak = $eq }
        if ($peak -gt 0) {
            $dd = ($peak - $eq) / $peak
            if ($dd -gt $worstDD) { $worstDD = $dd }
        }
    }
    $finalEquities.Add($eq)
    $maxDDs.Add($worstDD)
    if ($eq -gt $StartEquity) { $positiveCount++ }
    if ($worstDD -gt 0.50)    { $ruinCount++ }
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
$p99DD       = Percentile $maxDDs 0.99

$colorProfit = if ($pctPositive -ge 80) { 'Green' } else { if ($pctPositive -ge 60) { 'Yellow' } else { 'Red' } }
$colorRuin   = if ($pctRuin     -le 5)  { 'Green' } else { if ($pctRuin     -le 15) { 'Yellow' } else { 'Red' } }

Write-Host ""
Write-Host "Result distribution ($Sims simulations, NON-PARAMETRIC):" -ForegroundColor Yellow
Write-Host ("  P(profitable)        : {0,6:N1}%" -f $pctPositive) -ForegroundColor $colorProfit
Write-Host ("  P(>50% drawdown)     : {0,6:N1}%" -f $pctRuin)     -ForegroundColor $colorRuin
Write-Host ""
Write-Host "Final equity (after $($tradePnL.Count) trades):"
Write-Host ("  5th percentile  : `${0,10:N2}" -f $p05Equity)
Write-Host ("  Median          : `${0,10:N2}" -f $medEquity)
Write-Host ("  95th percentile : `${0,10:N2}" -f $p95Equity)
Write-Host ""
Write-Host "Max equity drawdown:"
Write-Host ("  Median          : {0,5:N2}%" -f ($medDD * 100))
Write-Host ("  95th percentile : {0,5:N2}%" -f ($p95DD * 100))
Write-Host ("  99th percentile : {0,5:N2}%" -f ($p99DD * 100))
Write-Host "─────────────────────────────────────────────────────────────"

if ($pctPositive -ge 80 -and $pctRuin -le 10) {
    Write-Host "VERDICT: ROBUST EDGE - strategy passes non-parametric robustness gate." -ForegroundColor Green
}
elseif ($pctPositive -ge 60 -and $pctRuin -le 20) {
    Write-Host "VERDICT: MODERATE EDGE - proceed with caution, smaller risk allocation." -ForegroundColor Yellow
}
else {
    Write-Host "VERDICT: WEAK / NO EDGE - strategy may be over-fit, do not deploy." -ForegroundColor Red
}
Write-Host ""
