# Forward-Test Deployment Guide

3–4 week forward test of the Tier-1 EA portfolio on a fresh system.

---

## TL;DR — single command for the new system

Open PowerShell on the new system (run as your user, NOT as admin) and paste:

```powershell
# Clone the repo + run automated setup
cd $env:USERPROFILE\Documents
git clone https://github.com/Priyanshu123496/sminds-claude-mt5-robos.git
cd sminds-claude-mt5-robos
.\scripts\setup_forward_test.ps1
```

The script will:
1. Auto-detect your MT5 install
2. Copy all 13 Tier-1 EA source files into `MQL5\Experts\`
3. Compile them via MetaEditor
4. Print the chart-attachment checklist for you to follow

---

## If you're using Claude on the new system

Paste this single prompt to Claude:

> Clone https://github.com/Priyanshu123496/sminds-claude-mt5-robos.git into
> `%USERPROFILE%\Documents`, then run `scripts\setup_forward_test.ps1` from
> the repo. It auto-detects MT5 and stages all Tier-1 EAs. After it finishes,
> open MT5 and walk me through attaching each EA to its chart per the
> printed checklist. The full deployment guide is in DEPLOYMENT-GUIDE.md.

Claude will execute the setup and guide you through GUI steps.

---

## Prerequisites on the new system

| Item | How to check / install |
|---|---|
| **MT5 installed** | Download from broker website (e.g., MetaQuotes Demo, OANDA) |
| **MT5 logged in once** | Open MT5, login to broker (creates the data folder) |
| **Git installed** | `git --version` — install from git-scm.com if missing |
| **PowerShell ≥ 5.1** | Built into Windows 10/11 |
| **Algo Trading enabled** | MT5 → Tools → Options → Expert Advisors → ✓ Allow Algo Trading |

---

## Account configuration

| Setting | Value |
|---|---|
| Type | **Demo** (for forward test) |
| Starting balance | **$10,000 USD** |
| Leverage | **1:100 minimum**, 1:500 ideal for Gold |
| Currency | USD |
| Hedging | **Enabled** (required — multiple EAs may take opposite XAU positions) |
| Server | Any broker with XAUUSD + EURUSD + GBPUSD + USDCAD + USDJPY |

**Recommended brokers** (have all symbols, retail-friendly): OANDA, MetaQuotes-Demo, IC Markets Demo, Pepperstone Demo.

---

## EA chart attachment — full table

After `setup_forward_test.ps1` runs, attach these EAs to charts.

### Gold cluster (5 charts on XAUUSD)

| # | Symbol | TF | EA | Magic | Role |
|---|---|---|---|---:|---|
| 1 | XAUUSD | M15 | TTR-XI-V1a-prod-ready-v12 | 94736312 | Trend follower (flagship) |
| 2 | XAUUSD | M15 | SMINDS-Gold-Pullback-V1 | 94736330 | Pullback continuation |
| 3 | XAUUSD | M15 | SMINDS-Gold-Pyramid-V1 | 94736350 | Trend confirmation amplifier |
| 4 | XAUUSD | M5 | SMINDS-Gold-Scalper-V1 | 94736340 | High-frequency scalper |
| 5 | XAUUSD | H1 | SMINDS-News-Event-V1 | 94736360 | Event-driven volatility |

### Forex cluster (8 charts on various pairs)

| # | Symbol | TF | EA | Magic | Role |
|---|---|---|---|---:|---|
| 6 | USDCAD | M15 | SMINDS-EMA-Stoch-Pullback-V1 | 96200001 | Forex pullback |
| 7 | EURUSD | M15 | SMINDS-London-Breakout-V1 | 96400001 | London open breakout |
| 8 | GBPUSD | M15 | SMINDS-BB-Squeeze-V1 | 96500001 | Bollinger squeeze |
| 9 | EURUSD | M15 | SMINDS-RangeBreakRetest-V1 | 97000001 | Range break + retest |
| 10 | EURUSD | M15 | SMINDS-InsideBar-V1 | 97400001 | Inside bar (3% risk) |
| 11 | EURUSD | M15 | SMINDS-CCI-Reversal-V1 | 97500001 | CCI extreme |
| 12 | GBPUSD | M15 | SMINDS-Pivot-V1 | 97600001 | Daily pivot reversion |
| 13 | EURUSD | M15 | SMINDS-RoundNum-V1 | 97300001 | Round-number rejection |

**Total: 13 charts.** Margin used at peak ≈ $3,500 on $10k account (35%).

### How to attach each EA

For each row in the table above:

1. **File → New Chart → [Symbol]** (e.g., XAUUSD)
2. Set timeframe via the toolbar buttons: M5 / M15 / H1 etc.
3. In the left **Navigator** panel, expand **Expert Advisors**
4. **Drag the EA name** onto the chart
5. In the popup dialog, switch to the **Common** tab:
   - ✓ Allow Algo Trading
   - ✓ Allow modification of Signal settings (if available)
6. Click **OK**
7. Verify the **smiley face** ☺ appears in the chart's top-right corner (this means the EA is running)
8. **A frowning face** ☹ means algo trading is disabled — toggle the AutoTrading button in the main toolbar

### Per-EA input verification

Most EAs use their compiled defaults (correct for the test period). Two exceptions:
- **SMINDS-InsideBar-V1**: confirm `InpRiskPercent = 3.0` in the Inputs tab when attaching
- **SMINDS-CCI-Reversal-V1**: confirm `InpRiskPercent = 2.5` in the Inputs tab

---

## Monitoring during the forward test

### Daily checks (5 min)
- **Terminal → Trade** tab: any open positions, are they correctly tagged with EA magic numbers?
- **Terminal → Experts** tab: any errors logged? Failed orders?
- **Account balance/equity**: track in a spreadsheet or just screenshot daily

### Weekly checks (15 min)
- **Trade History**: filter by magic number, compute per-EA PnL for the week
- Check drawdown: if any single EA exceeds 15% individual DD, consider reducing its lot size
- Verify all 13 EAs still have a smiley face (terminal restarts kill EAs!)

### Red flags — stop the forward test
- Any single trade losing > 3% of account
- Combined account DD > 25%
- Broker spreads consistently > 100 points on Gold (means bad broker / bad time)
- Any EA generating errors in Experts log

---

## Expected outcome over 3-4 weeks

Based on the Jan-May 2026 backtest scaled to 3-4 weeks:

| Metric | Expected range |
|---|---:|
| Net profit | $4,000 – $7,000 |
| Final balance | $14,000 – $17,000 |
| Worst drawdown | $1,500 – $2,500 (15-25%) |
| Total trades | 80 – 150 |

**Live performance always underperforms backtest by 15-30%** due to slippage, broker spread variance, missed bars, and regime mismatch.

If live PnL is **within 50% of expected** → strategy is healthy, scale up
If live PnL is **negative or < 30% of expected** → likely regime mismatch, investigate per-EA

---

## At end of forward test (3-4 weeks)

Open a new Claude session and ask:

> Analyze the forward-test results from MT5. Pull the trade history from the
> Experts tab, group by magic number, compute per-EA win rate, PF, max DD,
> and total PnL. Compare to backtest projections. Recommend which EAs to
> scale up, which to pause, and which to retire.

Claude will read MT5's report HTML/CSV exports and produce the analysis.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Compile errors after pull | `git pull origin main` to get latest source |
| EA shows ☹ on chart | AutoTrading button (top toolbar) — click to enable |
| "Trade context busy" errors | Broker conflict — one of the EAs is on a non-hedging account |
| 0 trades after 24h | Check Experts log for symbol/TF guard rejections |
| Margin call | Reduce all EA lot sizes by 50% (edit inputs on each chart) |

---

## Repo

https://github.com/Priyanshu123496/sminds-claude-mt5-robos
