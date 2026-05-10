//+------------------------------------------------------------------+
//|                                  SMINDS-InsideBar-V1.mq5         |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #14 (Inside-Bar Breakout)                 |
//|                                                                  |
//|  Inside Bar = a bar whose high <= mother bar's high AND          |
//|  whose low >= mother bar's low. Indicates compression/decision   |
//|  point. Break of mother bar's high/low triggers continuation.    |
//|                                                                  |
//|  Strategy:                                                       |
//|    1. Detect inside bar pattern (bar 1 inside bar 2 = mother).   |
//|    2. Mother bar must be substantial (range >= X × ATR).         |
//|    3. Pending: break of mother high (long) or low (short).       |
//|    4. Enter on bar that breaks AND closes beyond mother extreme. |
//|    5. SL = opposite mother extreme; TP = R × range_size.         |
//|                                                                  |
//|  Filters:                                                        |
//|    - HTF trend agrees with break direction                       |
//|    - Pattern expires after N bars without break                  |
//|                                                                  |
//|  Strategy class: PRICE-PATTERN BREAKOUT                          |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS Inside-Bar Breakout V1"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97400001;
input string InpOrderComment      = "SMINDS-IB-V1";

input group "═══ Pattern Detection ═══════════════════════════"
input double InpMinMotherATR      = 0.8;             // Mother bar range >= this × ATR
input double InpMaxInsideRatio    = 0.7;             // Inside bar range / mother bar <= this
input int    InpMaxPatternAge     = 5;               // Wait this many bars max for breakout
input double InpBreakBufferATR    = 0.05;            // Break beyond mother extreme by this × ATR

input group "═══ HTF Filter ═══════════════════════════════════"
input bool             InpUseHTFFilter = true;
input ENUM_TIMEFRAMES  InpHTFPeriod    = PERIOD_H1;
input int              InpHTFEMAPeriod = 50;
input int              InpHTFSlopeBars = 6;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;
input double InpRRRatio           = 2.0;

input group "═══ Position Sizing ═════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 3.0;
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
input bool   InpUseTrailingTP     = true;
input double InpTrailActivateR    = 1.0;
input double InpTrailDistanceR    = 0.5;

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

#define EA_TAG    "SMINDS-IB-V1"
#define GV_PREFIX "SMIB1_"

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

// Pattern pending state
struct PatternState {
   bool     active;
   double   mother_high;
   double   mother_low;
   double   atr_at_pattern;
   int      age;
};
PatternState g_pat = {false, 0.0, 0.0, 0.0, 0};

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

bool IsCooldownActive() { if(!InpUseCooldown) return false; return (g_last_loss && g_bars_since_loss < InpCooldownBars); }
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
   if(today != g_today) { g_today = today; g_today_trades = 0; g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE); }
   return (g_today_trades >= InpMaxTradesPerDay);
}

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
//| Inside-bar pattern detection                                      |
//+------------------------------------------------------------------+
// Looks at bar 1 (inside) vs bar 2 (mother). Returns true if pattern valid.
// Outputs mother high/low for use as breakout levels.
bool DetectInsideBar(double atr, double &mother_high, double &mother_low)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, g_tf, 0, 3, highs) != 3) return false;
   if(CopyLow (_Symbol, g_tf, 0, 3, lows ) != 3) return false;

   // bar 1 = inside; bar 2 = mother
   double m_hi = highs[2], m_lo = lows[2];
   double i_hi = highs[1], i_lo = lows[1];
   if(i_hi >= m_hi || i_lo <= m_lo) return false;  // Not inside

   double m_range = m_hi - m_lo;
   double i_range = i_hi - i_lo;
   if(m_range < atr * InpMinMotherATR) return false;
   if(m_range > 0 && (i_range / m_range) > InpMaxInsideRatio) return false;

   mother_high = m_hi;
   mother_low  = m_lo;
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
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_INVALID_VOLUME) return false;
      Sleep(InpRetryDelayMs);
      g_sym.RefreshRates();
   }
   return false;
}

