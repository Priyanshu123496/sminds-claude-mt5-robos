//+------------------------------------------------------------------+
//|                                  SMINDS-Donchian-V1.mq5          |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #7 (Donchian Channel Breakout)            |
//|                                                                  |
//|  Classic Turtle Traders system (Dennis/Eckhardt 1983):           |
//|    - Long when price closes above N-bar highest high             |
//|    - Short when price closes below N-bar lowest low              |
//|    - Exit at opposite M-bar Donchian (M < N for trailing exit)   |
//|                                                                  |
//|  Adapted with:                                                   |
//|    - Optional ATR-based hard SL                                  |
//|    - Trend-aligned filter (HTF EMA50)                            |
//|    - Risk-based sizing                                           |
//|                                                                  |
//|  Designed for indices (NAS100, US30, SPX500) where strong        |
//|  directional moves persist longer, but works on forex too.       |
//|                                                                  |
//|  Strategy class: TREND BREAKOUT (different from EMA-crossover    |
//|  trend follower in TTR-XI — captures explosive moves AT inception|
//|  rather than confirming via moving averages).                    |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Donchian Breakout V1 — multi-symbol"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96700001;
input string InpOrderComment      = "SMINDS-DON-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT;

input group "═══ Donchian Channels ═══════════════════════════"
input int    InpEntryPeriod       = 20;              // Breakout lookback for entry (Turtle: 20)
input int    InpExitPeriod        = 10;              // Reverse Donchian for exit (Turtle: 10)
input bool   InpRequireCloseBreak = true;            // Close beyond, vs intra-bar break

input group "═══ Volatility / SL ══════════════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLATRMult         = 2.0;             // Hard SL = entry ± ATR × this
input bool   InpUseATRSL          = true;
input bool   InpUseDonchianExit   = true;            // Exit on opposite Donchian

input group "═══ Trend Filter ═════════════════════════════════"
input bool   InpUseHTFFilter      = true;
input ENUM_TIMEFRAMES InpHTFPeriod= PERIOD_H4;
input int    InpHTFEMAPeriod      = 50;
input int    InpHTFSlopeBars      = 6;

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
input int    InpMaxConsecLosses   = 4;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 4;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = false;           // Trend strategies should let runners go
input int    InpMaxHoldBars       = 200;

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = false;           // Indices have varying hours; off by default
input int    InpSessionStartHour  = 6;
input int    InpSessionEndHour    = 22;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 100;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-DON-V1"
#define GV_PREFIX "SMDON1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr      = INVALID_HANDLE;
int g_h_htf_ema  = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;
datetime        g_today    = 0;
double          g_daily_start_bal = 0.0;

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

//+------------------------------------------------------------------+
//| Donchian channel                                                  |
//+------------------------------------------------------------------+
// Compute highest high / lowest low over the previous N bars,
// EXCLUDING the bar being tested (shift 1) to avoid trivial self-reference.
// start_shift = 2 means: bars 2, 3, ..., 2+period-1 (the period-many bars
// BEFORE the bar that just closed at shift 1).
bool DonchianBounds(int period, double &hi, double &lo, int start_shift = 2)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, g_tf, start_shift, period, highs) != period) return false;
   if(CopyLow (_Symbol, g_tf, start_shift, period, lows ) != period) return false;
   hi = -DBL_MAX; lo = DBL_MAX;
   for(int i = 0; i < period; i++)
   {
      if(highs[i] > hi) hi = highs[i];
      if(lows[i]  < lo) lo = lows[i];
   }
   return (hi > 0 && lo > 0);
}

