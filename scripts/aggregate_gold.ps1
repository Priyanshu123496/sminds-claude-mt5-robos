# Aggregate all multi-symbol results into a per-symbol leaderboard for Gold-correlate symbols
$dir = "C:\SMINDS\Projects\aminds-claude-mt5-robos"
$targets = @("XAUUSD","XAGUSD","USDCHF","US30","US500","USTEC")

$rows = @()
Get-ChildItem -Path $dir -Filter "results_*.csv" | ForEach-Object {
    $tag = $_.BaseName -replace '^results_',''
    $data = Import-Csv $_.FullName
    foreach ($r in $data) {
        if ($targets -contains $r.Symbol) {
            $netClean = ($r.Net -replace '\s','' -replace ',','')
            try { $net = [double]$netClean } catch { $net = $null }
            $rows += [PSCustomObject]@{
                EA       = $tag
                Symbol   = $r.Symbol
                TF       = $r.TF
                NetRaw   = $r.Net
                Net      = $net
                PF       = $r.PF
                Trades   = $r.Trades
                WinPct   = $r.WinPct
                EquityDD = $r.EquityDD
                Sharpe   = $r.Sharpe
            }
        }
    }
}

Write-Host "`n========== GOLD-CORRELATE LEADERBOARD ==========" -ForegroundColor Yellow
foreach ($sym in $targets) {
    Write-Host "`n--- $sym ---" -ForegroundColor Cyan
    $rows | Where-Object { $_.Symbol -eq $sym } | Sort-Object Net -Descending |
        Format-Table EA,TF,NetRaw,PF,Trades,WinPct,EquityDD -AutoSize
}

$rows | Export-Csv "$dir\gold_correlate_aggregate.csv" -NoTypeInformation
Write-Host "`nSaved: $dir\gold_correlate_aggregate.csv" -ForegroundColor Green
