//+------------------------------------------------------------------+
//|                                  SMINDS-MTC-V1.mq5               |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #8 (Multi-Timeframe Confluence)           |
//|                                                                  |
//|  Triple-screen style — Elder-derived, requires alignment across  |
//|  three timeframes:                                                |
//|                                                                  |
//|    H4 macro    : EMA50 slope and price location (trend bias)     |
//|    H1 trend    : EMA20 above/below EMA50 (intermediate filter)   |
//|    M15 entry   : pullback to M15 EMA20 + bullish/bearish close    |
//|                                                                  |
//|  All three must agree before a trade fires. This is the most     |
//|  selective strategy in the factory and is intended to fire 1-3   |
//|  times per week per symbol but with very high signal quality.    |
//|                                                                  |
//|  Strategy class: MULTI-TIMEFRAME TREND CONFLUENCE                |
//|  (uncorrelated with single-TF EAs because HTF disagreement       |
//|  blocks ~70% of low-quality setups our other EAs would take)     |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Multi-TF Confluence V1 — multi-symbol M15 entry"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96800001;
input string InpOrderComment      = "SMINDS-MTC-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_M15;   // EA runs on M15 (entries)

input group "═══ H4 Macro Trend ══════════════════════════════"
input int    InpH4EMAPeriod       = 50;
input int    InpH4SlopeBars       = 6;

input group "═══ H1 Intermediate Trend ════════════════════════"
input int    InpH1FastEMA         = 20;
input int    InpH1SlowEMA         = 50;

input group "═══ M15 Entry Trigger ════════════════════════════"
input int    InpM15FastEMA        = 20;              // Pullback target
input int    InpPullbackBars      = 6;               // Look back N bars for EMA touch
input bool   InpRequireEMATouch   = true;            // Bar low/high must reach EMA20
input bool   InpRequireBodyClose  = true;            // Bullish/bearish body confirmation

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;            // SL buffer beyond pullback swing
input double InpRRRatio           = 2.0;
input bool   InpUseTrailingTP     = true;
input double InpTrailActivateR    = 1.0;
input double InpTrailDistanceR    = 0.5;

input group "═══ Position Sizing ════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 1.5;
input double InpLotSize           = 0.10;
input double InpMaxLotSize        = 5.00;
input double InpMinLotSize        = 0.01;

input group "═══ Risk Circuit Breakers ════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 3;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 6;
input int    InpMaxTradesPerDay   = 3;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 60;

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 7;
input int    InpSessionEndHour    = 20;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 60;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-MTC-V1"
#define GV_PREFIX "SMMTC1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr      = INVALID_HANDLE;
int g_h_h4_ema   = INVALID_HANDLE;
int g_h_h1_fast  = INVALID_HANDLE;
int g_h_h1_slow  = INVALID_HANDLE;
int g_h_m15_fast = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;
datetime        g_today    = 0;
double          g_daily_start_bal = 0.0;
int             g_today_trades    = 0;

bool     g_last_loss       = false;
int      g_bars_since_loss = 9999;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;

ulong    g_open_ticket     = 0;
double   g_open_entry      = 0.0;
double   g_open_initial_sl = 0.0;
int      g_open_dir        = 0;

string g_gv_consec  = "";
string g_gv_breaker = "";

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
void LogInfo (string m) { PrintFormat("[%s] %s", EA_TAG, m); }
void LogWarn (string m) { PrintFormat("[%s] WARN: %s", EA_TAG, m); }
void LogError(string m) { PrintFormat("[%s] ERROR: %s", EA_TAG, m); }
void LogDebug(string m) { if(InpVerbose) PrintFormat("[%s] %s", EA_TAG, m); }

//+------------------------------------------------------------------+
//| Persistence                                                       |
//+------------------------------------------------------------------+
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_consec))  g_consec_losses = (int)GlobalVariableGet(g_gv_consec);
   if(GlobalVariableCheck(g_gv_breaker)) g_breaker_day   = (datetime)(long)GlobalVariableGet(g_gv_breaker);
}
void StateSave()
{
   GlobalVariableSet(g_gv_consec,  (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)(long)g_breaker_day);
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime bars[]; ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, bars) != 1) return false;
   if(g_last_bar == 0){ g_last_bar = bars[0]; return false; }
   if(bars[0] != g_last_bar){ g_last_bar = bars[0]; return true; }
   return false;
}

bool ReadBuf(int handle, int buf_idx, int shift, double &v)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int n = shift + 1;
   if(CopyBuffer(handle, buf_idx, 0, n, buf) != n) return false;
   v = buf[shift];
   return MathIsValidNumber(v);
}

