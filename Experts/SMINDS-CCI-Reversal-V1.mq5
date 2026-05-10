//+------------------------------------------------------------------+
//|                                  SMINDS-CCI-Reversal-V1.mq5      |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #15 (CCI Extreme Reversal)                |
//|                                                                  |
//|  CCI = (TP - SMA(TP)) / (0.015 × MAD), unbounded oscillator.     |
//|  Extreme readings (±200) are statistically rare — fading them    |
//|  has historical edge in non-trending environments.               |
//|                                                                  |
//|  Strategy:                                                       |
//|    Long:  CCI was below -200 (extreme oversold) within last      |
//|           N bars AND has now crossed back above -100.            |
//|    Short: CCI was above +200 within last N bars AND has now      |
//|           crossed back below +100.                               |
//|    Range filter: only trade when ADX < 25 (no strong trend).     |
//|    SL: ATR-based; TP: 1.5×SL (mean rev moves quickly).           |
//|                                                                  |
//|  Differs from RSI-MeanRev: CCI is unbounded (responds to extreme |
//|  moves more quickly), uses typical price (HLC/3) not just close. |
//|                                                                  |
//|  Strategy class: COUNTER-TREND OSCILLATOR EXTREMES               |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS CCI Reversal V1 — counter-trend on extreme CCI readings"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97500001;
input string InpOrderComment      = "SMINDS-CCI-V1";

input group "═══ CCI Trigger ══════════════════════════════════"
input int    InpCCIPeriod         = 20;
input double InpExtremeThreshold  = 200.0;            // |CCI| above this = extreme
input double InpExitZone          = 100.0;            // CCI crosses back through this = entry
input int    InpExtremeLookback   = 4;                // Look back N bars for extreme reading

input group "═══ Range Filter ═══════════════════════════════"
input bool   InpUseADXFilter      = true;
input int    InpADXPeriod         = 14;
input double InpMaxADX            = 25.0;            // CCI mean rev fails in trends; ADX must be LOW

input group "═══ Entry Confirmation ═══════════════════════════"
input bool   InpRequireBodyClose  = true;
input double InpMinBodyATR        = 0.25;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLATRMult         = 1.5;
input double InpRRRatio           = 1.5;

input group "═══ Position Sizing ═════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 2.5;
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
input int    InpMaxHoldBars       = 30;

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 7;
input int    InpSessionEndHour    = 20;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 70;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

#define EA_TAG    "SMINDS-CCI-V1"
#define GV_PREFIX "SMCCI1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_cci      = INVALID_HANDLE;
int g_h_adx      = INVALID_HANDLE;
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

string g_gv_consec  = "";
string g_gv_breaker = "";

void LogInfo (string m) { PrintFormat("[%s] %s", EA_TAG, m); }
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
   for(int i = 0; i <= 8; i++) { double s = step * MathPow(10.0, i); if(MathAbs(s - MathRound(s)) < 1e-8){ d = i; break; } }
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
bool IsSpreadOK() { if(InpMaxSpreadPoints <= 0) return true; return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints; }

bool IsTradeAllowed()
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
      g_today = today; g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE); g_today_trades = 0;
      return false;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily_start_bal <= 0.0) return false;
   double pct = (g_daily_start_bal - eq) / g_daily_start_bal * 100.0;
   return (pct >= InpMaxDailyLossPct);
}

bool IsCooldownActive() { return (InpUseCooldown && g_last_loss && g_bars_since_loss < InpCooldownBars); }
bool IsLossBreakerActive()
{
   if(!InpUseLossBreaker) return false;
   if(g_consec_losses < InpMaxConsecLosses) return false;
   datetime today = DayStart(TimeCurrent());
   return (g_breaker_day != 0 && today <= g_breaker_day);
}
bool IsDailyTradeLimitReached()
{
   if(InpMaxTradesPerDay <= 0) return false;
   datetime today = DayStart(TimeCurrent());
   if(today != g_today) { g_today = today; g_today_trades = 0; g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE); }
   return (g_today_trades >= InpMaxTradesPerDay);
}

//+------------------------------------------------------------------+
//| CCI signal detection                                              |
//+------------------------------------------------------------------+
// Returns +1 long, -1 short, 0 none
int DetectCCISignal()
{
   double cci_now, cci_prev;
   if(!ReadBuf(g_h_cci, 0, 1, cci_now)) return 0;
   if(!ReadBuf(g_h_cci, 0, 2, cci_prev)) return 0;

   // Long signal: CCI hit -InpExtreme within lookback, now crossing UP through -InpExitZone
   if(cci_prev <= -InpExitZone && cci_now > -InpExitZone)
   {
      // Check that CCI was at extreme oversold within lookback bars
      bool was_extreme = false;
      for(int s = 1; s <= InpExtremeLookback; s++)
      {
         double c = 0.0;
         if(!ReadBuf(g_h_cci, 0, s, c)) continue;
         if(c <= -InpExtremeThreshold) { was_extreme = true; break; }
      }
      if(was_extreme) return +1;
   }
   // Short signal: CCI hit +InpExtreme within lookback, now crossing DOWN through +InpExitZone
   if(cci_prev >= InpExitZone && cci_now < InpExitZone)
   {
      bool was_extreme = false;
      for(int s = 1; s <= InpExtremeLookback; s++)
      {
         double c = 0.0;
         if(!ReadBuf(g_h_cci, 0, s, c)) continue;
         if(c >= InpExtremeThreshold) { was_extreme = true; break; }
      }
      if(was_extreme) return -1;
   }
   return 0;
}

