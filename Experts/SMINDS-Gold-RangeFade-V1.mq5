//+------------------------------------------------------------------+
//|                                  SMINDS-Gold-RangeFade-V1.mq5    |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Counter-trend mean reversion EA for XAUUSD M15.                 |
//|  DESIGNED AS A PORTFOLIO DIVERSIFIER TO TTR-XI-V12.              |
//|                                                                  |
//|  Strategy thesis:                                                |
//|    TTR-XI-V12 trades only when ADX > 25 (trending). This EA      |
//|    trades only when ADX < 20 (ranging). Their PnL streams should |
//|    be lowly correlated, smoothing the combined equity curve.     |
//|                                                                  |
//|  Why prior Gold mean-rev EAs failed (RSI-MeanRev -$4,646;        |
//|  VWAP-Reversion -$9,758; RoundNum -$8,974) and what's different: |
//|    (a) Regime gate is HARD: ADX<20 AND flat EMA200 slope         |
//|    (b) Requires real dislocation: close > 2×ATR from EMA20       |
//|    (c) Reversal candle confirmation (engulfing or pin bar)       |
//|    (d) Vol-spike filter (avoid macro-driven days)                |
//|    (e) Tight SL just beyond candle extreme + 0.5×ATR buffer      |
//|    (f) High-probability TP: return to EMA20 OR 1.5×ATR           |
//|    (g) Time-stop after 16 bars (mean rev should be quick)        |
//|                                                                  |
//|  Risk controls (same battle-tested suite as TTR-XI-V12):         |
//|    1. Regime gate, stretch, candle, vol — entry quality          |
//|    2. Tight SL = candle extreme + 0.5×ATR                        |
//|    3. Time-stop at 16 bars                                       |
//|    4. Post-loss cooldown (4 M15 bars)                            |
//|    5. Consecutive-loss circuit breaker (halt for the day)        |
//|    6. Daily loss limit (3% equity)                               |
//|    7. Dynamic position sizing (halve at 15% DD, restore at 5%)   |
//|    8. Spread guard, broker stops-level enforcement               |
//|                                                                  |
//|  Persistence: peak equity, consecutive losses, breaker day are   |
//|    persisted via GlobalVariables (survives restarts).            |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Gold-RangeFade V1 — counter-trend mean reversion"
#property description "XAUUSD M15 — designed to diversify TTR-XI-V12"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Strategy Identification ════════════════════════"
input long   InpMagicNumber       = 94736325;        // Magic (distinct from TTR-XI-V12=94736312)
input string InpOrderComment      = "GRF-V1";        // Order comment

input group "═══ Symbol / Timeframe Guard ══════════════════════"
input bool   InpRequireXAUUSD     = true;            // Reject if symbol is not XAU/Gold
input bool   InpRequireM15        = true;            // Reject if timeframe is not M15

input group "═══ Mean / Volatility Indicators ══════════════════"
input int    InpEMAMeanPeriod     = 20;              // EMA used as mean (target)
input int    InpEMAFilterPeriod   = 200;             // EMA200 for macro slope check
input int    InpATRPeriod         = 14;              // ATR for SL/stretch sizing
input int    InpATRBaselinePeriod = 50;              // Long ATR baseline

input group "═══ Regime Gate (HARD — must be range-bound) ══════"
input bool   InpUseADXGate        = true;            // Require ADX < threshold (range market)
input int    InpADXPeriod         = 14;              // ADX period
input double InpMaxADX            = 25.0;            // ADX must be < this to trade
input bool   InpUseMacroFlat      = true;            // Require flat EMA200 slope
input int    InpMacroSlopeBars    = 24;              // EMA200 slope lookback (bars)
input double InpMaxMacroSlopeATR  = 1.5;             // |slope|/ATR must be < this

input group "═══ Stretch Detection ═════════════════════════════"
input double InpMinStretchATR     = 1.5;             // wick must reach ≥ this × ATR from EMA20

input group "═══ Reversal Candle Confirmation ═════════════════"
input bool   InpUseEngulfing      = true;            // Accept bullish/bearish engulfing
input bool   InpUsePinBar         = true;            // Accept pin bar (long-wick rejection)
input double InpPinWickRatio      = 0.50;            // wick must be ≥ this fraction of range
input double InpPinBodyRatio      = 0.30;            // body must be ≤ this fraction of range

