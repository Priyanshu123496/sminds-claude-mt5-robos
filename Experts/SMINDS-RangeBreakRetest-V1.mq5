//+------------------------------------------------------------------+
//|                          SMINDS-RangeBreakRetest-V1.mq5          |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #10 (Range Break + Retest)                |
//|                                                                  |
//|  Classic price-action setup that filters false breakouts:        |
//|                                                                  |
//|     STATE MACHINE:                                                |
//|     IDLE -> RANGE_FOUND -> BREAK_OBSERVED -> RETEST_PENDING -> ENTRY
//|                                                                  |
//|     1. Detect tight consolidation range over last N bars.        |
//|     2. Wait for breakout (bar close beyond range + buffer).      |
//|     3. After break, watch for the broken level to be retested    |
//|        from the breakout side (e.g., for long: price comes back  |
//|        DOWN to within X×ATR of the broken range high).           |
//|     4. Confirm the hold: a bullish/bearish reversal candle       |
//|        forms at the retest, level holds (close back above /      |
//|        below the broken level).                                  |
//|     5. Enter — broken level is now confirmed support/resistance. |
//|                                                                  |
//|  Why this is different from our other breakout EAs:              |
//|     - London-BO    : enters IMMEDIATELY on session-range break   |
//|     - BB-Squeeze   : enters IMMEDIATELY on BB exit               |
//|     - Donchian     : enters IMMEDIATELY on N-bar break           |
//|     - THIS EA      : enters ON RETEST CONFIRMATION (filters      |
//|                      ~half of false breakouts)                   |
//|                                                                  |
//|  Strategy class: BREAKOUT-RETEST CONFIRMATION                    |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Range Break + Retest V1 — multi-symbol"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97000001;
input string InpOrderComment      = "SMINDS-RBR-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT;

input group "═══ Range Detection ═══════════════════════════════"
input int    InpRangeBars         = 15;              // Bars to scan for range
input double InpMaxRangeATR       = 2.5;             // Range width <= this × ATR
input int    InpMinRangeTouches   = 1;               // Min times each side touched

input group "═══ Breakout Detection ═══════════════════════════"
input double InpBreakBufferATR    = 0.10;            // Close must exceed range edge by this × ATR
input int    InpMaxBreakAge       = 8;               // Max bars after break to wait for retest

input group "═══ Retest Detection ══════════════════════════"
input double InpRetestProximityATR= 0.30;            // Retest must come within this × ATR of broken level
input bool   InpRequireHoldCandle = true;            // Confirm with bullish/bearish reversal candle
input double InpMinRetestBodyATR  = 0.20;            // Min body size of reversal candle

input group "═══ HTF Trend Filter ═════════════════════════"
input bool             InpUseHTFFilter = true;
input ENUM_TIMEFRAMES  InpHTFPeriod    = PERIOD_H1;
input int              InpHTFEMAPeriod = 50;
input int              InpHTFSlopeBars = 6;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;            // SL beyond opposite range edge
input double InpRRRatio           = 2.0;             // TP = R × SL distance
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
input int    InpSessionStartHour  = 6;
input int    InpSessionEndHour    = 22;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 70;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-RBR-V1"
#define GV_PREFIX "SMRBR1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr      = INVALID_HANDLE;
int g_h_htf_ema  = INVALID_HANDLE;

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

// State machine for break+retest setup
enum BreakState { BR_IDLE = 0, BR_BREAK_UP = 1, BR_BREAK_DOWN = 2 };
BreakState g_state          = BR_IDLE;
int        g_break_age      = 0;        // bars since break detected
double     g_broken_level   = 0.0;      // range high (for up break) or low (for down break)
double     g_other_level    = 0.0;      // opposite range edge (for SL)
double     g_atr_at_break   = 0.0;

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
//| Range detection                                                   |
//+------------------------------------------------------------------+
// Compute high/low over the N bars BEFORE bar 1 (so bar 1 can break out of the range).
// Bars 2..N+1 are used — bar 1 is the candidate breakout bar.
bool DetectRange(double atr, double &range_hi, double &range_lo, int &touches_hi, int &touches_lo)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, g_tf, 2, InpRangeBars, highs) != InpRangeBars) return false;
   if(CopyLow (_Symbol, g_tf, 2, InpRangeBars, lows ) != InpRangeBars) return false;

   range_hi = -DBL_MAX; range_lo = DBL_MAX;
   for(int i = 0; i < InpRangeBars; i++)
   {
      if(highs[i] > range_hi) range_hi = highs[i];
      if(lows[i]  < range_lo) range_lo = lows[i];
   }

   double width = range_hi - range_lo;
   if(width <= 0 || width > atr * InpMaxRangeATR) return false;

   // Count touches near each edge (within 0.15 × ATR of edge)
   double tol = atr * 0.15;
   touches_hi = 0; touches_lo = 0;
   for(int i = 0; i < InpRangeBars; i++)
   {
      if(highs[i] >= range_hi - tol) touches_hi++;
      if(lows[i]  <= range_lo + tol) touches_lo++;
   }
   if(touches_hi < InpMinRangeTouches) return false;
   if(touches_lo < InpMinRangeTouches) return false;

   return true;
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