//+------------------------------------------------------------------+
//| HTF trend                                                         |
//+------------------------------------------------------------------+
int GetHTFTrend()
{
   if(!InpUseHTFFilter) return 0;
   double ema_now = 0.0, ema_old = 0.0;
   if(!ReadBuf(g_h_htf_ema, 0, 0, ema_now)) return 0;
   if(!ReadBuf(g_h_htf_ema, 0, InpHTFSlopeBars, ema_old)) return 0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool slope_up   = ema_now > ema_old;
   bool slope_down = ema_now < ema_old;
   bool price_up   = price > ema_now;
   bool price_down = price < ema_now;
   if(slope_up && price_up)     return  1;
   if(slope_down && price_down) return -1;
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
      LogWarn(StringFormat("%s rc=%u (%s)", is_buy ? "Buy" : "Sell", rc, g_trade.ResultRetcodeDescription()));
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
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;

   double sl = 0.0, tp = 0.0;
   if(InpUseATRSL)
   {
      double sl_dist = atr * InpSLATRMult;
      if(dir > 0)
      {
         sl = NormalizeDouble(entry - sl_dist, digits);
         sl = EnforceMinStop(sl, entry, true);
      }
      else
      {
         sl = NormalizeDouble(entry + sl_dist, digits);
         sl = EnforceMinStop(sl, entry, false);
      }
   }
   // No fixed TP — Donchian-exit handles take-profit (let trends run)

   double sl_dist = MathAbs(entry - sl);
   if(InpUseATRSL && sl_dist <= 0.0) return false;
   double vol = ComputeLotSize(InpUseATRSL ? sl_dist : (atr * InpSLATRMult));
   if(vol <= 0.0) return false;

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_open_dir       = dir;
      g_open_entry     = entry;
      g_open_initial_sl= sl;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f atr=%.5f",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, atr));
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

// Donchian trailing exit: close long when price closes below M-bar low,
// close short when price closes above M-bar high
void CheckDonchianExit(ulong ticket, long pos_type)
{
   if(!InpUseDonchianExit) return;
   double exit_hi, exit_lo;
   if(!DonchianBounds(InpExitPeriod, exit_hi, exit_lo)) return;
   double closes[]; ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return;
   double last_close = closes[1];

   if(pos_type == POSITION_TYPE_BUY && last_close < exit_lo)
   {
      LogInfo(StringFormat("Donchian exit (long): close %.5f < %d-low %.5f", last_close, InpExitPeriod, exit_lo));
      if(ClosePosition(ticket)) RecordTradeResult(ticket);
   }
   else if(pos_type == POSITION_TYPE_SELL && last_close > exit_hi)
   {
      LogInfo(StringFormat("Donchian exit (short): close %.5f > %d-high %.5f", last_close, InpExitPeriod, exit_hi));
      if(ClosePosition(ticket)) RecordTradeResult(ticket);
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

   if(InpEntryPeriod < 5 || InpExitPeriod < 3 || InpExitPeriod >= InpEntryPeriod)
   { LogError("Donchian periods invalid (entry > exit > 3)"); return INIT_PARAMETERS_INCORRECT; }

   g_h_atr     = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_htf_ema = iMA (_Symbol, InpHTFPeriod, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_h_atr == INVALID_HANDLE || g_h_htf_ema == INVALID_HANDLE)
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
   LogInfo(StringFormat("Donchian: entry=%d-bar  exit=%d-bar  CloseBreak=%s",
           InpEntryPeriod, InpExitPeriod, InpRequireCloseBreak ? "Y" : "N"));
   LogInfo(StringFormat("HTF=%s/EMA%d  SL=ATRx%.1f (%s)  Risk=%.1f%%",
           EnumToString(InpHTFPeriod), InpHTFEMAPeriod, InpSLATRMult,
           InpUseATRSL ? "ON" : "OFF", InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr      != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_htf_ema  != INVALID_HANDLE) IndicatorRelease(g_h_htf_ema);
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
      if(new_bar) CheckDonchianExit(ticket, ptype);
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

   // Donchian channel (entry period)
   double don_hi, don_lo;
   if(!DonchianBounds(InpEntryPeriod, don_hi, don_lo)) return;

   // ATR
   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   // Detect breakout — last completed bar closed beyond Donchian
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return;

   int dir = 0;
   if(InpRequireCloseBreak)
   {
      if(closes[1] > don_hi)      dir = +1;
      else if(closes[1] < don_lo) dir = -1;
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > don_hi)      dir = +1;
      else if(bid < don_lo) dir = -1;
   }
   if(dir == 0) return;

   // HTF alignment
   if(InpUseHTFFilter)
   {
      int htf_dir = GetHTFTrend();
      if(htf_dir == 0) return;
      if(dir != htf_dir) return;
   }

   OpenTrade(dir, atr);
}
//+------------------------------------------------------------------+
