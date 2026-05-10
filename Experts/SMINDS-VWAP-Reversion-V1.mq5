//+------------------------------------------------------------------+
//|                                  SMINDS-VWAP-Reversion-V1.mq5    |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #12 (VWAP Intraday Reversion)             |
//|                                                                  |
//|  VWAP = Volume-Weighted Average Price for the current session.   |
//|  Acts as an intraday "fair-value" magnet — institutional traders |
//|  use it as benchmark, so price tends to revert toward it.        |
//|                                                                  |
//|  Strategy:                                                       |
//|    1. Compute VWAP from session start (00:00 UTC by default).    |
//|    2. Compute σ-bands (VWAP ± k × stdev of price-VWAP residuals).|
//|    3. Long when price touches lower band AND bullish reversal.   |
//|    4. Short when price touches upper band AND bearish reversal.  |
//|    5. Exit when price returns to VWAP (mean reverted).            |
//|                                                                  |
//|  Strategy class: VWAP MEAN REVERSION                              |
//|  (intraday-specific, distinct from EMA-pullback because VWAP is  |
//|   volume-weighted and resets daily — different dynamics)         |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS VWAP Reversion V1 — intraday session-anchored mean reversion"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97200001;
input string InpOrderComment      = "SMINDS-VWAP-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT;

input group "═══ VWAP / Bands ═════════════════════════════════"
input int    InpSessionStartHour  = 0;               // VWAP resets at this UTC hour
input double InpBandStdMult       = 2.0;             // Bands at VWAP ± this × stdev
input int    InpMinBarsForVWAP    = 12;              // Min bars in session before trading

input group "═══ Entry Confirmation ═══════════════════════════"
input bool   InpRequireBodyClose  = true;            // Require reversal candle body
input double InpMinBodyATR        = 0.30;            // Min reversal body as fraction of ATR

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLATRMult         = 1.5;             // SL = entry ± ATR × this
input bool   InpExitAtVWAP        = true;            // TP at VWAP (mean reverted)
input double InpRRRatio           = 1.5;             // Used if not exiting at VWAP

input group "═══ Position Sizing ═════════════════════════════"
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
input int    InpMaxTradesPerDay   = 4;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 40;

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpTradeStartHour    = 7;
input int    InpTradeEndHour      = 20;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 70;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| State                                                             |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-VWAP-V1"
#define GV_PREFIX "SMVWAP1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr      = INVALID_HANDLE;

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

void LogInfo (string m) { PrintFormat("[%s] %s", EA_TAG, m); }
void LogWarn (string m) { PrintFormat("[%s] WARN: %s", EA_TAG, m); }
void LogError(string m) { PrintFormat("[%s] ERROR: %s", EA_TAG, m); }
void LogDebug(string m) { if(InpVerbose) PrintFormat("[%s] %s", EA_TAG, m); }

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