double NormalizeVol(double x)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || minv <= 0.0) return 0.0;
   double clipped = MathMax(minv, MathMin(maxv, x));
   int d = 2;
   for(int i = 0; i <= 8; i++)
   {
      double s = step * MathPow(10.0, i);
      if(MathAbs(s - MathRound(s)) < 1e-8){ d = i; break; }
   }
   return NormalizeDouble(MathFloor(clipped / step) * step, d);
}

double ComputeLotSize(double sl_distance_price)
{
   double base_lot = InpLotSize;
   if(InpUseRiskBasedLot && sl_distance_price > 0.0)
   {
      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk_amt   = equity * (InpRiskPercent / 100.0);
      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size > 0.0 && tick_value > 0.0 && risk_amt > 0.0)
      {
         double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
         if(loss_per_lot > 0.0) base_lot = risk_amt / loss_per_lot;
      }
      if(base_lot <= 0.0) base_lot = InpLotSize;
   }
   double clamped = MathMax(InpMinLotSize, MathMin(InpMaxLotSize, base_lot));
   return NormalizeVol(clamped);
}

bool FindOurPosition(ulong &ticket, long &type, datetime &open_time)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ticket = t;
         type   = PositionGetInteger(POSITION_TYPE);
         open_time = (datetime)PositionGetInteger(POSITION_TIME);
         return true;
      }
   }
   ticket = 0; type = -1; open_time = 0;
   return false;
}

datetime DayStart(datetime t) { return (datetime)((long)t / 86400 * 86400); }

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Risk gates                                                        |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if(!InpUseSession) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

bool IsDailyLossBreached()
{
   if(!InpUseDailyLossLimit) return false;
   datetime today = DayStart(TimeCurrent());
   if(today != g_today)
   {
      g_today = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_today_trades = 0;
      return false;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily_start_bal <= 0.0) return false;
   double pct = (g_daily_start_bal - eq) / g_daily_start_bal * 100.0;
   return (pct >= InpMaxDailyLossPct);
}

bool IsCooldownActive()
{
   if(!InpUseCooldown) return false;
   return (g_last_loss && g_bars_since_loss < InpCooldownBars);
}

bool IsLossBreakerActive()
{
   if(!InpUseLossBreaker) return false;
   if(g_consec_losses < InpMaxConsecLosses) return false;
   datetime today = DayStart(TimeCurrent());
   if(g_breaker_day == 0) return false;
   return (today <= g_breaker_day);
}

