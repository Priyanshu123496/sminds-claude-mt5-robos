//+------------------------------------------------------------------+
//|                            TTR-XI-V1a-prod-ready-v12-risk.mq5    |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Risk-based-sizing variant of TTR-XI-V1a-prod-ready-v12.        |
//|  Position size derived from InpRiskPercent (default 1.5%) of    |
//|  current equity, divided by SL distance × tick value.            |
//|  All other strategy logic identical to prod-ready-v12.           |
//|                                                                  |
//|  Strategy: Triple-EMA crossover (9/20 trigger, 200 filter) on    |
//|            XAUUSD M15. ATR-based stop, EMA-cross exits.          |
//|                                                                  |
//|  Risk controls (in order of severity):                           |
//|    1. EMA200 macro-slope, ADX, vol-spike, EMA-separation,        |
//|       UTC session — entry quality filters                        |
//|    2. ATR×3.0 hard stop loss                                     |
//|    3. Post-loss cooldown (4 M15 bars)                            |
//|    4. Consecutive-loss circuit breaker (halt for the day)        |
//|    5. Daily loss limit (3% equity)                               |
//|    6. Dynamic position sizing — halve lots at 15% equity DD,     |
//|       restore at 5% recovery (hysteresis)                        |
//|    7. Spread guard, broker stops-level enforcement               |
//|                                                                  |
//|  Persistence: peak equity, consecutive losses, breaker day are   |
//|    persisted via GlobalVariables, so the state survives EA       |
//|    restarts, disconnects, and platform reboots.                  |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "12.10"
#property description "TTR-XI V1a — production-ready V12 (risk-based sizing)"
#property description "Triple-EMA (9/20/200) + dynamic DD guard + 1.5% risk per trade"
#property description "XAUUSD M15"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Strategy Identification ════════════════════════"
input long   InpMagicNumber       = 94736320;        // Magic number (per-account unique) — V12-risk variant
input string InpOrderComment      = "TTR-XI-V12R";   // Order comment (risk-based variant)

input group "═══ Symbol / Timeframe Guard ══════════════════════"
input bool   InpRequireXAUUSD     = true;            // Reject if symbol is not XAU/Gold
input bool   InpRequireM15        = true;            // Reject if timeframe is not M15

input group "═══ EMA Periods ════════════════════════════════════"
input int    InpFastPeriod        = 9;               // Fast EMA period
input int    InpSlowPeriod        = 20;              // Slow EMA period
input int    InpFilterPeriod      = 200;             // Filter EMA period

input group "═══ Position Sizing ═══════════════════════════════"
input bool   InpUseRiskBasedLot   = false;           // Risk-based sizing (vs fixed lot)
input double InpRiskPercent       = 1.0;             // % of equity to risk per trade
input double InpLotSize           = 0.15;            // Fallback fixed lot if risk-based off
input double InpMaxLotSize        = 5.00;            // Hard cap on lot size (safety)
input double InpMinLotSize        = 0.01;            // Hard floor on lot size

input group "═══ Dynamic Lot Sizing (DD Guard) ═════════════════"
input bool   InpUseDynLots        = true;            // Enable dynamic lot reduction
input double InpDDHalvePercent    = 15.0;            // Halve lots when DD >= this %
input double InpDDRestorePercent  = 5.0;             // Restore lots when DD < this %

input group "═══ ATR Stop Loss ══════════════════════════════════"
input bool   InpUseATRStopLoss    = true;            // Use ATR-based hard stop
input int    InpATRPeriod         = 14;              // ATR period for SL
input double InpATRSLMultiplier   = 3.0;             // SL distance = ATR × this

input group "═══ ATR Trailing Stop ═════════════════════════════"
input bool   InpUseATRTrail       = false;           // Trailing stop (disabled — let winners run)
input double InpATRTrailMultiplier= 1.0;             // Trail distance = ATR × this

