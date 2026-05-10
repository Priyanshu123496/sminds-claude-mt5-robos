//+------------------------------------------------------------------+
//|                              SMINDS-London-Breakout-V1.mq5       |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #4 (London Open Breakout)                 |
//|                                                                  |
//|  Classic volatility-breakout setup:                              |
//|    1. Track the Asian session range (00:00–07:00 UTC).           |
//|    2. At London open (07:00 UTC), within entry window:           |
//|       - Long if price closes above Asian high                    |
//|       - Short if price closes below Asian low                    |
//|    3. SL at opposite end of Asian range (+/- buffer)             |
//|    4. TP = R × range size (default 1.5)                          |
//|                                                                  |
//|  Edge: London open often produces directional breakout from      |
//|        the consolidation built during low-volume Asian session.  |
//|                                                                  |
//|  Strategy class: VOLATILITY BREAKOUT  (uncorrelated with         |
//|        trend-following and pullback strategies in our portfolio) |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS London Open Breakout V1 — multi-symbol"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96400001;
input string InpOrderComment      = "SMINDS-LOB-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT; // PERIOD_CURRENT = no constraint

input group "═══ Sessions (UTC hours) ════════════════════════════"
input int    InpAsianStartHour    = 0;               // Asian session start (UTC)
input int    InpAsianEndHour      = 7;               // Asian session end (= London open)
input int    InpEntryWindowEndHour= 11;              // No new trades after this hour
input int    InpForceCloseHour    = 16;              // Force-close any open trade at this hour (US close)

input group "═══ Range Quality ════════════════════════════════"
input int    InpATRPeriod         = 14;
input double InpMinRangeATR       = 0.5;             // Asian range must be at least this × daily ATR
input double InpMaxRangeATR       = 3.0;             // Asian range must not exceed this × daily ATR
input ENUM_TIMEFRAMES InpATRTF    = PERIOD_D1;       // ATR timeframe for range comparison

input group "═══ Breakout Trigger ═════════════════════════════"
input bool   InpRequireCloseBreak = true;            // Wait for bar close beyond range (vs intra-bar)
input double InpBreakoutBufferPts = 5.0;             // Extra buffer in points beyond range high/low

input group "═══ Stop Loss / Take Profit ══════════════════════"
input double InpRRRatio           = 1.5;             // TP = R × SL distance
input double InpSLBufferPts       = 5.0;             // SL beyond opposite range edge
input bool   InpUseTrailingTP     = true;            // Trail TP after 1R favorable move
input double InpTrailActivateR    = 1.0;             // Activate trail after this R-multiple
input double InpTrailDistanceR    = 0.5;             // Trail distance (× initial SL distance)

input group "═══ Position Sizing ════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 3.0;             // Boosted from 1.0% — DD analysis shows headroom
input double InpLotSize           = 0.10;            // Fallback fixed lot
input double InpMaxLotSize        = 5.00;
input double InpMinLotSize        = 0.01;

input group "═══ Daily Limits ═════════════════════════════════"
input int    InpMaxTradesPerDay   = 1;               // London breakout = 1 setup/day
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 3;

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
#define EA_TAG    "SMINDS-LOB-V1"
#define GV_PREFIX "SMLOB1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr_d1 = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;
datetime        g_today    = 0;
double          g_daily_start_bal = 0.0;

// Asian range state (per day)
datetime g_range_day_id      = 0;     // day for which range was computed
double   g_asian_high        = 0.0;
double   g_asian_low         = 0.0;
bool     g_range_valid       = false;
bool     g_breakout_taken    = false; // already opened breakout for this day

int      g_today_trades      = 0;
int      g_consec_losses     = 0;
datetime g_breaker_day       = 0;

ulong    g_open_ticket       = 0;
double   g_open_entry        = 0.0;
double   g_open_initial_sl   = 0.0;
int      g_open_dir          = 0;
bool     g_open_trail_armed  = false;

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

bool FindOurPosition(ulong &ticket, long &type)
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
         return true;
      }
   }
   ticket = 0; type = -1;
   return false;
}

