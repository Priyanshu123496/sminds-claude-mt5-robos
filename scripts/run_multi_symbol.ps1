# Run a single EA across multiple symbols/TFs and aggregate results.
# Usage: .\run_multi_symbol.ps1 -ExpertFile "...ex5" -From "2026.01.01" -To "2026.05.07"
param(
    [string]$ExpertFile = "SMINDS-EMA-Stoch-Pullback-V1.ex5",
    [string]$From       = "2026.01.01",
    [string]$To         = "2026.05.07",
    [string]$Period     = "M5",
    [int]   $Deposit    = 10000,
    [string]$Tag        = "smesp1",
    [string[]]$Symbols  = @("XAGUSD","EURUSD","GBPUSD","USDJPY","AUDUSD","XAUUSD")
)

$results = @()
foreach ($sym in $Symbols) {
    $reportName = "bt_${Tag}_${sym}_${Period}"
    Write-Host "`n========== Testing $sym $Period ==========" -ForegroundColor Cyan
    & .\run_single_test.ps1 -ExpertFile $ExpertFile -From $From -To $To `
        -ReportName $reportName -Model "0" -Period $Period `
        -Symbol $sym -Deposit $Deposit -TimeoutSec 1500 | Out-Null

    # Parse the report
    $reportPath = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\$reportName.htm"
    if (Test-Path $reportPath) {
        $bytes = [System.IO.File]::ReadAllBytes($reportPath)
        $txt = [System.Text.Encoding]::Unicode.GetString($bytes)

        function GetVal($txt, $label) {
            $idx = $txt.IndexOf($label); if($idx -lt 0) { return "" }
            $bStart = $txt.IndexOf('<b>', $idx); if($bStart -lt 0 -or ($bStart - $idx) -gt 300) { return "" }
            $bEnd = $txt.IndexOf('</b>', $bStart); if($bEnd -lt 0) { return "" }
            return $txt.Substring($bStart + 3, $bEnd - $bStart - 3).Trim()
        }

        $row = [PSCustomObject]@{
            Symbol      = $sym
            TF          = $Period
            Net         = GetVal $txt 'Total Net Profit'
            PF          = GetVal $txt 'Profit Factor'
            Trades      = GetVal $txt 'Total Trades'
            WinPct      = GetVal $txt 'Profit Trades (% of total)'
            AvgWin      = GetVal $txt 'Average profit trade'
            AvgLoss     = GetVal $txt 'Average loss trade'
            EquityDD    = GetVal $txt 'Equity Drawdown Maximal'
            Sharpe      = GetVal $txt 'Sharpe Ratio'
            Recovery    = GetVal $txt 'Recovery Factor'
        }
        $results += $row
        Write-Host "  $sym : Net=$($row.Net) | PF=$($row.PF) | Trades=$($row.Trades) | DD=$($row.EquityDD)" -ForegroundColor Green
    } else {
        Write-Host "  $sym : REPORT MISSING" -ForegroundColor Red
    }
}

Write-Host "`n========== SUMMARY ==========" -ForegroundColor Yellow
$results | Format-Table -AutoSize

# Save CSV for analysis
$csvPath = "C:\SMINDS\Projects\aminds-claude-mt5-robos\results_${Tag}_${Period}.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`nResults saved: $csvPath" -ForegroundColor Cyan