input group "═══ Entry Quality Filters ════════════════════════"
input bool   InpUseEMASepFilter   = true;            // Require EMA9-EMA20 separation
input double InpMinEMASepATRRatio = 0.10;            // Min separation = ATR × this
input bool   InpUseADXFilter      = true;            // Require trend strength
input int    InpADXPeriod         = 14;              // ADX period
input double InpMinADX            = 25.0;            // Minimum ADX for entry
input bool   InpUseVolFilter      = true;            // Reject volatility spikes
input int    InpATRBaselinePeriod = 50;              // Long ATR baseline
input double InpMaxATRRatio       = 1.5;             // Reject if ATR > baseline × this
input bool   InpUseMacroFilter    = true;            // Require EMA200 slope alignment
input int    InpMacroSlopeBars    = 24;              // EMA200 slope lookback

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
#define EA_TAG          "TTR-XI-V12R"
#define GV_PREFIX       "TTRXIV12R_"

CTrade        g_trade;
CSymbolInfo   g_sym;

int  g_h_fast      = INVALID_HANDLE;
int  g_h_slow      = INVALID_HANDLE;
int  g_h_filter    = INVALID_HANDLE;
int  g_h_atr       = INVALID_HANDLE;
int  g_h_atr_base  = INVALID_HANDLE;
int  g_h_adx       = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf         = PERIOD_CURRENT;
datetime        g_last_bar   = 0;
bool            g_rel_ready  = false;
int             g_prev_fast  = 0;
int             g_prev_price = 0;

enum EntryWaitState { WAIT_CROSS = 0, WAIT_BUY_FILTER = 1, WAIT_SELL_FILTER = 2 };
EntryWaitState g_entry_wait = WAIT_CROSS;

datetime g_today               = 0;
double   g_daily_start_bal     = 0.0;

int      g_bars_since_loss     = 9999;
bool     g_last_trade_was_loss = false;
int      g_consec_losses       = 0;
datetime g_breaker_day         = 0;

double   g_peak_equity         = 0.0;
double   g_last_balance        = 0.0;   // detect deposits/withdrawals
bool     g_lots_halved         = false;

string   g_gv_peak             = "";
string   g_gv_consec           = "";
string   g_gv_breaker          = "";
string   g_gv_balance          = "";

//+------------------------------------------------------------------+
//| Logging helpers                                                   |
//+------------------------------------------------------------------+
void LogInfo(const string msg)
{
   PrintFormat("[%s] %s", EA_TAG, msg);
}

void LogWarn(const string msg)
{
   PrintFormat("[%s] WARN: %s", EA_TAG, msg);
}

void LogError(const string msg)
{
   PrintFormat("[%s] ERROR: %s", EA_TAG, msg);
}

void LogDebug(const string msg)
{
   if(InpVerboseLogging)
      PrintFormat("[%s] %s", EA_TAG, msg);
}

//+------------------------------------------------------------------+
//| Persistence helpers                                               |
//+------------------------------------------------------------------+
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_peak))
      g_peak_equity = GlobalVariableGet(g_gv_peak);
   else
      g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(GlobalVariableCheck(g_gv_consec))
      g_consec_losses = (int)GlobalVariableGet(g_gv_consec);

   if(GlobalVariableCheck(g_gv_breaker))
      g_breaker_day = (datetime)(long)GlobalVariableGet(g_gv_breaker);

   if(GlobalVariableCheck(g_gv_balance))
      g_last_balance = GlobalVariableGet(g_gv_balance);
   else
      g_last_balance = AccountInfoDouble(ACCOUNT_BALANCE);
}

void StateSave()
{
   GlobalVariableSet(g_gv_peak,    g_peak_equity);
   GlobalVariableSet(g_gv_consec,  (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)(long)g_breaker_day);
   GlobalVariableSet(g_gv_balance, g_last_balance);
}

//+------------------------------------------------------------------+
//| Utility                                                           |
//+------------------------------------------------------------------+
int Relation(const double a, const double b)
{
   if(a > b) return  1;
   if(a < b) return -1;
   return 0;
}

bool ReadBuffer(const int handle, const int shift, double &value)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   const int n = shift + 1;
   if(CopyBuffer(handle, 0, 0, n, buf) != n)
      return false;
   value = buf[shift];
   return MathIsValidNumber(value) && value != 0.0;
}

bool ReadBid(double &value)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   value = tick.bid;
   return MathIsValidNumber(value) && value > 0.0;
}