datetime DayStartOfTime(datetime t)
{
   return (datetime)((long)t / 86400 * 86400);
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long s = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return s <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Risk gates                                                        |
//+------------------------------------------------------------------+
bool IsDailyLossBreached()
{
   if(!InpUseDailyLossLimit) return false;
   datetime today = DayStartOfTime(TimeCurrent());
   if(today != g_today)
   {
      g_today           = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_today_trades    = 0;
      return false;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily_start_bal <= 0.0) return false;
   double pct = (g_daily_start_bal - eq) / g_daily_start_bal * 100.0;
   return (pct >= InpMaxDailyLossPct);
}

bool IsLossBreakerActive()
{
   if(!InpUseLossBreaker) return false;
   if(g_consec_losses < InpMaxConsecLosses) return false;
   datetime today = DayStartOfTime(TimeCurrent());
   if(g_breaker_day == 0) return false;
   return (today <= g_breaker_day);
}

//+------------------------------------------------------------------+
//| Asian range computation                                           |
//+------------------------------------------------------------------+
// Compute Asian high/low for the current day's session
// (uses M5/M15 bars from today's start to InpAsianEndHour)
bool ComputeAsianRange(double &hi, double &lo)
{
   datetime today = DayStartOfTime(TimeCurrent());
   datetime asian_start = today + InpAsianStartHour * 3600;
   datetime asian_end   = today + InpAsianEndHour   * 3600;

   // Number of bars in the session window
   int total_bars = 1500; // generous lookback
   datetime times[]; double highs[], lows[];
   ArraySetAsSeries(times, true); ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyTime(_Symbol, g_tf, 0, total_bars, times) <= 0) return false;
   if(CopyHigh(_Symbol, g_tf, 0, total_bars, highs) <= 0) return false;
   if(CopyLow (_Symbol, g_tf, 0, total_bars, lows ) <= 0) return false;

   double h = -DBL_MAX, l = DBL_MAX;
   bool found = false;
   int n = ArraySize(times);
   for(int i = 0; i < n; i++)
   {
      if(times[i] < asian_start) break;          // gone past today's start
      if(times[i] >= asian_end)  continue;       // outside session (later than London open)
      if(highs[i] > h) h = highs[i];
      if(lows[i]  < l) l = lows[i];
      found = true;
   }
   if(!found) return false;
   hi = h; lo = l;
   return true;
}