input group "═══ Vol-Spike Filter ════════════════════════════"
input bool   InpUseVolFilter      = true;            // Skip when ATR/baseline too high
input double InpMaxATRRatio       = 1.5;             // Reject if ATR > baseline × this

input group "═══ Stops / Targets ═══════════════════════════════"
input double InpSLBufferATR       = 0.3;             // SL = swing extreme ± this × ATR
input double InpSLMaxATR          = 1.2;             // Cap SL distance to ≤ this × ATR (RR safety)
input double InpMinRR             = 0.8;             // Skip trade if expected RR (TP/SL) < this
input bool   InpTPAtMean          = true;            // Primary TP = EMA20 (mean reversion target)
input double InpTPFallbackATR     = 1.5;             // If TPAtMean off, use this × ATR target

input group "═══ Time Stop / Regime Exit ════════════════════"
input bool   InpUseTimeStop       = false;           // Close if held too long (default OFF — let TP/SL run)
input int    InpMaxHoldBars       = 32;              // 32 × M15 = 8 hours
input bool   InpUseRegimeExit     = false;           // Close if ADX surges (default OFF — let TP/SL run)

input group "═══ Position Sizing ═══════════════════════════════"
input double InpLotSize           = 0.10;            // Base lot size
input double InpMinLotSize        = 0.01;            // Hard floor
input double InpMaxLotSize        = 1.00;            // Hard cap

input group "═══ Dynamic Lot Sizing (DD Guard) ═════════════════"
input bool   InpUseDynLots        = true;            // Enable dynamic lot reduction
input double InpDDHalvePercent    = 15.0;            // Halve when DD ≥ this %
input double InpDDRestorePercent  = 5.0;             // Restore when DD < this %

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSessionFilter  = true;            // Restrict to active hours
input int    InpSessionStartHour  = 7;               // Session open (UTC)
input int    InpSessionEndHour    = 20;              // Session close (UTC)

input group "═══ Risk Circuit Breakers ═══════════════════════"
input bool   InpUseDailyLossLimit = true;            // Halt on daily loss
input double InpMaxDailyLossPct   = 3.0;             // Max daily loss % of start-of-day balance
input bool   InpUseCooldown       = true;            // Cooldown after a loss
input int    InpCooldownBars      = 4;               // Cooldown duration (M15 bars)
input bool   InpUseLossBreaker    = true;            // Halt after N consecutive losses
input int    InpMaxConsecLosses   = 2;               // Trip threshold

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 50;              // Skip entry if spread > this (0=disabled)
input int    InpSlippagePoints    = 30;              // Max acceptable slippage on market orders
input int    InpMaxRetries        = 3;               // Retry attempts for trade ops
input int    InpRetryDelayMs      = 500;             // Delay between retries

input group "═══ Diagnostics ═════════════════════════════════"
input bool   InpVerboseLogging    = false;           // Log every filter rejection (noisy)

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG          "GRF-V1"
#define GV_PREFIX       "GRFV1_"

CTrade        g_trade;
CSymbolInfo   g_sym;

int  g_h_ema_mean   = INVALID_HANDLE;
int  g_h_ema_filter = INVALID_HANDLE;
int  g_h_atr        = INVALID_HANDLE;
int  g_h_atr_base   = INVALID_HANDLE;
int  g_h_adx        = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;

// Persisted state
string g_gv_peak;
string g_gv_consec;
string g_gv_breaker;
string g_gv_balance;

double   g_peak_equity     = 0.0;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;
double   g_last_balance    = 0.0;

// Volatile per-bar state
datetime g_last_bar              = 0;
bool     g_last_trade_was_loss   = false;
int      g_bars_since_loss       = 9999;
bool     g_lots_halved           = false;
datetime g_today                 = 0;
double   g_daily_start_bal       = 0.0;
ulong    g_open_position_ticket  = 0;
datetime g_open_position_time    = 0;

//+------------------------------------------------------------------+
//| Logging helpers                                                   |
//+------------------------------------------------------------------+
void LogInfo(string msg)
{
   PrintFormat("[%s] %s", EA_TAG, msg);
}
void LogError(string msg)
{
   PrintFormat("[%s] ERROR: %s", EA_TAG, msg);
}
void LogVerbose(string msg)
{
   if(InpVerboseLogging) PrintFormat("[%s] %s", EA_TAG, msg);
}