bool IsNewBar(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, bars) != 1)
      return false;
   bar_time = bars[0];
   if(g_last_bar == 0) { g_last_bar = bars[0]; return false; }
   if(bars[0] != g_last_bar) { g_last_bar = bars[0]; return true; }
   return false;
}

double NormalizeVol(const double x)
{
   double min_v = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_v = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || min_v <= 0.0)
      return 0.0;
   double clipped = MathMax(min_v, MathMin(max_v, x));
   int d = 2;
   for(int i = 0; i <= 8; i++)
   {
      double s = step * MathPow(10.0, i);
      if(MathAbs(s - MathRound(s)) < 1e-8) { d = i; break; }
   }
   return NormalizeDouble(MathFloor(clipped / step) * step, d);
}

bool FindPosition(ulong &ticket, long &type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ticket = t;
         type   = PositionGetInteger(POSITION_TYPE);
         return true;
      }
   }
   ticket = 0; type = -1;
   return false;
}

//+------------------------------------------------------------------+
//| Spread / stops-level guards                                       |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
   {
      LogDebug(StringFormat("Skip: spread %d > max %d", (int)spread, InpMaxSpreadPoints));
      return false;
   }
   return true;
}

double EnforceMinStopDistance(const double sl_price, const double ref_price, const bool is_buy)
{
   long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops_level <= 0)
      return sl_price;
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = stops_level * point;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(is_buy)
   {
      double max_sl = ref_price - minDist;
      if(sl_price > max_sl)
         return NormalizeDouble(max_sl, digits);
   }
   else
   {
      double min_sl = ref_price + minDist;
      if(sl_price < min_sl)
         return NormalizeDouble(min_sl, digits);
   }
   return sl_price;
}

//+------------------------------------------------------------------+
//| Risk gates                                                        |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpUseSessionFilter)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

bool IsDailyLossLimitBreached()
{
   if(!InpUseDailyLossLimit)
      return false;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today)
   {
      g_today           = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
      return false;
   }
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily_start_bal <= 0.0) return false;
   double loss_pct = (g_daily_start_bal - equity) / g_daily_start_bal * 100.0;
   return (loss_pct >= InpMaxDailyLossPct);
}

bool IsCooldownActive()
{
   if(!InpUseCooldown)
      return false;
   return (g_last_trade_was_loss && g_bars_since_loss < InpCooldownBars);
}

bool IsLossBreakerActive()
{
   if(!InpUseLossBreaker)
      return false;
   if(g_consec_losses < InpMaxConsecLosses)
      return false;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(g_breaker_day == 0) return false;
   return (today <= g_breaker_day);
}

//+------------------------------------------------------------------+
//| DD state update (peak equity + halved flag)                       |
//+------------------------------------------------------------------+
void UpdateDDState()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Detect external deposit/withdrawal and recalibrate peak
   if(g_last_balance > 0.0)
   {
      double bal_change = balance - g_last_balance;
      if(MathAbs(bal_change) > g_last_balance * 0.005 && PositionsTotal() == 0)
      {
         g_peak_equity += bal_change;
         LogInfo(StringFormat("Detected balance change %.2f — recalibrated peak equity to %.2f",
                              bal_change, g_peak_equity));
      }
   }
   g_last_balance = balance;

   if(equity > g_peak_equity)
      g_peak_equity = equity;

   double dd_pct = 0.0;
   if(g_peak_equity > 0.0)
      dd_pct = (g_peak_equity - equity) / g_peak_equity * 100.0;

   bool was_halved = g_lots_halved;
   if(dd_pct >= InpDDHalvePercent)
      g_lots_halved = true;
   else if(dd_pct < InpDDRestorePercent)
      g_lots_halved = false;

   if(g_lots_halved != was_halved)
   {
      LogInfo(StringFormat("Lot size %s — current DD %.2f%% (peak=%.2f, equity=%.2f)",
                           g_lots_halved ? "HALVED" : "RESTORED", dd_pct,
                           g_peak_equity, equity));
   }
}

