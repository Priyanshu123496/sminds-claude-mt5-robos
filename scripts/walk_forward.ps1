# Walk-forward stability tester for MT5 EAs.
#
# Splits a date range into N consecutive sub-windows, runs the EA's backtest
# on each, and reports out-of-sample consistency:
#   - How many sub-windows were profitable
#   - Worst-window net profit and DD
#   - Per-window summary
#
# This is a simpler form of walk-forward (no parameter re-optimization per
# window — uses fixed compiled defaults), but it answers the key question:
# "Is this strategy's edge consistent across time, or driven by a single
# good month?"
#
# Usage:
#   .\walk_forward.ps1 -ExpertFile "...ex5" -Symbol "USDCAD" -Period "M15" `
#       -From "2026.01.01" -To "2026.05.07" -Windows 4
param(
    [string]$ExpertFile = "SMINDS-EMA-Stoch-Pullback-V1.ex5",
    [string]$Symbol     = "USDCAD",
    [string]$Period     = "M15",
    [string]$From       = "2026.01.01",
    [string]$To         = "2026.05.07",
    [int]   $Windows    = 4,
    [int]   $Deposit    = 10000,
    [string]$Tag        = "wf"
)

# ─────────────────────────────────────────────────────────────────
# Date math: split range into N approximately equal windows
# ─────────────────────────────────────────────────────────────────
$start = [datetime]::ParseExact($From, "yyyy.MM.dd", $null)
$end   = [datetime]::ParseExact($To,   "yyyy.MM.dd", $null)
$totalDays = ($end - $start).TotalDays
$daysPerWindow = [Math]::Floor($totalDays / $Windows)

$windowList = @()
$cursor = $start
for ($i = 0; $i -lt $Windows; $i++) {
    $wFrom = $cursor
    $wTo = if ($i -eq $Windows - 1) { $end } else { $cursor.AddDays($daysPerWindow) }
    $windowList += [PSCustomObject]@{
        Index = $i + 1
        From  = $wFrom.ToString("yyyy.MM.dd")
        To    = $wTo.ToString("yyyy.MM.dd")
    }
    $cursor = $wTo
}

Write-Host ""
Write-Host "═════════════ Walk-Forward Stability Test ═════════════" -ForegroundColor Cyan
Write-Host "EA           : $ExpertFile"
Write-Host "Symbol/TF    : $Symbol / $Period"
Write-Host "Range        : $From -> $To  ($([int]$totalDays) days)"
Write-Host "Windows      : $Windows ($daysPerWindow days each)"
Write-Host "─────────────────────────────────────────────────────────────"

# ─────────────────────────────────────────────────────────────────
# Run each window
# ─────────────────────────────────────────────────────────────────
$results = @()
foreach ($w in $windowList) {
    $reportName = "bt_${Tag}_W$($w.Index)_${Symbol}_${Period}"
    Write-Host "`n[Window $($w.Index)/$Windows] $($w.From) -> $($w.To)" -ForegroundColor Yellow

    & .\run_single_test.ps1 -ExpertFile $ExpertFile `
        -From $w.From -To $w.To `
        -ReportName $reportName -Model "0" -Period $Period `
        -Symbol $Symbol -Deposit $Deposit -TimeoutSec 1500 | Out-Null

    $reportPath = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\$reportName.htm"
    if (Test-Path $reportPath) {
        $bytes = [System.IO.File]::ReadAllBytes($reportPath)
        $txt = [System.Text.Encoding]::Unicode.GetString($bytes)

        function GetVal($txt, $label) {
            $idx = $txt.IndexOf($label); if ($idx -lt 0) { return "" }
            $bStart = $txt.IndexOf('<b>', $idx); if ($bStart -lt 0 -or ($bStart - $idx) -gt 300) { return "" }
            $bEnd = $txt.IndexOf('</b>', $bStart); if ($bEnd -lt 0) { return "" }
            return $txt.Substring($bStart + 3, $bEnd - $bStart - 3).Trim()
        }
        function CleanNum($s) {
            if ([string]::IsNullOrEmpty($s)) { return 0.0 }
            $s = $s -replace '\s*\(.*\)\s*', ''
            $s = $s -replace '\s', ''
            try { return [double]$s } catch { return 0.0 }
        }

        $row = [PSCustomObject]@{
            Window  = $w.Index
            From    = $w.From
            To      = $w.To
            Net     = CleanNum (GetVal $txt 'Total Net Profit')
            PF      = (GetVal $txt 'Profit Factor')
            Trades  = (GetVal $txt 'Total Trades')
            EquityDD= (GetVal $txt 'Equity Drawdown Maximal')
        }
        $results += $row
        $netStr = '${0,9:N2}' -f $row.Net
        Write-Host "  Net=$netStr  PF=$($row.PF)  Trades=$($row.Trades)  DD=$($row.EquityDD)"
    }
    else {
        Write-Host "  REPORT MISSING" -ForegroundColor Red
        $results += [PSCustomObject]@{ Window = $w.Index; From = $w.From; To = $w.To; Net = 0; PF = ""; Trades = ""; EquityDD = "" }
    }
}

# ─────────────────────────────────────────────────────────────────
# Stability analysis
# ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════ Stability Summary ═══════════════" -ForegroundColor Cyan
$results | Format-Table -Property Window, From, To, Net, PF, Trades, EquityDD -AutoSize

$nets = @($results | ForEach-Object { $_.Net })
$totalNet  = ($nets | Measure-Object -Sum).Sum
$winCount  = ($nets | Where-Object { $_ -gt 0 }).Count
$lossCount = ($nets | Where-Object { $_ -lt 0 }).Count
$bestWin   = ($nets | Measure-Object -Maximum).Maximum
$worstWin  = ($nets | Measure-Object -Minimum).Minimum
$consistencyPct = $winCount / $Windows * 100.0

Write-Host ""
Write-Host "Combined net      : `$$([Math]::Round($totalNet, 2))"
Write-Host "Profitable windows: $winCount / $Windows ($([Math]::Round($consistencyPct, 1))%)"
Write-Host "Best window net   : `$$([Math]::Round($bestWin, 2))"
Write-Host "Worst window net  : `$$([Math]::Round($worstWin, 2))"
Write-Host ""

if ($consistencyPct -ge 75 -and $worstWin -gt -200) {
    Write-Host "VERDICT: STABLE EDGE - profitable in most windows, no catastrophic losses." -ForegroundColor Green
}
elseif ($consistencyPct -ge 50 -and $totalNet -gt 0) {
    Write-Host "VERDICT: MODERATE - profitable overall, some windows underperform." -ForegroundColor Yellow
}
else {
    Write-Host "VERDICT: UNSTABLE - edge concentrated in few windows, fragile." -ForegroundColor Red
}
Write-Host ""

# Save CSV
$csvPath = "C:\SMINDS\Projects\aminds-claude-mt5-robos\walkforward_${Tag}_${Symbol}_${Period}.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Saved: $csvPath" -ForegroundColor Cyan