bool RangeQualityOK(double range_size)
{
   double atr_d1 = 0.0;
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_h_atr_d1, 0, 0, 2, buf) != 2) return false;
   atr_d1 = buf[1]; // yesterday's ATR (today's not complete)
   if(atr_d1 <= 0.0) return false;
   if(range_size < atr_d1 * InpMinRangeATR)
   {
      LogDebug(StringFormat("Skip: range %.1fpts < %.2f×ATRd1 (%.1f)",
                            range_size, InpMinRangeATR, atr_d1 * InpMinRangeATR));
      return false;
   }
   if(range_size > atr_d1 * InpMaxRangeATR)
   {
      LogDebug(StringFormat("Skip: range %.1fpts > %.2f×ATRd1 (%.1f)",
                            range_size, InpMaxRangeATR, atr_d1 * InpMaxRangeATR));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Trade execution                                                   |
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
      LogWarn(StringFormat("%s attempt %d/%d rc=%u (%s)",
              is_buy ? "Buy" : "Sell", a, InpMaxRetries,
              rc, g_trade.ResultRetcodeDescription()));
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME) return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool OpenBreakout(int dir)
{
   if(!IsSpreadOK()){ LogDebug("Skip: spread"); return false; }
   if(!g_range_valid){ return false; }

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double range_size = g_asian_high - g_asian_low;

   double sl, tp;
   if(dir > 0)
   {
      sl = NormalizeDouble(g_asian_low - InpSLBufferPts * point, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(g_asian_high + InpSLBufferPts * point, digits);
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
      g_breakout_taken = true;
      g_today_trades++;
      g_open_dir         = dir;
      g_open_entry       = entry;
      g_open_initial_sl  = sl;
      g_open_trail_armed = false;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f range=%.1fpts #%d/day",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, range_size / point, g_today_trades));
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

//+------------------------------------------------------------------+
//| Trade-result accounting                                           |
//+------------------------------------------------------------------+
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
      g_consec_losses++;
      if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
      {
         g_breaker_day = DayStartOfTime(TimeCurrent());
         LogWarn(StringFormat("Circuit breaker tripped at %d losses", g_consec_losses));
      }
      LogInfo(StringFormat("Loss %.2f. Consec=%d", total, g_consec_losses));
   }
   else
   {
      if(g_consec_losses > 0) LogInfo(StringFormat("Win %.2f. Consec reset", total));
      g_consec_losses = 0;
      g_breaker_day = 0;
   }
   StateSave();
}

//+------------------------------------------------------------------+
//| Trailing TP                                                       |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(InpRequireTF != PERIOD_CURRENT && g_tf != InpRequireTF)
   { LogError(StringFormat("Timeframe must be %s", EnumToString(InpRequireTF))); return INIT_FAILED; }
   if(g_tf > PERIOD_M30)
   { LogError("This EA needs M5/M15/M30 (intraday session detection)"); return INIT_FAILED; }

   if(!g_sym.Name(_Symbol)){ LogError("CSymbolInfo init failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)){ LogError("SymbolSelect failed"); return INIT_FAILED; }

   if(InpAsianStartHour < 0 || InpAsianStartHour > 23 ||
      InpAsianEndHour <= InpAsianStartHour || InpAsianEndHour > 23 ||
      InpEntryWindowEndHour <= InpAsianEndHour || InpEntryWindowEndHour > 23)
   { LogError("Invalid session hours"); return INIT_PARAMETERS_INCORRECT; }

   g_h_atr_d1 = iATR(_Symbol, InpATRTF, InpATRPeriod);
   if(g_h_atr_d1 == INVALID_HANDLE){ LogError("ATR handle failed"); return INIT_FAILED; }

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
      g_breaker_day   = 0;
   }
   else
      StateLoad();

   g_today           = DayStartOfTime(TimeCurrent());
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_range_valid     = false;
   g_breakout_taken  = false;

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("Asian: %02d:00-%02d:00 UTC  Entry-window: until %02d:00 UTC  Force-close: %02d:00",
           InpAsianStartHour, InpAsianEndHour, InpEntryWindowEndHour, InpForceCloseHour));
   LogInfo(StringFormat("R:R=%.1f  RangeATR-band=[%.2f,%.2f]×D1 ATR  Risk=%.1f%%",
           InpRRRatio, InpMinRangeATR, InpMaxRangeATR, InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr_d1 != INVALID_HANDLE) IndicatorRelease(g_h_atr_d1);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime today = DayStartOfTime(TimeCurrent());
   if(today != g_today)
   {
      g_today           = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_today_trades    = 0;
      g_range_valid     = false;
      g_breakout_taken  = false;
   }

   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);

   // Manage existing position
   ulong ticket = 0; long ptype = -1;
   bool has_pos = FindOurPosition(ticket, ptype);
   if(has_pos)
   {
      g_open_ticket = ticket;
      ApplyTrail(ticket);
      // Force close at end of US session if still open
      if(dt.hour >= InpForceCloseHour)
      {
         LogInfo(StringFormat("Force close at %02d:00 UTC", dt.hour));
         if(ClosePosition(ticket)) RecordTradeResult(ticket);
      }
      return;
   }
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
   }

   // Risk gates
   if(IsDailyLossBreached()) return;
   if(IsLossBreakerActive()) return;
   if(InpMaxTradesPerDay > 0 && g_today_trades >= InpMaxTradesPerDay) return;
   if(g_breakout_taken) return;

   // Compute Asian range right at session end (or any time after)
   if(!g_range_valid && dt.hour >= InpAsianEndHour)
   {
      double hi, lo;
      if(ComputeAsianRange(hi, lo))
      {
         double range = hi - lo;
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         if(RangeQualityOK(range))
         {
            g_asian_high = hi;
            g_asian_low  = lo;
            g_range_valid = true;
            LogDebug(StringFormat("Asian range valid: H=%.5f L=%.5f size=%.1fpts",
                     hi, lo, range / point));
         }
      }
   }

   if(!g_range_valid) return;

   // Entry window: between London open and entry-end hour
   if(dt.hour < InpAsianEndHour || dt.hour >= InpEntryWindowEndHour) return;

   // Check breakout on last completed bar
   double opens[], closes[]; double highs[], lows[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buf   = InpBreakoutBufferPts * point;

   if(InpRequireCloseBreak)
   {
      // Use just-closed bar (shift 1)
      if(closes[1] > g_asian_high + buf)      OpenBreakout(+1);
      else if(closes[1] < g_asian_low  - buf) OpenBreakout(-1);
   }
   else
   {
      // Intra-bar break (current price)
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > g_asian_high + buf)      OpenBreakout(+1);
      else if(bid < g_asian_low  - buf) OpenBreakout(-1);
   }
}
//+------------------------------------------------------------------+