bool IsDailyTradeLimitReached()
{
   if(InpMaxTradesPerDay <= 0) return false;
   datetime today = DayStart(TimeCurrent());
   if(today != g_today)
   {
      g_today = today;
      g_today_trades = 0;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   return (g_today_trades >= InpMaxTradesPerDay);
}

//+------------------------------------------------------------------+
//| Multi-TF trend reads                                              |
//+------------------------------------------------------------------+
// H4 macro: returns +1 (up) / -1 (down) / 0 (mixed)
int GetH4Trend()
{
   double ema_now = 0.0, ema_old = 0.0;
   if(!ReadBuf(g_h_h4_ema, 0, 0, ema_now)) return 0;
   if(!ReadBuf(g_h_h4_ema, 0, InpH4SlopeBars, ema_old)) return 0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool slope_up   = ema_now > ema_old;
   bool slope_down = ema_now < ema_old;
   bool price_up   = price > ema_now;
   bool price_down = price < ema_now;
   if(slope_up && price_up)     return  1;
   if(slope_down && price_down) return -1;
   return 0;
}

// H1 intermediate: fast EMA vs slow EMA
int GetH1Trend()
{
   double fast = 0.0, slow = 0.0;
   if(!ReadBuf(g_h_h1_fast, 0, 0, fast)) return 0;
   if(!ReadBuf(g_h_h1_slow, 0, 0, slow)) return 0;
   if(fast > slow) return  1;
   if(fast < slow) return -1;
   return 0;
}

// M15 pullback detection (current TF)
bool DetectPullback(int dir, double atr, double &swing_extreme)
{
   double lows[], highs[];
   ArraySetAsSeries(lows, true); ArraySetAsSeries(highs, true);
   if(CopyLow (_Symbol, g_tf, 0, InpPullbackBars + 1, lows)  != InpPullbackBars + 1) return false;
   if(CopyHigh(_Symbol, g_tf, 0, InpPullbackBars + 1, highs) != InpPullbackBars + 1) return false;

   bool touched = false;
   double extreme = (dir > 0) ? DBL_MAX : 0.0;

   for(int s = 1; s <= InpPullbackBars; s++)
   {
      double ema_s = 0.0;
      if(!ReadBuf(g_h_m15_fast, 0, s, ema_s)) continue;
      if(dir > 0)
      {
         if(lows[s] <= ema_s) touched = true;
         else if(!InpRequireEMATouch && (lows[s] - ema_s) <= atr * 0.5) touched = true;
         if(lows[s] < extreme) extreme = lows[s];
      }
      else
      {
         if(highs[s] >= ema_s) touched = true;
         else if(!InpRequireEMATouch && (ema_s - highs[s]) <= atr * 0.5) touched = true;
         if(highs[s] > extreme) extreme = highs[s];
      }
   }
   swing_extreme = extreme;
   return touched;
}

// M15 confirmation: bar 1 closed above EMA20 (long) / below (short) with body
bool DetectConfirmation(int dir, double atr)
{
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;
   double ema1 = 0.0;
   if(!ReadBuf(g_h_m15_fast, 0, 1, ema1)) return false;

   double body = MathAbs(closes[1] - opens[1]);
   if(body < atr * 0.3 && InpRequireBodyClose) return false;

   if(dir > 0)
   {
      if(closes[1] <= ema1) return false;
      if(InpRequireBodyClose && closes[1] <= opens[1]) return false;
      return true;
   }
   else
   {
      if(closes[1] >= ema1) return false;
      if(InpRequireBodyClose && closes[1] >= opens[1]) return false;
      return true;
   }
}

//+------------------------------------------------------------------+
//| Trade ops                                                         |
//+------------------------------------------------------------------+
double EnforceMinStop(double sl, double ref, bool is_buy)
{
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops <= 0) return sl;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double mind  = stops * point;
   int    digits= (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(is_buy)
   {
      double max_sl = ref - mind;
      if(sl > max_sl) return NormalizeDouble(max_sl, digits);
   }
   else
   {
      double min_sl = ref + mind;
      if(sl < min_sl) return NormalizeDouble(min_sl, digits);
   }
   return sl;
}

bool ExecOrder(bool is_buy, double vol, double sl, double tp)
{
   for(int a = 1; a <= InpMaxRetries; a++)
   {
      bool ok = is_buy ? g_trade.Buy (vol, _Symbol, 0.0, sl, tp, InpOrderComment)
                       : g_trade.Sell(vol, _Symbol, 0.0, sl, tp, InpOrderComment);
      if(ok) return true;
      uint rc = g_trade.ResultRetcode();
      LogWarn(StringFormat("%s rc=%u (%s)", is_buy ? "Buy" : "Sell", rc, g_trade.ResultRetcodeDescription()));
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME) return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool OpenTrade(int dir, double swing_extreme, double atr)
{
   if(!IsSpreadOK()) return false;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double buffer = atr * InpSLBufferATR;
   double sl, tp;

   if(dir > 0)
   {
      sl = NormalizeDouble(swing_extreme - buffer, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(swing_extreme + buffer, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry - dist * InpRRRatio, digits);
   }

   double sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(sl_dist);
   if(vol <= 0.0) return false;

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      g_open_dir       = dir;
      g_open_entry     = entry;
      g_open_initial_sl= sl;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f atr=%.5f #%d/day",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, atr, g_today_trades));
   }
   return ok;
}

bool ClosePosition(ulong ticket)
{
   for(int a = 1; a <= InpMaxRetries; a++)
   {
      if(g_trade.PositionClose(ticket)) return true;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

void RecordTradeResult(ulong ticket)
{
   if(!HistorySelectByPosition(ticket)) return;
   int n = HistoryDealsTotal(); if(n < 1) return;
   double total = 0.0;
   for(int i = 0; i < n; i++)
   {
      ulong dt = HistoryDealGetTicket(i); if(dt == 0) continue;
      total += HistoryDealGetDouble(dt, DEAL_PROFIT)
             + HistoryDealGetDouble(dt, DEAL_SWAP)
             + HistoryDealGetDouble(dt, DEAL_COMMISSION);
   }
   if(total < 0.0)
   {
      g_last_loss = true;
      g_bars_since_loss = 0;
      g_consec_losses++;
      if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
      {
         g_breaker_day = DayStart(TimeCurrent());
      }
      LogInfo(StringFormat("Loss %.2f. Consec=%d", total, g_consec_losses));
   }
   else
   {
      g_last_loss = false;
      g_bars_since_loss = 9999;
      g_consec_losses = 0;
      g_breaker_day = 0;
   }
   StateSave();
}

void ApplyTrail(ulong ticket)
{
   if(!InpUseTrailingTP) return;
   if(!PositionSelectByTicket(ticket)) return;
   if(g_open_initial_sl == 0.0 || g_open_entry == 0.0 || g_open_dir == 0) return;

   double cur_sl = PositionGetDouble(POSITION_SL);
   double cur_tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double initial_dist = MathAbs(g_open_entry - g_open_initial_sl);
   if(initial_dist <= 0.0) return;

   double favor;
   if(g_open_dir > 0) favor = bid - g_open_entry;
   else               favor = g_open_entry - ask;
   if(favor <= 0.0) return;

   double r_progress = favor / initial_dist;
   if(r_progress < InpTrailActivateR) return;

   double trail_dist = initial_dist * InpTrailDistanceR;
   double new_sl;
   if(g_open_dir > 0)
   {
      new_sl = NormalizeDouble(bid - trail_dist, digits);
      if(new_sl > cur_sl) g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
   else
   {
      new_sl = NormalizeDouble(ask + trail_dist, digits);
      if(cur_sl == 0.0 || new_sl < cur_sl) g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
}

void CheckTimeStop(ulong ticket, datetime open_time)
{
   if(!InpUseTimeStop || open_time == 0) return;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, times) != 1) return;
   long held = (long)((times[0] - open_time) / PeriodSeconds(g_tf));
   if(held >= InpMaxHoldBars)
   {
      LogInfo(StringFormat("Time stop after %d bars", (int)held));
      if(ClosePosition(ticket)) RecordTradeResult(ticket);
   }
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(InpRequireTF != PERIOD_CURRENT && g_tf != InpRequireTF)
   { LogError(StringFormat("Timeframe must be %s", EnumToString(InpRequireTF))); return INIT_FAILED; }

   if(!g_sym.Name(_Symbol)){ LogError("CSymbolInfo init failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)){ LogError("SymbolSelect failed"); return INIT_FAILED; }

   g_h_atr      = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_h4_ema   = iMA (_Symbol, PERIOD_H4,  InpH4EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_h1_fast  = iMA (_Symbol, PERIOD_H1,  InpH1FastEMA,   0, MODE_EMA, PRICE_CLOSE);
   g_h_h1_slow  = iMA (_Symbol, PERIOD_H1,  InpH1SlowEMA,   0, MODE_EMA, PRICE_CLOSE);
   g_h_m15_fast = iMA (_Symbol, g_tf,       InpM15FastEMA,  0, MODE_EMA, PRICE_CLOSE);
   if(g_h_atr == INVALID_HANDLE || g_h_h4_ema == INVALID_HANDLE ||
      g_h_h1_fast == INVALID_HANDLE || g_h_h1_slow == INVALID_HANDLE ||
      g_h_m15_fast == INVALID_HANDLE)
   { LogError("Indicator handle failed"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(g_gv_consec);
      GlobalVariableDel(g_gv_breaker);
      g_consec_losses = 0;
      g_breaker_day = 0;
   }
   else StateLoad();

   g_today           = DayStart(TimeCurrent());
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("Triple-screen: H4 EMA%d slope (%dbars)  H1 EMA%d/%d  M15 EMA%d pullback",
           InpH4EMAPeriod, InpH4SlopeBars, InpH1FastEMA, InpH1SlowEMA, InpM15FastEMA));
   LogInfo(StringFormat("R:R=%.1f  SLbuf=%.2fxATR  Trail=%s  Risk=%.1f%%",
           InpRRRatio, InpSLBufferATR,
           InpUseTrailingTP ? "ON" : "OFF", InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr      != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_h4_ema   != INVALID_HANDLE) IndicatorRelease(g_h_h4_ema);
   if(g_h_h1_fast  != INVALID_HANDLE) IndicatorRelease(g_h_h1_fast);
   if(g_h_h1_slow  != INVALID_HANDLE) IndicatorRelease(g_h_h1_slow);
   if(g_h_m15_fast != INVALID_HANDLE) IndicatorRelease(g_h_m15_fast);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   bool new_bar = IsNewBar();
   if(new_bar && g_last_loss && g_bars_since_loss < 9999) g_bars_since_loss++;

   ulong ticket = 0; long ptype = -1; datetime opened = 0;
   bool has_pos = FindOurPosition(ticket, ptype, opened);
   if(has_pos)
   {
      g_open_ticket = ticket;
      ApplyTrail(ticket);
      CheckTimeStop(ticket, opened);
      return;
   }
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
   }

   if(!new_bar) return;

   // Risk gates
   if(!IsSessionAllowed())     return;
   if(IsDailyLossBreached())   return;
   if(IsCooldownActive())      return;
   if(IsLossBreakerActive())   return;
   if(IsDailyTradeLimitReached()) return;

   // Triple-screen alignment
   int h4_dir = GetH4Trend();
   if(h4_dir == 0) return;
   int h1_dir = GetH1Trend();
   if(h1_dir == 0) return;
   if(h1_dir != h4_dir) return;

   int dir = h4_dir;

   // ATR
   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   // M15 pullback to EMA20
   double swing = 0.0;
   if(!DetectPullback(dir, atr, swing)) return;

   // M15 confirmation candle
   if(!DetectConfirmation(dir, atr)) return;

   OpenTrade(dir, swing, atr);
}
//+------------------------------------------------------------------+