bool OpenTrade(int dir, double sl_anchor, double atr)
{
   if(!IsSpreadOK()) return false;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double buf    = atr * InpSLBufferATR;
   double sl, tp;

   if(dir > 0)
   {
      sl = NormalizeDouble(sl_anchor - buf, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(sl_anchor + buf, digits);
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

   if(InpRangeBars < 8){ LogError("Range bars too small"); return INIT_PARAMETERS_INCORRECT; }

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
   g_state           = BR_IDLE;
   g_break_age       = 0;
   g_broken_level    = 0.0;
   g_other_level     = 0.0;

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("Range: %dbar lookback  maxW=%.1fxATR  minTouches=%d",
           InpRangeBars, InpMaxRangeATR, InpMinRangeTouches));
   LogInfo(StringFormat("Break: bufATR=%.2f  Retest: <=%.2fxATR within %dbars",
           InpBreakBufferATR, InpRetestProximityATR, InpMaxBreakAge));
   LogInfo(StringFormat("R:R=%.1f  SLbuf=%.2fxATR  HTF=%s/EMA%d  Risk=%.1f%%",
           InpRRRatio, InpSLBufferATR, EnumToString(InpHTFPeriod), InpHTFEMAPeriod, InpRiskPercent));
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
//| OnTick — state machine                                            |
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

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   // Read last completed bar (shift 1)
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return;

   // ── State transitions ──
   if(g_state == BR_IDLE)
   {
      // Look for tight range and breakout
      double range_hi, range_lo;
      int t_hi, t_lo;
      if(!DetectRange(atr, range_hi, range_lo, t_hi, t_lo)) return;

      double break_buf = atr * InpBreakBufferATR;

      if(closes[1] > range_hi + break_buf)
      {
         g_state         = BR_BREAK_UP;
         g_broken_level  = range_hi;
         g_other_level   = range_lo;
         g_atr_at_break  = atr;
         g_break_age     = 1;
         LogDebug(StringFormat("UP break detected: close=%.5f > rangeHi=%.5f (touches: %d/%d)",
                  closes[1], range_hi, t_hi, t_lo));
      }
      else if(closes[1] < range_lo - break_buf)
      {
         g_state         = BR_BREAK_DOWN;
         g_broken_level  = range_lo;
         g_other_level   = range_hi;
         g_atr_at_break  = atr;
         g_break_age     = 1;
         LogDebug(StringFormat("DOWN break detected: close=%.5f < rangeLo=%.5f (touches: %d/%d)",
                  closes[1], range_lo, t_hi, t_lo));
      }
      return;
   }

   // We're in BREAK_UP or BREAK_DOWN — looking for retest
   g_break_age++;
   if(g_break_age > InpMaxBreakAge)
   {
      LogDebug(StringFormat("Break expired (%d bars without retest)", g_break_age));
      g_state = BR_IDLE;
      return;
   }

   // HTF must align with the break direction
   int htf_dir = GetHTFTrend();
   if(InpUseHTFFilter && htf_dir != 0)
   {
      if(g_state == BR_BREAK_UP   && htf_dir < 0){ g_state = BR_IDLE; return; }
      if(g_state == BR_BREAK_DOWN && htf_dir > 0){ g_state = BR_IDLE; return; }
   }

   double prox = g_atr_at_break * InpRetestProximityATR;
   double body = MathAbs(closes[1] - opens[1]);
   double min_body = g_atr_at_break * InpMinRetestBodyATR;

   if(g_state == BR_BREAK_UP)
   {
      // Long retest: bar1 dipped to within prox of broken level, then closed back above with bull body
      bool dipped_to_level = (lows[1] <= g_broken_level + prox);
      bool above_level     = (closes[1] > g_broken_level);
      bool bull_body       = (closes[1] > opens[1]);
      bool body_ok         = !InpRequireHoldCandle || (body >= min_body);
      bool no_full_break   = (closes[1] >= g_broken_level - prox); // didn't fall back through

      if(dipped_to_level && above_level && bull_body && body_ok && no_full_break)
      {
         LogInfo(StringFormat("LONG retest hold confirmed: low=%.5f reached level=%.5f, close=%.5f back above",
                 lows[1], g_broken_level, closes[1]));
         OpenTrade(+1, g_other_level, g_atr_at_break);  // SL anchor = opposite range edge
         g_state = BR_IDLE;
         return;
      }

      // Failed break: price closes back below broken level by > prox → invalid setup
      if(closes[1] < g_broken_level - prox)
      {
         LogDebug("Break invalidated: close fell back under broken level");
         g_state = BR_IDLE;
      }
   }
   else if(g_state == BR_BREAK_DOWN)
   {
      bool dipped_to_level = (highs[1] >= g_broken_level - prox);
      bool below_level     = (closes[1] < g_broken_level);
      bool bear_body       = (closes[1] < opens[1]);
      bool body_ok         = !InpRequireHoldCandle || (body >= min_body);
      bool no_full_break   = (closes[1] <= g_broken_level + prox);

      if(dipped_to_level && below_level && bear_body && body_ok && no_full_break)
      {
         LogInfo(StringFormat("SHORT retest hold confirmed: high=%.5f reached level=%.5f, close=%.5f back below",
                 highs[1], g_broken_level, closes[1]));
         OpenTrade(-1, g_other_level, g_atr_at_break);
         g_state = BR_IDLE;
         return;
      }

      if(closes[1] > g_broken_level + prox)
      {
         LogDebug("Break invalidated: close rose back over broken level");
         g_state = BR_IDLE;
      }
   }
}
//+------------------------------------------------------------------+
