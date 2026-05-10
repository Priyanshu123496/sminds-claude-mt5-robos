# Best EAs on Gold-Correlated Symbols — Synthesis Report

**Date:** 2026-05-09
**Test period:** 2026-01-01 → 2026-05-07 (4 months, M15 unless noted)
**Source:** Multi-symbol scans across 16 EAs in the Strategy Factory portfolio

---

## Summary

The single most important finding: **most forex-tuned EAs LOSE money on metals.** Only 2 EAs are profitable on XAUUSD, and only 1 EA in the entire portfolio is profitable on BOTH Gold AND its closest correlate (Silver).

| Rank | EA | XAUUSD | XAGUSD | Cross-asset transfer? |
|---|---|---:|---:|---|
| 1 | **TTR-XI-V12 (fixed-lot, gold-tuned)** | **+$13,940** | hardcoded to XAU | No (symbol-locked) |
| 2 | **SMINDS-RangeBreakRetest V2** | **+$12,799** | **+$2,029** | **YES — only EA profitable on both** |
| 3 | EMA-Stoch V2 | -$4,895 | +$1,230 | Partial (Silver only) |
| 4 | BB-Squeeze | -$7,984 | +$591 | Partial (Silver only) |
| 5 | RSI-MeanRev | -$4,646 | +$459 | Partial (Silver only) |
| 6 | MTC | -$8,919 | +$229 | Partial (Silver only) |
| — | All others (InsideBar, RoundNum, VWAP, Donchian, Pivot, HA-Trend, ESP-M5) | catastrophic | catastrophic | No |

---

## Why most EAs fail on metals

Forex-tuned strategies (InsideBar, RoundNum, VWAP, Pivot, etc.) bleed badly on Gold/Silver because:

1. **Volatility scale.** XAUUSD ATR(14) is 5–10× the ATR of EURUSD. Risk-based sizing at fixed % equity → tiny lots → small wins, large stops.
2. **No volatility-adjusted SL multiplier.** Most EAs use a hardcoded ATR × 1.5–2.0 for SL, calibrated to forex pip ranges. On Gold this often equals $30–100 SL distance — broker stops eat trades.
3. **Different intraday regime.** Gold trades on macro/safe-haven flows, not technical levels. Mean-reversion (RSI, RoundNum, Pivot) is uncorrelated to gold's actual catalyst structure.
4. **Sample size.** 4-month windows on metals can have 1-2 macro-driven directional weeks that overwhelm any tactical edge.

The InsideBar EA — our top forex performer at $9,223 on EURUSD — was -$9,206 on XAUUSD (catastrophic 95% drawdown). Same EA, same period, completely different asset class behavior.

---

## The bridge: SMINDS-RangeBreakRetest V2

This is the only EA in the portfolio that produces **positive** results on **both** XAUUSD and XAGUSD without modification:

- **XAUUSD**: +$12,799, 5 trades, 100% win rate, max DD 19% (small sample but clean)
- **XAGUSD**: +$2,029, 11 trades, 64% win rate, PF 1.31, max DD 37%

The mechanism (range break + retest with hold-candle confirmation) is asset-agnostic — it relies on price structure, not volatility-tuned parameters. That's why it generalizes.

**Caveat — small sample:** XAUUSD result is only 5 trades. Should be re-validated with NP-MC robustness and walk-forward before live deployment on Gold.

---

## Symbol coverage

| Symbol | Status | Notes |
|---|---|---|
| **XAUUSD** | Tested across 13 EAs | 2 winners (TTR-XI-V12, RBR-V2) |
| **XAGUSD** | Tested across 13 EAs | 5 winners; RBR-V2 is best |
| **USDCHF** | Not yet tested | Would require a fresh run (test platform restart needed) |
| **US30** | Not yet tested | Index, may behave like indices not metals |
| **US500** | Not yet tested | Index |
| **USTEC** | Not yet tested | Index |
| **XPTUSD/XPDUSD** | Not available on broker | Would need different broker |
| **BTCUSD/ETHUSD** | Not available on broker | Would need different broker |

---

## Recommendation

**For the Gold-correlate slot in the live portfolio, deploy:**

1. **TTR-XI-V12** on XAUUSD M15 (already deployed, magic 94736312) — the gold specialist.
2. **RangeBreakRetest V2** on XAUUSD M15 + XAGUSD M15 — the only cross-metal EA. Allocate smaller risk on XAUUSD due to small sample (5 trades is too few for robust deployment; treat as exploratory).

**Do not deploy** any forex-tuned EA (InsideBar, EMA-Stoch, RoundNum, Pivot, etc.) on metals. The catastrophic drawdowns aren't worth the rare positive months.

---

## Test platform note

When attempting to expand testing to USDCHF / US30 / US500 / USTEC, the MT5 strategy tester started returning 0-bar / 0-trade reports for ALL EAs (including known-working ones). The agent was disconnecting immediately on connect (status code 2). This indicates the local agent farm has degraded after a long testing session. **Manual MT5 terminal restart is needed before further multi-symbol scans.**

Symbols already covered (XAUUSD, XAGUSD) have rich existing data, so the synthesis above is reliable for the user's question.
