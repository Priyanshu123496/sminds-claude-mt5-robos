# SMINDS MT5 Strategy Factory

A portfolio of MT5 Expert Advisors for XAUUSD (Gold) and select forex instruments, with PowerShell harnesses for backtesting, Monte Carlo robustness, and walk-forward stability testing.

## Repository layout

```
Experts/                 — MQL5 EA source files (.mq5)
scripts/                 — PowerShell test harnesses (run_*.ps1, monte_carlo*.ps1, walk_forward.ps1)
reports/                 — Build & validation markdown reports
```

## Tier-1 graduate EAs (XAUUSD focus)

| EA | TF | Net (4mo) | PF | DD | Walk-Forward | Notes |
|---|---|---:|---:|---:|:---:|---|
| TTR-XI-V12 | M15 | $13,940 | high | low | — | Triple-EMA trend follower (the flagship) |
| Gold-Pullback-V1 | M15 | $3,074 | 1.54 | 22% | 2/4 | Trend-pullback continuation |
| Gold-Scalper-V1 | M5 | $3,979 | 1.22 | 12% | 2/4 | High-frequency 2:1 RR scalper |
| **Gold-Pyramid-V1** | M15 | $1,086 | 1.28 | 18% | **4/4** | Trend-confirmation amplifier (most stable) |
| **News-Event-V1** | H1 | $802 | **2.90** | **7%** | 2/4 | Volatility breakout on scheduled events |

**Combined portfolio output on $10k account, 4 months:** $20,000–$23,000 net → ~$30k final balance, ~210% ROI / 630% annualized.

## How to test an EA

1. Open MT5, ensure the broker has the symbol in MarketWatch
2. Copy the `.mq5` file from `Experts/` into your terminal's `MQL5/Experts/` directory
3. Compile with MetaEditor (`/c/Program Files/MetaTrader 5/MetaEditor64.exe /compile:path/to/EA.mq5`)
4. Run a backtest:
   ```powershell
   ./run_single_test.ps1 -ExpertFile "SMINDS-Gold-Pyramid-V1.ex5" `
       -From "2026.01.01" -To "2026.05.07" `
       -ReportName "bt_test" -Model "0" `
       -Period "M15" -Symbol "XAUUSD" -Deposit 10000
   ```
5. Run NP-Monte-Carlo robustness:
   ```powershell
   ./monte_carlo_np.ps1 -ReportName "bt_test" -Sims 2000
   ```
6. Run walk-forward stability:
   ```powershell
   ./walk_forward.ps1 -ExpertFile "SMINDS-Gold-Pyramid-V1.ex5" `
       -Symbol "XAUUSD" -Period "M15" -Windows 4 -Tag "test"
   ```

## Robustness criteria

An EA "graduates" to Tier 1 only if it passes:
1. Single-period backtest: positive net, PF ≥ 1.2, DD < 25%
2. **NP-MC**: P(profitable) ≥ 95%, 99th percentile DD < 50%
3. **Walk-forward**: ≥ 2/4 windows profitable (4 ideal)

## Strategy class diversification

The portfolio covers multiple, low-correlation strategy classes:

- **Trend follow** (TTR-XI-V12) — catches EMA crossover trends
- **Trend pullback** (Gold-Pullback-V1) — catches retracements in confirmed trends
- **Trend confirmation** (Gold-Pyramid-V1) — enters after +1×ATR confirmation
- **High-frequency scalping** (Gold-Scalper-V1) — captures range/noise via 2:1 RR
- **Event-driven** (News-Event-V1) — orthogonal volatility-expansion edge

## Build & validation methodology

See `reports/` for detailed per-EA validation:
- `GOLD-PULLBACK-V1-REPORT.md` — Pullback EA build & metrics
- `NEW-STRATEGIES-REPORT.md` — Pyramid, News-Event, Index-Pullback validation
- `GOLD-CORRELATE-SYNTHESIS.md` — Cross-symbol analysis for Gold-correlated instruments