//+------------------------------------------------------------------+
//| Lot computation: risk-based or fixed, with DD halving applied     |
//|   sl_distance_price = positive distance in price units (entry-SL) |
//+------------------------------------------------------------------+
double ComputeLot(const double sl_distance_price)
{
   UpdateDDState();

   double base_lot = 0.0;

   if(InpUseRiskBasedLot && sl_distance_price > 0.0)
   {
      // Risk-based: equity × risk% / loss-per-lot at this SL distance
      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk_amt   = equity * (InpRiskPercent / 100.0);
      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size > 0.0 && tick_value > 0.0 && risk_amt > 0.0)
      {
         double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
         if(loss_per_lot > 0.0)
            base_lot = risk_amt / loss_per_lot;
      }
      // Fallback to fixed if computation failed
      if(base_lot <= 0.0)
         base_lot = InpLotSize;
   }
   else
   {
      base_lot = InpLotSize;
   }

   // Apply DD halving if enabled
   if(InpUseDynLots && g_lots_halved)
      base_lot *= 0.5;

   // Clamp to min/max
   double clamped = MathMax(InpMinLotSize, MathMin(InpMaxLotSize, base_lot));
   return clamped;
}

// Backwards-compat shim: when caller doesn't know SL distance yet
double GetEffectiveLot()
{
   return ComputeLot(0.0);
}