//+------------------------------------------------------------------+
//| State persistence                                                 |
//+------------------------------------------------------------------+
void StateSave()
{
   GlobalVariableSet(g_gv_peak,    g_peak_equity);
   GlobalVariableSet(g_gv_consec,  (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)g_breaker_day);
   GlobalVariableSet(g_gv_balance, g_last_balance);
}
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_peak))    g_peak_equity   = GlobalVariableGet(g_gv_peak);
   else                                  g_peak_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(g_gv_consec))  g_consec_losses = (int)GlobalVariableGet(g_gv_consec);
   if(GlobalVariableCheck(g_gv_breaker)) g_breaker_day   = (datetime)(long)GlobalVariableGet(g_gv_breaker);
   if(GlobalVariableCheck(g_gv_balance)) g_last_balance  = GlobalVariableGet(g_gv_balance);
   else                                  g_last_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//| Indicator value fetchers                                          |
//+------------------------------------------------------------------+
double Get1(int handle, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
}
bool GetN(int handle, int shift, int count, double &out[])
{
   ArraySetAsSeries(out, true);
   return CopyBuffer(handle, 0, shift, count, out) == count;
}

//+------------------------------------------------------------------+
//| Position size with dynamic DD halving                             |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double mn   = MathMax(g_sym.LotsMin(), InpMinLotSize);
   double mx   = MathMin(g_sym.LotsMax(), InpMaxLotSize);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   return NormalizeDouble(lot, 2);
}

double ComputeLot()
{
   double lot = InpLotSize;

   if(InpUseDynLots)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_peak_equity = MathMax(g_peak_equity, equity);
      double dd_pct = (g_peak_equity > 0) ? 100.0 * (g_peak_equity - equity) / g_peak_equity : 0.0;

      // hysteresis
      if(!g_lots_halved && dd_pct >= InpDDHalvePercent)
      {
         g_lots_halved = true;
         LogInfo(StringFormat("DD %.2f%% ≥ %.1f%% — halving lots", dd_pct, InpDDHalvePercent));
      }
      else if(g_lots_halved && dd_pct < InpDDRestorePercent)
      {
         g_lots_halved = false;
         LogInfo(StringFormat("DD %.2f%% < %.1f%% — restoring lots", dd_pct, InpDDRestorePercent));
      }
      if(g_lots_halved) lot *= 0.5;
   }

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Reversal candle detection                                         |
//+------------------------------------------------------------------+
bool IsBullishReversal(double o, double h, double l, double c,
                       double prev_o, double prev_c)
{
   double range = h - l;
   if(range <= 0) return false;
   double body = MathAbs(c - o);

   // Bullish engulfing
   if(InpUseEngulfing)
   {
      if(prev_c < prev_o && c > o && c >= prev_o && o <= prev_c)
         return true;
   }
   // Bullish pin bar (long lower wick, small body, close in upper half)
   if(InpUsePinBar)
   {
      double lower_wick = MathMin(o, c) - l;
      if(lower_wick / range >= InpPinWickRatio &&
         body / range <= InpPinBodyRatio &&
         c > (l + range * 0.5))
         return true;
   }
   return false;
}