bool IsTradeAllowed()
{
   if(!InpUseSession) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= InpTradeStartHour && dt.hour < InpTradeEndHour);
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
//| VWAP computation                                                  |
//+------------------------------------------------------------------+
// Compute VWAP and stdev from session-start to bar 1 (last closed)
// VWAP = Σ(typical_price × tick_volume) / Σ(tick_volume)
// stdev = sqrt(Σ((tp - VWAP)² × vol) / Σvol)
bool ComputeVWAP(double &vwap, double &up_band, double &lo_band, int &session_bars)
{
   datetime now_t = TimeCurrent();
   datetime today_start = DayStart(now_t);
   datetime session_start_t = today_start + InpSessionStartHour * 3600;

   // Find the index of the first session bar
   int total = 1500;
   datetime times[]; double highs[], lows[], closes[];
   long volumes[];
   ArraySetAsSeries(times, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   ArraySetAsSeries(volumes, true);
   if(CopyTime  (_Symbol, g_tf, 0, total, times)   <= 0) return false;
   if(CopyHigh  (_Symbol, g_tf, 0, total, highs)   <= 0) return false;
   if(CopyLow   (_Symbol, g_tf, 0, total, lows)    <= 0) return false;
   if(CopyClose (_Symbol, g_tf, 0, total, closes)  <= 0) return false;
   if(CopyTickVolume(_Symbol, g_tf, 0, total, volumes) <= 0) return false;

   double sum_pv = 0.0, sum_v = 0.0;
   int bars_count = 0;
   int n = ArraySize(times);
   // Walk from oldest-of-window to newest, including bar 1
   for(int i = n - 1; i >= 1; i--)
   {
      if(times[i] < session_start_t) continue;
      double tp = (highs[i] + lows[i] + closes[i]) / 3.0;
      double v  = (double)volumes[i];
      if(v <= 0.0) v = 1.0;
      sum_pv += tp * v;
      sum_v  += v;
      bars_count++;
   }
   if(sum_v <= 0.0 || bars_count < InpMinBarsForVWAP) return false;
   vwap = sum_pv / sum_v;

   // Compute weighted stdev of typical price vs VWAP
   double sum_dev2 = 0.0;
   for(int i = n - 1; i >= 1; i--)
   {
      if(times[i] < session_start_t) continue;
      double tp = (highs[i] + lows[i] + closes[i]) / 3.0;
      double v  = (double)volumes[i];
      if(v <= 0.0) v = 1.0;
      double d = tp - vwap;
      sum_dev2 += d * d * v;
   }
   double std = MathSqrt(sum_dev2 / sum_v);
   up_band = vwap + InpBandStdMult * std;
   lo_band = vwap - InpBandStdMult * std;
   session_bars = bars_count;
   return true;
}

//+------------------------------------------------------------------+
//| Entry detection                                                   |
//+------------------------------------------------------------------+
// Check bar 1 (last closed) for reversal at band
//   Long  : low <= lo_band AND close > lo_band AND bullish body
//   Short : high >= up_band AND close < up_band AND bearish body
int DetectEntry(double up_band, double lo_band, double atr)
{
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return 0;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return 0;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return 0;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return 0;

   double body = MathAbs(closes[1] - opens[1]);
   if(InpRequireBodyClose && body < atr * InpMinBodyATR) return 0;

   if(lows[1] <= lo_band && closes[1] > lo_band)
   {
      if(InpRequireBodyClose && closes[1] <= opens[1]) return 0;
      return +1;
   }
   if(highs[1] >= up_band && closes[1] < up_band)
   {
      if(InpRequireBodyClose && closes[1] >= opens[1]) return 0;
      return -1;
   }
   return 0;
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
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME) return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool OpenTrade(int dir, double vwap, double atr)
{
   if(!IsSpreadOK()) return false;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double sl_dist = atr * InpSLATRMult;
   double sl, tp;

   if(dir > 0)
   {
      sl = NormalizeDouble(entry - sl_dist, digits);
      sl = EnforceMinStop(sl, entry, true);
      if(InpExitAtVWAP) tp = NormalizeDouble(vwap, digits);
      else              tp = NormalizeDouble(entry + (entry - sl) * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(entry + sl_dist, digits);
      sl = EnforceMinStop(sl, entry, false);
      if(InpExitAtVWAP) tp = NormalizeDouble(vwap, digits);
      else              tp = NormalizeDouble(entry - (sl - entry) * InpRRRatio, digits);
   }

   double real_sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(real_sl_dist);
   if(vol <= 0.0) return false;

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      g_open_dir       = dir;
      g_open_entry     = entry;
      g_open_initial_sl= sl;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f vwap=%.5f atr=%.5f #%d/day",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, vwap, atr, g_today_trades));
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
         g_breaker_day = DayStart(TimeCurrent());
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

void CheckTimeStop(ulong ticket, datetime open_time)
{
   if(!InpUseTimeStop || open_time == 0) return;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, times) != 1) return;
   long held = (long)((times[0] - open_time) / PeriodSeconds(g_tf));
   if(held >= InpMaxHoldBars)
   {
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
   { LogError("Wrong TF"); return INIT_FAILED; }
   if(g_tf > PERIOD_H1)
   { LogError("VWAP needs intraday TF (M5/M15/M30/H1)"); return INIT_FAILED; }

   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;

   g_h_atr = iATR(_Symbol, g_tf, InpATRPeriod);
   if(g_h_atr == INVALID_HANDLE) return INIT_FAILED;

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
   LogInfo(StringFormat("%s/%s  Magic=%lld  VWAP@%02d:00 UTC  bands ±%.1fσ  Risk=%.1f%%",
           _Symbol, EnumToString(g_tf), InpMagicNumber, InpSessionStartHour,
           InpBandStdMult, InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
}

void OnTick()
{
   bool new_bar = IsNewBar();
   if(new_bar && g_last_loss && g_bars_since_loss < 9999) g_bars_since_loss++;

   ulong ticket = 0; long ptype = -1; datetime opened = 0;
   bool has_pos = FindOurPosition(ticket, ptype, opened);
   if(has_pos)
   {
      g_open_ticket = ticket;
      CheckTimeStop(ticket, opened);
      return;
   }
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
   }

   if(!new_bar) return;

   if(!IsTradeAllowed())       return;
   if(IsDailyLossBreached())   return;
   if(IsCooldownActive())      return;
   if(IsLossBreakerActive())   return;
   if(IsDailyTradeLimitReached()) return;

   double vwap, up, lo;
   int sb;
   if(!ComputeVWAP(vwap, up, lo, sb)) return;

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   int dir = DetectEntry(up, lo, atr);
   if(dir == 0) return;

   OpenTrade(dir, vwap, atr);
}
//+------------------------------------------------------------------+