bool IsRangeRegime()
{
   if(!InpUseADXFilter) return true;
   double adx = 0.0;
   if(!ReadBuf(g_h_adx, 0, 0, adx)) return false;
   return (adx < InpMaxADX);
}

bool DetectConfirmation(int dir, double atr)
{
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;
   double body = MathAbs(closes[1] - opens[1]);
   if(InpRequireBodyClose && body < atr * InpMinBodyATR) return false;
   if(dir > 0 && closes[1] <= opens[1]) return false;
   if(dir < 0 && closes[1] >= opens[1]) return false;
   return true;
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
   if(is_buy) { double max_sl = ref - mind; if(sl > max_sl) return NormalizeDouble(max_sl, digits); }
   else       { double min_sl = ref + mind; if(sl < min_sl) return NormalizeDouble(min_sl, digits); }
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

bool OpenTrade(int dir, double atr)
{
   if(!IsSpreadOK()) return false;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = (dir > 0) ? ask : bid;
   double sl_dist = atr * InpSLATRMult;
   double sl, tp;
   if(dir > 0)
   {
      sl = NormalizeDouble(entry - sl_dist, digits);
      sl = EnforceMinStop(sl, entry, true);
      tp = NormalizeDouble(entry + (entry - sl) * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(entry + sl_dist, digits);
      sl = EnforceMinStop(sl, entry, false);
      tp = NormalizeDouble(entry - (sl - entry) * InpRRRatio, digits);
   }
   double real_sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(real_sl_dist);
   if(vol <= 0.0) return false;
   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f atr=%.5f",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, atr));
   }
   return ok;
}

bool ClosePosition(ulong ticket)
{
   for(int a = 1; a <= InpMaxRetries; a++)
   {
      if(g_trade.PositionClose(ticket)) return true;
      Sleep(InpRetryDelayMs); g_sym.RefreshRates();
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
      total += HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
   }
   if(total < 0.0)
   {
      g_last_loss = true; g_bars_since_loss = 0; g_consec_losses++;
      if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses) g_breaker_day = DayStart(TimeCurrent());
   }
   else { g_last_loss = false; g_bars_since_loss = 9999; g_consec_losses = 0; g_breaker_day = 0; }
   StateSave();
}

void CheckTimeStop(ulong ticket, datetime open_time)
{
   if(!InpUseTimeStop || open_time == 0) return;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, times) != 1) return;
   long held = (long)((times[0] - open_time) / PeriodSeconds(g_tf));
   if(held >= InpMaxHoldBars) { if(ClosePosition(ticket)) RecordTradeResult(ticket); }
}

int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;
   g_h_cci = iCCI(_Symbol, g_tf, InpCCIPeriod, PRICE_TYPICAL);
   g_h_adx = iADX(_Symbol, g_tf, InpADXPeriod);
   g_h_atr = iATR(_Symbol, g_tf, InpATRPeriod);
   if(g_h_cci == INVALID_HANDLE || g_h_adx == INVALID_HANDLE || g_h_atr == INVALID_HANDLE) return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   if(MQLInfoInteger(MQL_TESTER)) { GlobalVariableDel(g_gv_consec); GlobalVariableDel(g_gv_breaker); g_consec_losses=0; g_breaker_day=0; }
   else StateLoad();
   g_today = DayStart(TimeCurrent());
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   LogInfo(StringFormat("INIT %s/%s magic=%lld CCI(%d) extreme=±%.0f exit=±%.0f ADX<%.0f Risk=%.1f%%",
           _Symbol, EnumToString(g_tf), InpMagicNumber, InpCCIPeriod,
           InpExtremeThreshold, InpExitZone, InpMaxADX, InpRiskPercent));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_cci != INVALID_HANDLE) IndicatorRelease(g_h_cci);
   if(g_h_adx != INVALID_HANDLE) IndicatorRelease(g_h_adx);
   if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
}

void OnTick()
{
   bool new_bar = IsNewBar();
   if(new_bar && g_last_loss && g_bars_since_loss < 9999) g_bars_since_loss++;

   ulong ticket = 0; long ptype = -1; datetime opened = 0;
   bool has_pos = FindOurPosition(ticket, ptype, opened);
   if(has_pos) { g_open_ticket = ticket; CheckTimeStop(ticket, opened); return; }
   if(g_open_ticket != 0) { RecordTradeResult(g_open_ticket); g_open_ticket = 0; }

   if(!new_bar) return;
   if(!IsTradeAllowed())          return;
   if(IsDailyLossBreached())      return;
   if(IsCooldownActive())         return;
   if(IsLossBreakerActive())      return;
   if(IsDailyTradeLimitReached()) return;
   if(!IsRangeRegime())           return;

   int dir = DetectCCISignal();
   if(dir == 0) return;

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;
   if(!DetectConfirmation(dir, atr)) return;

   OpenTrade(dir, atr);
}
//+------------------------------------------------------------------+
