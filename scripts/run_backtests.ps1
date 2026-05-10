# ============================================================
# MT5 Backtest Runner + HTML Report Parser
# Runs V1a_close and TTR-XI-V1a-Improved for both periods,
# then prints a side-by-side comparison table.
# ============================================================

$terminal  = "C:\Program Files\MetaTrader 5\terminal64.exe"
$dataDir   = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$configDir = "$dataDir\config"
$reportDir = $dataDir   # MT5 saves reports here

# ─── Helper: write an INI and wait for its report ──────────────────────
function Run-Backtest {
    param(
        [string]$ExpertPath,   # e.g.  "BLISSFUL MINDS INC. - TTR-XI-V1a_close.ex5"
        [string]$FromDate,     # e.g.  "2026.01.01"
        [string]$ToDate,       # e.g.  "2026.03.31"
        [string]$ReportName,   # unique name, no extension
        [int]$TimeoutSec = 300
    )

    $iniPath    = "$configDir\bt_auto_$ReportName.ini"
    $reportHtm  = "$reportDir\$ReportName.htm"

    # Remove old report if it exists
    if (Test-Path $reportHtm) { Remove-Item $reportHtm -Force }

    # Write INI
    $ini = @"
[Tester]
Expert=$ExpertPath
Symbol=XAUUSD
Period=M15
Model=1
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate=$FromDate
ToDate=$ToDate
ForwardMode=0
Deposit=10000
Currency=USD
Leverage=100
Report=$ReportName
ReplaceReport=1
ShutdownTerminal=0
Visual=0
"@
    Set-Content -Path $iniPath -Value $ini -Encoding ASCII

    Write-Host "  Launching backtest: $ReportName ..." -ForegroundColor Cyan

    # Launch terminal with config (passes config to running instance or starts new)
    Start-Process -FilePath $terminal -ArgumentList "/config:`"$iniPath`"" -WindowStyle Minimized

    # Wait for report to appear
    $elapsed = 0
    while (-not (Test-Path $reportHtm)) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        if ($elapsed -ge $TimeoutSec) {
            Write-Host "  TIMEOUT waiting for $ReportName" -ForegroundColor Red
            return $null
        }
    }
    # Extra wait to ensure file is fully written
    Start-Sleep -Seconds 3

    Write-Host "  Report ready: $ReportName" -ForegroundColor Green
    return $reportHtm
}

# ─── Helper: parse key metrics from MT5 HTML report ────────────────────
function Parse-Report {
    param([string]$HtmlPath)

    if (-not $HtmlPath -or -not (Test-Path $HtmlPath)) {
        return @{ Error = "Report not found: $HtmlPath" }
    }

    $html = Get-Content $HtmlPath -Raw -Encoding UTF8

    function Extract {
        param([string]$label, [string]$src)
        # MT5 reports use patterns like: <td>Net Profit:</td><td>1234.56</td>
        # Try multiple patterns
        $patterns = @(
            "$label[^<]*</td>\s*<td[^>]*>([^<]+)</td>",
            "$label[^<]*</td><td[^>]*>\s*([0-9\-\.\s,]+)"
        )
        foreach ($p in $patterns) {
            if ($src -match $p) {
                return ($Matches[1] -replace '\s+', ' ').Trim()
            }
        }
        return "N/A"
    }

    # Extract expert name
    $expert = "N/A"
    if ($html -match 'Expert:?[^<]*</td>\s*<td[^>]*>([^<]+)</td>') {
        $expert = $Matches[1].Trim()
    }

    $result = @{
        Expert        = $expert
        NetProfit     = Extract "Net Profit" $html
        TotalTrades   = Extract "Total Trades" $html
        ProfitFactor  = Extract "Profit Factor" $html
        MaxDrawdown   = Extract "Equity Drawdown Maximal" $html
        WinRate       = Extract "Profit Trades" $html
        GrossProfit   = Extract "Gross Profit" $html
        GrossLoss     = Extract "Gross Loss" $html
        AvgWin        = Extract "Average Profit Trade" $html
        AvgLoss       = Extract "Average Loss Trade" $html
    }

    # Fallback: scan for table rows
    $rows = [regex]::Matches($html, '<tr[^>]*>\s*<td[^>]*>([^<]+)</td>\s*<td[^>]*>([^<]*)</td>')
    $map = @{}
    foreach ($row in $rows) {
        $k = $row.Groups[1].Value.Trim() -replace ':',''
        $v = $row.Groups[2].Value.Trim()
        $map[$k] = $v
    }

    $fields = @('Net Profit','Total Trades','Profit Factor','Profit Trades (%)','Equity Drawdown Maximal')
    foreach ($f in $fields) {
        foreach ($k in $map.Keys) {
            if ($k -like "*$f*") {
                $short = $f -replace ' ','' -replace '[^a-zA-Z]',''
                if (-not $result.ContainsKey($short) -or $result[$short] -eq 'N/A') {
                    $result[$short] = $map[$k]
                }
            }
        }
    }

    # Also try direct key lookup
    if ($map.ContainsKey('Net Profit')) { $result.NetProfit = $map['Net Profit'] }
    if ($map.ContainsKey('Total Trades')) { $result.TotalTrades = $map['Total Trades'] }
    if ($map.ContainsKey('Profit Factor')) { $result.ProfitFactor = $map['Profit Factor'] }
    if ($map.ContainsKey('Profit Trades (%)')) { $result.WinRate = $map['Profit Trades (%)'] }
    if ($map.ContainsKey('Equity Drawdown Maximal')) { $result.MaxDrawdown = $map['Equity Drawdown Maximal'] }
    if ($map.ContainsKey('Gross Profit')) { $result.GrossProfit = $map['Gross Profit'] }
    if ($map.ContainsKey('Gross Loss')) { $result.GrossLoss = $map['Gross Loss'] }

    return $result
}

# ─── Define the 4 tests ────────────────────────────────────────────────
$tests = @(
    @{
        Label      = "V1a_close  | Q1-2026"
        Expert     = "BLISSFUL MINDS INC. - TTR-XI-V1a_close.ex5"
        From       = "2026.01.01"
        To         = "2026.03.31"
        ReportName = "bt_v1a_close_q1_2026"
    },
    @{
        Label      = "V1a_close  | Apr2026"
        Expert     = "BLISSFUL MINDS INC. - TTR-XI-V1a_close.ex5"
        From       = "2026.04.01"
        To         = "2026.04.09"
        ReportName = "bt_v1a_close_apr_2026"
    },
    @{
        Label      = "Improved   | Q1-2026"
        Expert     = "TTR-XI-V1a-Improved.ex5"
        From       = "2026.01.01"
        To         = "2026.03.31"
        ReportName = "bt_improved_q1_2026"
    },
    @{
        Label      = "Improved   | Apr2026"
        Expert     = "TTR-XI-V1a-Improved.ex5"
        From       = "2026.04.01"
        To         = "2026.04.09"
        ReportName = "bt_improved_apr_2026"
    }
)

# ─── Run all tests ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== MT5 Backtest Runner ===" -ForegroundColor Yellow
Write-Host "Terminal: $terminal"
Write-Host "Data Dir: $dataDir"
Write-Host ""

$reports = @{}
foreach ($t in $tests) {
    $path = Run-Backtest `
        -ExpertPath  $t.Expert `
        -FromDate    $t.From `
        -ToDate      $t.To `
        -ReportName  $t.ReportName `
        -TimeoutSec  600
    $reports[$t.Label] = $path
    Start-Sleep -Seconds 2
}

# ─── Parse and display results ─────────────────────────────────────────
Write-Host ""
Write-Host "=== RESULTS ===" -ForegroundColor Yellow
Write-Host ("{0,-25} {1,12} {2,8} {3,8} {4,10} {5,10}" -f "Test", "Net Profit", "Trades", "Win%", "Prof.Factor", "MaxDD%")
Write-Host ("-" * 80)

$resultsData = @{}

foreach ($t in $tests) {
    $path = $reports[$t.Label]
    $m = Parse-Report -HtmlPath $path
    $resultsData[$t.Label] = $m
    $profitStr = if ($m.NetProfit -ne 'N/A') { $m.NetProfit } else { "N/A" }
    Write-Host ("{0,-25} {1,12} {2,8} {3,8} {4,10} {5,10}" -f `
        $t.Label, $profitStr, $m.TotalTrades, $m.WinRate, $m.ProfitFactor, $m.MaxDrawdown)
}

# ─── Save results to JSON for further processing ───────────────────────
$jsonPath = "C:\SMINDS\Projects\aminds-claude-mt5-robos\backtest_results.json"
$resultsData | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8
Write-Host ""
Write-Host "Results saved to: $jsonPath" -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