//+------------------------------------------------------------------+
//| Entry filters                                                     |
//+------------------------------------------------------------------+
bool EntryFiltersPass(const double fast_ema, const double slow_ema,
                      const double filter_ema, const double atr,
                      const bool want_buy)
{
   if(InpUseEMASepFilter && atr > 0.0)
   {
      double sep = MathAbs(fast_ema - slow_ema);
      if(sep < atr * InpMinEMASepATRRatio)
      { LogDebug("Skip: EMA sep too small"); return false; }
   }

   if(InpUseADXFilter)
   {
      double adx = 0.0;
      if(ReadBuffer(g_h_adx, 0, adx) && adx < InpMinADX)
      { LogDebug(StringFormat("Skip: ADX %.1f < %.1f", adx, InpMinADX)); return false; }
   }

   if(InpUseVolFilter && atr > 0.0)
   {
      double atr_base = 0.0;
      if(ReadBuffer(g_h_atr_base, 0, atr_base) && atr_base > 0.0)
      {
         if(atr > atr_base * InpMaxATRRatio)
         { LogDebug(StringFormat("Skip: ATR spike %.2f > %.2f×%.1f", atr, atr_base, InpMaxATRRatio)); return false; }
      }
   }

   if(InpUseMacroFilter)
   {
      double filter_old = 0.0;
      if(ReadBuffer(g_h_filter, InpMacroSlopeBars, filter_old) && filter_old > 0.0)
      {
         bool ema200_up   = (filter_ema > filter_old);
         bool ema200_down = (filter_ema < filter_old);
         if(want_buy && !ema200_up)
         { LogDebug("Skip: EMA200 not rising — no long"); return false; }
         if(!want_buy && !ema200_down)
         { LogDebug("Skip: EMA200 not falling — no short"); return false; }
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Trade execution with retry                                        |
//+------------------------------------------------------------------+
bool ExecBuy(const double vol, const double sl)
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      if(g_trade.Buy(vol, _Symbol, 0.0, sl, 0.0, InpOrderComment))
         return true;
      uint rc = g_trade.ResultRetcode();
      LogWarn(StringFormat("Buy attempt %d/%d failed rc=%u (%s)",
                           attempt, InpMaxRetries, rc, g_trade.ResultRetcodeDescription()));
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME)
         return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool ExecSell(const double vol, const double sl)
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      if(g_trade.Sell(vol, _Symbol, 0.0, sl, 0.0, InpOrderComment))
         return true;
      uint rc = g_trade.ResultRetcode();
      LogWarn(StringFormat("Sell attempt %d/%d failed rc=%u (%s)",
                           attempt, InpMaxRetries, rc, g_trade.ResultRetcodeDescription()));
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME)
         return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool OpenBuy(const double atr)
{
   if(!IsSpreadAcceptable()) return false;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl     = 0.0;
   double sl_dist = 0.0;

   if(InpUseATRStopLoss && atr > 0.0)
   {
      sl = NormalizeDouble(ask - atr * InpATRSLMultiplier, digits);
      sl = EnforceMinStopDistance(sl, ask, true);
      sl_dist = ask - sl;
   }

   double vol = NormalizeVol(ComputeLot(sl_dist));
   if(vol <= 0.0)
   {
      LogWarn("Lot normalization returned zero — skip buy");
      return false;
   }

   bool ok = ExecBuy(vol, sl);
   if(ok)
      LogInfo(StringFormat("BUY %.2f @ %.5f SL=%.5f (SLdist=%.2f risk=%.1f%% DD-half=%s)",
                           vol, ask, sl, sl_dist, InpRiskPercent, g_lots_halved ? "Y" : "N"));
   return ok;
}

bool OpenSell(const double atr)
{
   if(!IsSpreadAcceptable()) return false;

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl     = 0.0;
   double sl_dist = 0.0;

   if(InpUseATRStopLoss && atr > 0.0)
   {
      sl = NormalizeDouble(bid + atr * InpATRSLMultiplier, digits);
      sl = EnforceMinStopDistance(sl, bid, false);
      sl_dist = sl - bid;
   }

   double vol = NormalizeVol(ComputeLot(sl_dist));
   if(vol <= 0.0)
   {
      LogWarn("Lot normalization returned zero — skip sell");
      return false;
   }

   bool ok = ExecSell(vol, sl);
   if(ok)
      LogInfo(StringFormat("SELL %.2f @ %.5f SL=%.5f (SLdist=%.2f risk=%.1f%% DD-half=%s)",
                           vol, bid, sl, sl_dist, InpRiskPercent, g_lots_halved ? "Y" : "N"));
   return ok;
}

bool ClosePosition(const ulong ticket)
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      if(g_trade.PositionClose(ticket))
         return true;
      uint rc = g_trade.ResultRetcode();
      LogWarn(StringFormat("Close attempt %d/%d failed rc=%u (%s)",
                           attempt, InpMaxRetries, rc, g_trade.ResultRetcodeDescription()));
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

//+------------------------------------------------------------------+
//| Trailing stop                                                     |
//+------------------------------------------------------------------+
void ApplyTrailingStop(const ulong ticket, const long pos_type, const double atr)
{
   if(!InpUseATRTrail || atr <= 0.0) return;
   if(!PositionSelectByTicket(ticket)) return;

   double open_px = PositionGetDouble(POSITION_PRICE_OPEN);
   double cur_sl  = PositionGetDouble(POSITION_SL);
   double cur_tp  = PositionGetDouble(POSITION_TP);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double dist    = atr * InpATRTrailMultiplier;

   if(pos_type == POSITION_TYPE_BUY)
   {
      double new_sl = NormalizeDouble(bid - dist, digits);
      new_sl = EnforceMinStopDistance(new_sl, bid, true);
      if(bid > open_px && new_sl > cur_sl)
         g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      double new_sl = NormalizeDouble(ask + dist, digits);
      new_sl = EnforceMinStopDistance(new_sl, ask, false);
      if(ask < open_px && (cur_sl == 0.0 || new_sl < cur_sl))
         g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
}

//+------------------------------------------------------------------+
//| Trade-result accounting                                           |
//+------------------------------------------------------------------+
void RecordTradeResult(const ulong ticket)
{
   if(!HistorySelectByPosition(ticket))
      return;
   int deals = HistoryDealsTotal();
   if(deals < 1) return;

   double total_profit = 0.0;
   for(int i = 0; i < deals; i++)
   {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0) continue;
      total_profit += HistoryDealGetDouble(dt, DEAL_PROFIT)
                    + HistoryDealGetDouble(dt, DEAL_SWAP)
                    + HistoryDealGetDouble(dt, DEAL_COMMISSION);
   }

   if(total_profit < 0.0)
   {
      g_last_trade_was_loss = true;
      g_bars_since_loss     = 0;
      g_consec_losses++;
      if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
      {
         g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
         LogWarn(StringFormat("Circuit breaker tripped at %d consecutive losses; halt until next day",
                              g_consec_losses));
      }
      LogInfo(StringFormat("Loss recorded (%.2f) — cooldown active. Consec losses: %d",
                           total_profit, g_consec_losses));
   }
   else
   {
      g_last_trade_was_loss = false;
      g_bars_since_loss     = 9999;
      if(g_consec_losses > 0)
         LogInfo(StringFormat("Win (%.2f) — consec-loss counter reset", total_profit));
      g_consec_losses = 0;
      g_breaker_day   = 0;
   }
   StateSave();
}

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   // ── Symbol / TF guards ──
   string up = _Symbol;
   StringToUpper(up);
   if(InpRequireXAUUSD && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   {
      LogError(StringFormat("Symbol %s is not XAUUSD/Gold — strategy was tuned for gold only", _Symbol));
      return INIT_FAILED;
   }
   if(InpRequireM15 && g_tf != PERIOD_M15)
   {
      LogError("Timeframe must be M15 — strategy was tuned for M15 only");
      return INIT_FAILED;
   }

   if(!g_sym.Name(_Symbol))
   {
      LogError("CSymbolInfo init failed");
      return INIT_FAILED;
   }
   if(!SymbolSelect(_Symbol, true))
   {
      LogError("SymbolSelect failed");
      return INIT_FAILED;
   }

   // ── Parameter sanity ──
   if(InpFastPeriod >= InpSlowPeriod || InpSlowPeriod >= InpFilterPeriod)
   {
      LogError("EMA periods must satisfy: fast < slow < filter");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLotSize <= 0.0 || InpMaxLotSize <= 0.0 || InpMaxLotSize < InpMinLotSize || InpMinLotSize <= 0.0)
   {
      LogError("Invalid lot configuration");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpUseRiskBasedLot && (InpRiskPercent <= 0.0 || InpRiskPercent > 10.0))
   {
      LogError("Invalid risk percent: must be in (0,10]");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpDDHalvePercent <= InpDDRestorePercent)
   {
      LogError("InpDDHalvePercent must be > InpDDRestorePercent (hysteresis)");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour   < 1 || InpSessionEndHour   > 24 ||
      InpSessionStartHour >= InpSessionEndHour)
   {
      LogError("Invalid session hours");
      return INIT_PARAMETERS_INCORRECT;
   }

   // ── Indicators ──
   g_h_fast     = iMA(_Symbol, g_tf, InpFastPeriod,        0, MODE_EMA, PRICE_CLOSE);
   g_h_slow     = iMA(_Symbol, g_tf, InpSlowPeriod,        0, MODE_EMA, PRICE_CLOSE);
   g_h_filter   = iMA(_Symbol, g_tf, InpFilterPeriod,      0, MODE_EMA, PRICE_CLOSE);
   g_h_atr      = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_atr_base = iATR(_Symbol, g_tf, InpATRBaselinePeriod);
   g_h_adx      = iADX(_Symbol, g_tf, InpADXPeriod);

   if(g_h_fast     == INVALID_HANDLE ||
      g_h_slow     == INVALID_HANDLE ||
      g_h_filter   == INVALID_HANDLE ||
      g_h_atr      == INVALID_HANDLE ||
      g_h_atr_base == INVALID_HANDLE ||
      g_h_adx      == INVALID_HANDLE)
   {
      LogError("Failed to create one or more indicator handles");
      return INIT_FAILED;
   }

   // ── Trade context ──
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // ── Persisted state (peak equity, breaker, etc.) ──
   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_peak    = StringFormat("%s%lld_%s_peak",    GV_PREFIX, acct, _Symbol);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   g_gv_balance = StringFormat("%s%lld_%s_balance", GV_PREFIX, acct, _Symbol);

   // In strategy tester, always start with clean state to ensure
   // deterministic, repeatable backtest results.
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

   // ── Volatile state ──
   g_entry_wait           = WAIT_CROSS;
   g_rel_ready            = false;
   g_prev_fast            = 0;
   g_prev_price           = 0;
   g_last_bar             = 0;
   g_last_trade_was_loss  = false;
   g_bars_since_loss      = 9999;
   g_lots_halved          = false;

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);

   // ── Audit-trail init log ──
   LogInfo("─────────── INIT ───────────");
   LogInfo(StringFormat("Symbol/TF      : %s / %s", _Symbol, EnumToString(g_tf)));
   LogInfo(StringFormat("Magic / Comment: %lld / %s", InpMagicNumber, InpOrderComment));
   LogInfo(StringFormat("EMA            : %d / %d / %d", InpFastPeriod, InpSlowPeriod, InpFilterPeriod));
   if(InpUseRiskBasedLot)
      LogInfo(StringFormat("Lot            : RISK-BASED %.2f%% equity (min=%.2f max=%.2f) dyn=%s halve@%.0f%% restore@%.0f%%",
                           InpRiskPercent, InpMinLotSize, InpMaxLotSize,
                           InpUseDynLots ? "ON" : "OFF",
                           InpDDHalvePercent, InpDDRestorePercent));
   else
      LogInfo(StringFormat("Lot            : FIXED base=%.2f (min=%.2f max=%.2f) dyn=%s halve@%.0f%% restore@%.0f%%",
                           InpLotSize, InpMinLotSize, InpMaxLotSize,
                           InpUseDynLots ? "ON" : "OFF",
                           InpDDHalvePercent, InpDDRestorePercent));
   LogInfo(StringFormat("Stop Loss      : %s ATR×%.1f", InpUseATRStopLoss ? "ON" : "OFF", InpATRSLMultiplier));
   LogInfo(StringFormat("Trail          : %s ATR×%.1f", InpUseATRTrail ? "ON" : "OFF", InpATRTrailMultiplier));
   LogInfo(StringFormat("Filters        : ADX>=%.0f Vol<=%.1f Macro=%s Sep>=%.2fATR Session=%02d-%02d UTC",
                        InpMinADX, InpMaxATRRatio,
                        InpUseMacroFilter ? "ON" : "OFF",
                        InpMinEMASepATRRatio,
                        InpSessionStartHour, InpSessionEndHour));
   LogInfo(StringFormat("Risk Gates     : DailyLoss<=%.1f%% Cooldown=%d bars Breaker@%d losses",
                        InpMaxDailyLossPct, InpCooldownBars, InpMaxConsecLosses));
   LogInfo(StringFormat("Execution      : MaxSpread=%dpts Slippage=%dpts Retries=%d",
                        InpMaxSpreadPoints, InpSlippagePoints, InpMaxRetries));
   LogInfo(StringFormat("State Loaded   : peak=%.2f consecLoss=%d breakerDay=%s",
                        g_peak_equity, g_consec_losses,
                        g_breaker_day == 0 ? "—" : TimeToString(g_breaker_day, TIME_DATE)));
   LogInfo("────────────────────────────");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   StateSave();
   int handles[] = { g_h_fast, g_h_slow, g_h_filter, g_h_atr, g_h_atr_base, g_h_adx };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE)
         IndicatorRelease(handles[i]);
   LogInfo(StringFormat("Deinit (reason=%d) — state persisted", reason));
}