bool OpenTrade(int dir, double mother_hi, double mother_lo, double atr)
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
      sl = NormalizeDouble(mother_lo - buf, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(mother_hi + buf, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(entry - dist * InpRRRatio, digits);
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
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f mother=[%.5f,%.5f]",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, mother_lo, mother_hi));
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
   double r = favor / initial_dist;
   if(r < InpTrailActivateR) return;
   double td = initial_dist * InpTrailDistanceR;
   double new_sl;
   if(g_open_dir > 0)
   {
      new_sl = NormalizeDouble(bid - td, digits);
      if(new_sl > cur_sl) g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
   else
   {
      new_sl = NormalizeDouble(ask + td, digits);
      if(cur_sl == 0.0 || new_sl < cur_sl) g_trade.PositionModify(ticket, new_sl, cur_tp);
   }
}

void CheckTimeStop(ulong ticket, datetime open_time)
{
   if(!InpUseTimeStop || open_time == 0) return;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, times) != 1) return;
   long held = (long)((times[0] - open_time) / PeriodSeconds(g_tf));
   if(held >= InpMaxHoldBars) { if(ClosePosition(ticket)) RecordTradeResult(ticket); }
}

//+------------------------------------------------------------------+
//| Init / Deinit / OnTick                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;
   g_h_atr     = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_htf_ema = iMA (_Symbol, InpHTFPeriod, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_h_atr == INVALID_HANDLE || g_h_htf_ema == INVALID_HANDLE) return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   if(MQLInfoInteger(MQL_TESTER))
   { GlobalVariableDel(g_gv_consec); GlobalVariableDel(g_gv_breaker); g_consec_losses=0; g_breaker_day=0; }
   else StateLoad();
   g_today           = DayStart(TimeCurrent());
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_pat.active = false;
   LogInfo(StringFormat("INIT %s/%s magic=%lld minMother=%.1fxATR maxInside=%.2f",
           _Symbol, EnumToString(g_tf), InpMagicNumber, InpMinMotherATR, InpMaxInsideRatio));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_htf_ema != INVALID_HANDLE) IndicatorRelease(g_h_htf_ema);
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
      ApplyTrail(ticket);
      CheckTimeStop(ticket, opened);
      return;
   }
   if(g_open_ticket != 0) { RecordTradeResult(g_open_ticket); g_open_ticket = 0; }

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   // ── Pending pattern: check for breakout (every tick) ──
   if(g_pat.active)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double break_buf = g_pat.atr_at_pattern * InpBreakBufferATR;
      int dir = 0;
      if(ask > g_pat.mother_high + break_buf) dir = +1;
      else if(bid < g_pat.mother_low  - break_buf) dir = -1;

      if(dir != 0)
      {
         // Risk gates final check
         if(IsTradeAllowed() && !IsDailyLossBreached() && !IsCooldownActive() &&
            !IsLossBreakerActive() && !IsDailyTradeLimitReached())
         {
            // HTF alignment
            if(InpUseHTFFilter)
            {
               int htf_dir = GetHTFTrend();
               if(htf_dir != 0 && htf_dir == dir)
                  OpenTrade(dir, g_pat.mother_high, g_pat.mother_low, g_pat.atr_at_pattern);
            }
            else
               OpenTrade(dir, g_pat.mother_high, g_pat.mother_low, g_pat.atr_at_pattern);
         }
         g_pat.active = false;
         return;
      }
      // Age out
      if(new_bar)
      {
         g_pat.age++;
         if(g_pat.age > InpMaxPatternAge) { g_pat.active = false; LogDebug("Pattern expired"); }
      }
   }

   // ── Detect new pattern on new bar ──
   if(!new_bar) return;
   if(g_pat.active) return;   // already watching one

   double mh, ml;
   if(DetectInsideBar(atr, mh, ml))
   {
      g_pat.active        = true;
      g_pat.mother_high   = mh;
      g_pat.mother_low    = ml;
      g_pat.atr_at_pattern= atr;
      g_pat.age           = 0;
      LogDebug(StringFormat("Inside-bar detected mother=[%.5f,%.5f]", ml, mh));
   }
}
//+------------------------------------------------------------------+
