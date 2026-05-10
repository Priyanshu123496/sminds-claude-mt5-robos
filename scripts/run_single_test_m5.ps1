# Run a single MT5 backtest by writing INI and waiting for report
# Usage: .\run_single_test.ps1 -ExpertFile "..." -From "2026.04.01" -To "2026.04.09" -ReportName "bt_xxx"

param(
    [string]$ExpertFile  = "BLISSFUL MINDS INC. - TTR-XI-V1a_close.ex5",
    [string]$From        = "2026.04.01",
    [string]$To          = "2026.04.09",
    [string]$ReportName  = "bt_test_apr",
    [int]   $TimeoutSec  = 600,
    [string]$Model       = "1"
)

$terminal  = "C:\Program Files\MetaTrader 5\terminal64.exe"
$dataDir   = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$configDir = "$dataDir\config"
$reportHtm = "$dataDir\$ReportName.htm"
$iniPath   = "$configDir\bt_single_$ReportName.ini"

# Kill any lingering terminal64 instances so we start clean
Get-Process terminal64 -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Killing lingering terminal64 PID $($_.Id)" -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# Remove stale report
if (Test-Path $reportHtm) {
    Remove-Item $reportHtm -Force
    Write-Host "Removed old report: $reportHtm" -ForegroundColor Yellow
}

# Write INI
$ini = @"
[Tester]
Expert=$ExpertFile
Symbol=XAUUSD
Period=M5
Model=$Model
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate=$From
ToDate=$To
ForwardMode=0
Deposit=10000
Currency=USD
Leverage=100
Report=$ReportName
ReplaceReport=1
ShutdownTerminal=1
Visual=0
"@
Set-Content -Path $iniPath -Value $ini -Encoding ASCII
Write-Host "INI written: $iniPath" -ForegroundColor Cyan

# Launch terminal with config
Write-Host "Launching: $ExpertFile  [$From -> $To]" -ForegroundColor Cyan
$proc = Start-Process -FilePath $terminal -ArgumentList "/config:`"$iniPath`"" -WindowStyle Minimized -PassThru
Write-Host "Terminal PID: $($proc.Id)"

# Wait for report
$elapsed = 0
Write-Host "Waiting for report: $reportHtm" -ForegroundColor Cyan
while (-not (Test-Path $reportHtm)) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    Write-Host "  ... $elapsed sec elapsed"
    if ($elapsed -ge $TimeoutSec) {
        Write-Host "TIMEOUT after ${TimeoutSec}s waiting for: $ReportName" -ForegroundColor Red
        exit 1
    }
}

Start-Sleep -Seconds 3  # let file finish writing
Write-Host "Report ready: $reportHtm" -ForegroundColor Green

# Parse key metrics
$html = Get-Content $reportHtm -Raw -Encoding UTF8

$rows = [regex]::Matches($html, '<tr[^>]*>\s*<td[^>]*>([^<]+)</td>\s*<td[^>]*>([^<]*)</td>')
$map = @{}
foreach ($r in $rows) {
    $k = ($r.Groups[1].Value -replace ':','').Trim()
    $v = $r.Groups[2].Value.Trim()
    if ($v -ne '' -and -not $map.ContainsKey($k)) { $map[$k] = $v }
}

function G($k) {
    $keys = @($k) + @($map.Keys | Where-Object { $_ -like "*$k*" })
    foreach ($x in $keys) { if ($map.ContainsKey($x)) { return $map[$x] } }
    return 'N/A'
}

Write-Host ""
Write-Host "=== RESULTS: $ReportName ===" -ForegroundColor Yellow
Write-Host "  Expert      : $(G 'Expert')"
Write-Host "  Period      : $From to $To"
Write-Host "  Net Profit  : $(G 'Total Net Profit')"
Write-Host "  Trades      : $(G 'Total Trades')"
Write-Host "  Win Rate    : $(G 'Profit Trades (%)')"
Write-Host "  Profit Fac. : $(G 'Profit Factor')"
Write-Host "  Max DD      : $(G 'Equity Drawdown Maximal')"
Write-Host "  Gross Profit: $(G 'Gross Profit')"
Write-Host "  Gross Loss  : $(G 'Gross Loss')"
Write-Host "  Avg Win     : $(G 'Average Profit Trade')"
Write-Host "  Avg Loss    : $(G 'Average Loss Trade')"
Write-Host ""

# Output CSV line for easy comparison
Write-Host "CSV: $ReportName,$From,$To,$(G 'Total Net Profit'),$(G 'Total Trades'),$(G 'Profit Trades (%)'),$(G 'Profit Factor'),$(G 'Equity Drawdown Maximal')"