//+------------------------------------------------------------------+
//| OnTick — strategy core                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar_time = 0;
   bool new_bar = IsNewBar(bar_time);
   if(new_bar)
   {
      if(g_last_trade_was_loss && g_bars_since_loss < 9999)
         g_bars_since_loss++;
   }

   double fast_ema = 0.0, slow_ema = 0.0, filter_ema = 0.0, price = 0.0, atr = 0.0;
   if(!ReadBuffer(g_h_fast,   0, fast_ema))   return;
   if(!ReadBuffer(g_h_slow,   0, slow_ema))   return;
   if(!ReadBuffer(g_h_filter, 0, filter_ema)) return;
   if(!ReadBid(price))                        return;
   if(!ReadBuffer(g_h_atr,    0, atr))        return;

   int fast_rel  = Relation(fast_ema, slow_ema);
   int price_rel = Relation(price, filter_ema);

   if(!g_rel_ready)
   {
      g_prev_fast  = fast_rel;
      g_prev_price = price_rel;
      g_rel_ready  = true;
      return;
   }

   bool up_cross         = (g_prev_fast  <= 0 && fast_rel  > 0);
   bool down_cross       = (g_prev_fast  >= 0 && fast_rel  < 0);
   bool price_up_cross   = (g_prev_price <= 0 && price_rel > 0);
   bool price_down_cross = (g_prev_price >= 0 && price_rel < 0);
   bool pass_buy         = (price_rel > 0);
   bool pass_sell        = (price_rel < 0);
   bool trend_up         = (fast_rel > 0);
   bool trend_down       = (fast_rel < 0);

   ulong ticket = 0;
   long  pos_type = -1;
   bool  has_pos = FindPosition(ticket, pos_type);

   // ── Manage open position: trailing + EMA-cross exit ──
   if(has_pos)
   {
      ApplyTrailingStop(ticket, pos_type, atr);

      if(pos_type == POSITION_TYPE_BUY && down_cross)
      {
         if(ClosePosition(ticket))
         {
            RecordTradeResult(ticket);
            g_entry_wait = WAIT_CROSS;
         }
      }
      else if(pos_type == POSITION_TYPE_SELL && up_cross)
      {
         if(ClosePosition(ticket))
         {
            RecordTradeResult(ticket);
            g_entry_wait = WAIT_CROSS;
         }
      }
      g_prev_fast  = fast_rel;
      g_prev_price = price_rel;
      return;
   }

   // ── Risk gates ──
   if(!IsSessionAllowed() || IsDailyLossLimitBreached() ||
      IsCooldownActive()  || IsLossBreakerActive())
   {
      g_prev_fast  = fast_rel;
      g_prev_price = price_rel;
      return;
   }

   bool filt_buy  = EntryFiltersPass(fast_ema, slow_ema, filter_ema, atr, true);
   bool filt_sell = EntryFiltersPass(fast_ema, slow_ema, filter_ema, atr, false);

   // ── Entry state machine ──
   if(g_entry_wait == WAIT_BUY_FILTER)
   {
      if(down_cross)
      {
         if(pass_sell || price_down_cross)
         {
            if(filt_sell && OpenSell(atr)) g_entry_wait = WAIT_CROSS;
            else                           g_entry_wait = WAIT_SELL_FILTER;
         }
         else g_entry_wait = WAIT_SELL_FILTER;
      }
      else if(!trend_up)
      {
         g_entry_wait = WAIT_CROSS;
      }
      else if(pass_buy || price_up_cross)
      {
         if(filt_buy && OpenBuy(atr)) g_entry_wait = WAIT_CROSS;
      }
      g_prev_fast = fast_rel; g_prev_price = price_rel;
      return;
   }

   if(g_entry_wait == WAIT_SELL_FILTER)
   {
      if(up_cross)
      {
         if(pass_buy || price_up_cross)
         {
            if(filt_buy && OpenBuy(atr))  g_entry_wait = WAIT_CROSS;
            else                          g_entry_wait = WAIT_BUY_FILTER;
         }
         else g_entry_wait = WAIT_BUY_FILTER;
      }
      else if(!trend_down)
      {
         g_entry_wait = WAIT_CROSS;
      }
      else if(pass_sell || price_down_cross)
      {
         if(filt_sell && OpenSell(atr)) g_entry_wait = WAIT_CROSS;
      }
      g_prev_fast = fast_rel; g_prev_price = price_rel;
      return;
   }

   // WAIT_CROSS — fresh crossover signals
   if(up_cross)
   {
      if(pass_buy || price_up_cross)
      {
         if(filt_buy && OpenBuy(atr))  g_entry_wait = WAIT_CROSS;
         else                          g_entry_wait = WAIT_BUY_FILTER;
      }
      else g_entry_wait = WAIT_BUY_FILTER;
   }
   else if(down_cross)
   {
      if(pass_sell || price_down_cross)
      {
         if(filt_sell && OpenSell(atr)) g_entry_wait = WAIT_CROSS;
         else                           g_entry_wait = WAIT_SELL_FILTER;
      }
      else g_entry_wait = WAIT_SELL_FILTER;
   }

   g_prev_fast  = fast_rel;
   g_prev_price = price_rel;
}
//+------------------------------------------------------------------+