bool IsBearishReversal(double o, double h, double l, double c,
                       double prev_o, double prev_c)
{
   double range = h - l;
   if(range <= 0) return false;
   double body = MathAbs(c - o);

   // Bearish engulfing
   if(InpUseEngulfing)
   {
      if(prev_c > prev_o && c < o && c <= prev_o && o >= prev_c)
         return true;
   }
   // Bearish pin bar (long upper wick, small body, close in lower half)
   if(InpUsePinBar)
   {
      double upper_wick = h - MathMax(o, c);
      if(upper_wick / range >= InpPinWickRatio &&
         body / range <= InpPinBodyRatio &&
         c < (h - range * 0.5))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Filter checks                                                     |
//+------------------------------------------------------------------+
bool InSession(datetime t)
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(t, dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spr <= InpMaxSpreadPoints;
}

bool RegimeRanging()
{
   if(InpUseADXGate)
   {
      double adx = Get1(g_h_adx, 1);
      if(adx >= InpMaxADX)
      {
         LogVerbose(StringFormat("Regime reject — ADX=%.1f ≥ %.1f", adx, InpMaxADX));
         return false;
      }
   }
   if(InpUseMacroFlat)
   {
      double f[];
      if(!GetN(g_h_ema_filter, 1, InpMacroSlopeBars + 1, f))
      {
         LogVerbose("Regime reject — could not read EMA200");
         return false;
      }
      double slope = f[0] - f[InpMacroSlopeBars];
      double atr   = Get1(g_h_atr, 1);
      if(atr <= 0)
      {
         LogVerbose("Regime reject — ATR<=0");
         return false;
      }
      double ratio = MathAbs(slope) / atr;
      if(ratio >= InpMaxMacroSlopeATR)
      {
         LogVerbose(StringFormat("Regime reject — |EMA200 slope|/ATR=%.2f ≥ %.2f", ratio, InpMaxMacroSlopeATR));
         return false;
      }
   }
   return true;
}

bool VolOK()
{
   if(!InpUseVolFilter) return true;
   double atr  = Get1(g_h_atr, 1);
   double base = Get1(g_h_atr_base, 1);
   if(base <= 0) return false;
   double r = atr / base;
   if(r >= InpMaxATRRatio)
   {
      LogVerbose(StringFormat("Vol reject — ATR/baseline=%.2f ≥ %.2f", r, InpMaxATRRatio));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Risk gates                                                        |
//+------------------------------------------------------------------+
bool DailyLossOK()
{
   if(!InpUseDailyLossLimit) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today)
   {
      g_today           = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   double cur_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss_pct = 100.0 * (g_daily_start_bal - cur_bal) / MathMax(g_daily_start_bal, 0.01);
   if(loss_pct >= InpMaxDailyLossPct)
   {
      LogVerbose(StringFormat("Daily-loss halt — loss=%.2f%% ≥ %.1f%%", loss_pct, InpMaxDailyLossPct));
      return false;
   }
   return true;
}

bool BreakerOK()
{
   if(!InpUseLossBreaker) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(g_breaker_day == today)
   {
      LogVerbose("Loss-breaker active for today");
      return false;
   }
   return true;
}

bool CooldownOK()
{
   if(!InpUseCooldown) return true;
   if(g_last_trade_was_loss && g_bars_since_loss < InpCooldownBars)
   {
      LogVerbose(StringFormat("Cooldown — %d/%d bars", g_bars_since_loss, InpCooldownBars));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Position management                                               |
//+------------------------------------------------------------------+
bool HaveOurPosition(ulong &ticket_out)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ticket_out = t;
      return true;
   }
   return false;
}

void ClosePositionByTicket(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return;
   for(int retry = 0; retry < InpMaxRetries; retry++)
   {
      if(g_trade.PositionClose(ticket, InpSlippagePoints))
      {
         LogInfo(StringFormat("CLOSE %s — %s", (string)ticket, reason));
         return;
      }
      Sleep(InpRetryDelayMs);
   }
   LogError(StringFormat("Failed to close %s — %s", (string)ticket, reason));
}

void OpenPosition(bool is_long, double entry_ref, double sl, double tp, double lot)
{
   double stops_lvl_pts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = g_sym.Point();
   double min_dist = stops_lvl_pts * pt;

   if(is_long)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // enforce broker stops level
      if(ask - sl < min_dist)
      {
         LogVerbose(StringFormat("Adjust SL — too tight (need %.2fpts)", min_dist/pt));
         sl = ask - min_dist - pt;
      }
      if(tp - bid < min_dist)
      {
         tp = bid + min_dist + pt;
      }
      for(int retry = 0; retry < InpMaxRetries; retry++)
      {
         if(g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("BUY %.2f @ %.5f SL=%.5f TP=%.5f ref=%.5f", lot, ask, sl, tp, entry_ref));
            return;
         }
         Sleep(InpRetryDelayMs);
      }
      LogError("BUY failed after retries");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(sl - bid < min_dist)
      {
         LogVerbose(StringFormat("Adjust SL — too tight (need %.2fpts)", min_dist/pt));
         sl = bid + min_dist + pt;
      }
      if(ask - tp < min_dist)
      {
         tp = ask - min_dist - pt;
      }
      for(int retry = 0; retry < InpMaxRetries; retry++)
      {
         if(g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("SELL %.2f @ %.5f SL=%.5f TP=%.5f ref=%.5f", lot, bid, sl, tp, entry_ref));
            return;
         }
         Sleep(InpRetryDelayMs);
      }
      LogError("SELL failed after retries");
   }
}

//+------------------------------------------------------------------+
//| Trade close detection (track PnL of last closed deal)             |
//+------------------------------------------------------------------+
void CheckLastClosedTradePnL()
{
   if(!HistorySelect(TimeCurrent() - 7*24*60*60, TimeCurrent() + 60))
      return;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(t <= g_open_position_time && g_open_position_time != 0) break;

      double profit = HistoryDealGetDouble(d, DEAL_PROFIT)
                    + HistoryDealGetDouble(d, DEAL_SWAP)
                    + HistoryDealGetDouble(d, DEAL_COMMISSION);

      if(profit < 0)
      {
         g_consec_losses++;
         g_last_trade_was_loss = true;
         g_bars_since_loss = 0;
         LogInfo(StringFormat("LOSS recorded — %.2f, consec=%d", profit, g_consec_losses));
         if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
         {
            g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
            LogInfo(StringFormat("BREAKER tripped — halting today after %d consec losses", g_consec_losses));
         }
      }
      else
      {
         g_consec_losses = 0;
         g_last_trade_was_loss = false;
         LogInfo(StringFormat("WIN recorded — %.2f", profit));
      }
      g_open_position_time = 0;
      g_open_position_ticket = 0;
      StateSave();
      break;
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   // ── Symbol / TF guards ──
   string up = _Symbol;
   StringToUpper(up);
   if(InpRequireXAUUSD && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   {
      LogError(StringFormat("Symbol %s is not XAUUSD/Gold — strategy is gold-only", _Symbol));
      return INIT_FAILED;
   }
   if(InpRequireM15 && g_tf != PERIOD_M15)
   {
      LogError("Timeframe must be M15 — strategy was tuned for M15");
      return INIT_FAILED;
   }

   if(!g_sym.Name(_Symbol)) { LogError("CSymbolInfo init failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)) { LogError("SymbolSelect failed"); return INIT_FAILED; }

   // ── Sanity ──
   if(InpEMAMeanPeriod >= InpEMAFilterPeriod) { LogError("EMA periods invalid"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDDHalvePercent <= InpDDRestorePercent) { LogError("DD hysteresis invalid"); return INIT_PARAMETERS_INCORRECT; }
   if(InpSessionStartHour < 0 || InpSessionEndHour > 24 || InpSessionStartHour >= InpSessionEndHour)
   { LogError("Session hours invalid"); return INIT_PARAMETERS_INCORRECT; }
   if(InpLotSize <= 0 || InpMinLotSize <= 0 || InpMaxLotSize < InpMinLotSize)
   { LogError("Lot config invalid"); return INIT_PARAMETERS_INCORRECT; }

   // ── Indicators ──
   g_h_ema_mean   = iMA(_Symbol, g_tf, InpEMAMeanPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_filter = iMA(_Symbol, g_tf, InpEMAFilterPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_atr        = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_atr_base   = iATR(_Symbol, g_tf, InpATRBaselinePeriod);
   g_h_adx        = iADX(_Symbol, g_tf, InpADXPeriod);

   if(g_h_ema_mean   == INVALID_HANDLE ||
      g_h_ema_filter == INVALID_HANDLE ||
      g_h_atr        == INVALID_HANDLE ||
      g_h_atr_base   == INVALID_HANDLE ||
      g_h_adx        == INVALID_HANDLE)
   { LogError("Indicator handle creation failed"); return INIT_FAILED; }

   // ── Trade ──
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // ── Persisted state ──
   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_peak    = StringFormat("%s%lld_%s_peak",    GV_PREFIX, acct, _Symbol);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   g_gv_balance = StringFormat("%s%lld_%s_balance", GV_PREFIX, acct, _Symbol);

   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(g_gv_peak);
      GlobalVariableDel(g_gv_consec);
      GlobalVariableDel(g_gv_breaker);
      GlobalVariableDel(g_gv_balance);
      g_peak_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      g_consec_losses = 0;
      g_breaker_day   = 0;
      g_last_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   else
   {
      StateLoad();
   }

   // ── Init log ──
   LogInfo("─────────── INIT ───────────");
   LogInfo(StringFormat("Symbol/TF      : %s / %s", _Symbol, EnumToString(g_tf)));
   LogInfo(StringFormat("Magic / Comment: %lld / %s", InpMagicNumber, InpOrderComment));
   LogInfo("Strategy       : MEAN-REVERSION (range-bound regime only)");
   LogInfo(StringFormat("Regime gate    : ADX<%.0f, |EMA200 slope|/ATR<%.2f over %d bars",
                        InpMaxADX, InpMaxMacroSlopeATR, InpMacroSlopeBars));
   LogInfo(StringFormat("Stretch        : ≥ %.1f × ATR(%d) from EMA(%d)",
                        InpMinStretchATR, InpATRPeriod, InpEMAMeanPeriod));
   LogInfo(StringFormat("Confirmation   : Engulfing=%s PinBar=%s (wick≥%.0f%% body≤%.0f%%)",
                        InpUseEngulfing ? "ON" : "OFF",
                        InpUsePinBar ? "ON" : "OFF",
                        InpPinWickRatio*100, InpPinBodyRatio*100));
   LogInfo(StringFormat("SL / TP        : SL=swing±%.1fATR (cap %.1f)  TP=%s  MinRR=%.2f",
                        InpSLBufferATR, InpSLMaxATR,
                        InpTPAtMean ? "EMA20" : StringFormat("%.1fATR", InpTPFallbackATR),
                        InpMinRR));
   LogInfo(StringFormat("Time stop      : %s @ %d bars", InpUseTimeStop ? "ON" : "OFF", InpMaxHoldBars));
   LogInfo(StringFormat("Lot            : base=%.2f dyn=%s halve@%.0f%% restore@%.0f%%",
                        InpLotSize, InpUseDynLots ? "ON" : "OFF",
                        InpDDHalvePercent, InpDDRestorePercent));
   LogInfo(StringFormat("Risk Gates     : DailyLoss<=%.1f%% Cooldown=%d Breaker@%d losses",
                        InpMaxDailyLossPct, InpCooldownBars, InpMaxConsecLosses));
   LogInfo(StringFormat("Session        : %02d-%02d UTC", InpSessionStartHour, InpSessionEndHour));
   LogInfo("────────────────────────────");

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_bars_since_loss = 9999;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   StateSave();
   int handles[] = { g_h_ema_mean, g_h_ema_filter, g_h_atr, g_h_atr_base, g_h_adx };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
   LogInfo(StringFormat("Deinit (reason=%d) — state persisted", reason));
}

//+------------------------------------------------------------------+
//| Try to open a new position based on current (closed) bar         |
//+------------------------------------------------------------------+
void TryEntry()
{
   double atr  = Get1(g_h_atr, 1);
   if(atr <= 0) return;
   double mean = Get1(g_h_ema_mean, 1);
   if(mean <= 0) return;
   double mean2 = Get1(g_h_ema_mean, 2);
   if(mean2 <= 0) return;

   // Bar[2] = the stretched extension bar (price dislocated from mean)
   // Bar[1] = the reversal candle confirming the turn
   // Bar[0] = current open (we enter at market here)
   double o1 = iOpen(_Symbol,  g_tf, 1);
   double h1 = iHigh(_Symbol,  g_tf, 1);
   double l1 = iLow(_Symbol,   g_tf, 1);
   double c1 = iClose(_Symbol, g_tf, 1);
   double o2 = iOpen(_Symbol,  g_tf, 2);
   double h2 = iHigh(_Symbol,  g_tf, 2);
   double l2 = iLow(_Symbol,   g_tf, 2);
   double c2 = iClose(_Symbol, g_tf, 2);
   double c3 = iClose(_Symbol, g_tf, 3);

   // ── Stretch test on the EXTENSION bar (bar[2]) ──
   double stretch2_low  = l2 - mean2;   // negative if low dipped below mean
   double stretch2_high = h2 - mean2;   // positive if high pushed above mean

   // ── Long setup: bar[2] dipped ≥ N×ATR below mean, bar[1] is bullish reversal vs bar[2] ──
   bool long_stretch = (mean2 - l2) >= InpMinStretchATR * atr;
   bool short_stretch = (h2 - mean2) >= InpMinStretchATR * atr;

   if(long_stretch && IsBullishReversal(o1, h1, l1, c1, o2, c2))
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // SL: at swing extreme - buffer, but capped at MaxATR for RR safety
      double swing_low = MathMin(l1, l2);
      double sl_swing  = swing_low - InpSLBufferATR * atr;
      double sl_cap    = ask - InpSLMaxATR * atr;
      double sl        = MathMax(sl_swing, sl_cap);  // whichever is closer to entry
      // TP: mean (high-probability) or fallback ATR
      double tp = InpTPAtMean ? mean : (ask + InpTPFallbackATR * atr);
      // RR floor: skip if not worth the risk
      double risk = ask - sl;
      double reward = tp - ask;
      if(risk <= 0 || reward <= 0 || reward / risk < InpMinRR)
      {
         LogVerbose(StringFormat("Long skipped — RR=%.2f < %.2f (risk=%.2f reward=%.2f)",
                                  reward/MathMax(risk,1e-9), InpMinRR, risk, reward));
         return;
      }
      double lot = ComputeLot();
      OpenPosition(true, c1, sl, tp, lot);
      g_open_position_time = TimeCurrent();
   }
   else if(short_stretch && IsBearishReversal(o1, h1, l1, c1, o2, c2))
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double swing_high = MathMax(h1, h2);
      double sl_swing   = swing_high + InpSLBufferATR * atr;
      double sl_cap     = bid + InpSLMaxATR * atr;
      double sl         = MathMin(sl_swing, sl_cap);  // whichever is closer to entry
      double tp = InpTPAtMean ? mean : (bid - InpTPFallbackATR * atr);
      double risk = sl - bid;
      double reward = bid - tp;
      if(risk <= 0 || reward <= 0 || reward / risk < InpMinRR)
      {
         LogVerbose(StringFormat("Short skipped — RR=%.2f < %.2f (risk=%.2f reward=%.2f)",
                                  reward/MathMax(risk,1e-9), InpMinRR, risk, reward));
         return;
      }
      double lot = ComputeLot();
      OpenPosition(false, c1, sl, tp, lot);
      g_open_position_time = TimeCurrent();
   }
   else
   {
      LogVerbose(StringFormat("No setup — long_stretch=%d short_stretch=%d (mean2=%.2f l2=%.2f h2=%.2f atr=%.2f)",
                              long_stretch, short_stretch, mean2, l2, h2, atr));
   }
}

//+------------------------------------------------------------------+
//| Manage existing position (regime exit + time-stop)                |
//+------------------------------------------------------------------+
void ManagePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);

   // Time stop
   if(InpUseTimeStop)
   {
      int bars_held = iBarShift(_Symbol, g_tf, open_time, false);
      if(bars_held >= InpMaxHoldBars)
      {
         ClosePositionByTicket(ticket, StringFormat("time-stop %d bars", bars_held));
         return;
      }
   }

   // Regime exit (optional) — close if ADX surges, signaling regime change
   if(InpUseRegimeExit)
   {
      double adx = Get1(g_h_adx, 0);  // current bar
      if(adx > InpMaxADX + 5.0)
      {
         ClosePositionByTicket(ticket, StringFormat("regime broken ADX=%.1f", adx));
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime cur_bar = iTime(_Symbol, g_tf, 0);
   if(cur_bar == 0) return;

   // ── Bar-close events ──
   bool new_bar = (cur_bar != g_last_bar);
   if(new_bar)
   {
      g_last_bar = cur_bar;
      g_bars_since_loss++;

      // Update DD tracker on every new bar
      if(InpUseDynLots)
      {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         g_peak_equity = MathMax(g_peak_equity, equity);
      }

      // Detect closure of our position
      ulong t;
      if(g_open_position_ticket != 0 && !HaveOurPosition(t))
      {
         // Position closed - find the deal
         CheckLastClosedTradePnL();
      }
   }

   // Track open position ticket
   ulong cur_ticket;
   if(HaveOurPosition(cur_ticket))
   {
      g_open_position_ticket = cur_ticket;
      // Manage on every tick (cheap checks)
      if(new_bar) ManagePosition(cur_ticket);
      return;  // one-position-at-a-time
   }
   else
   {
      // Detect deal closure that happened intra-bar
      if(g_open_position_ticket != 0)
      {
         CheckLastClosedTradePnL();
      }
   }

   // ── Entry attempt only on a new bar close ──
   if(!new_bar) return;

   if(!DailyLossOK())  return;
   if(!BreakerOK())    return;
   if(!CooldownOK())   return;
   if(!InSession(cur_bar)) return;
   if(!SpreadOK())     return;
   if(!RegimeRanging()) return;
   if(!VolOK())         return;

   TryEntry();
}
//+------------------------------------------------------------------+
