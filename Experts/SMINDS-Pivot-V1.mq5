//+------------------------------------------------------------------+
//|                                  SMINDS-Pivot-V1.mq5             |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #16 (Daily Pivot Reversion)               |
//|                                                                  |
//|  Floor-trader daily pivots based on previous day's H/L/C:        |
//|    Pivot = (PrevH + PrevL + PrevC) / 3                            |
//|    R1 = 2P - PrevL    S1 = 2P - PrevH                             |
//|    R2 = P + (H - L)   S2 = P - (H - L)                            |
//|    R3 = H + 2*(P - L) S3 = L - 2*(H - P)                          |
//|                                                                  |
//|  Strategy: rejection candle at any pivot level → trade reversal  |
//|    - Long  : price wick reaches S1/S2/S3 with bullish close      |
//|    - Short : price wick reaches R1/R2/R3 with bearish close      |
//|  SL beyond the level; TP at next pivot level above/below.        |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS Daily Pivot Reversion V1"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97600001;
input string InpOrderComment      = "SMINDS-PV-V1";

input group "═══ Pivot / Entry ═════════════════════════════════"
input double InpProximityATR      = 0.40;            // Touch within this × ATR of pivot level
input double InpMinWickATR        = 0.40;            // Reversal wick >= this × ATR
input double InpMaxBodyATR        = 0.6;             // Max body (true rejection candle)
input double InpMinBodyATR        = 0.10;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;
input double InpRRRatio           = 1.5;

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

#define EA_TAG    "SMINDS-PV-V1"
#define GV_PREFIX "SMPV1_"

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
string g_gv_consec  = "";
string g_gv_breaker = "";

// Pivot levels for current day
struct Pivots { double R3, R2, R1, P, S1, S2, S3; bool valid; };
Pivots g_pv = {0,0,0,0,0,0,0,false};
datetime g_pv_day = 0;

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
//| Compute pivots from previous day's D1 bar                         |
//+------------------------------------------------------------------+
bool UpdatePivots()
{
   datetime today = DayStart(TimeCurrent());
   if(today == g_pv_day && g_pv.valid) return true;  // already computed for today

   double op[], hi[], lo[], cl[];
   ArraySetAsSeries(op, true); ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true); ArraySetAsSeries(cl, true);
   if(CopyOpen (_Symbol, PERIOD_D1, 0, 3, op) != 3) return false;
   if(CopyHigh (_Symbol, PERIOD_D1, 0, 3, hi) != 3) return false;
   if(CopyLow  (_Symbol, PERIOD_D1, 0, 3, lo) != 3) return false;
   if(CopyClose(_Symbol, PERIOD_D1, 0, 3, cl) != 3) return false;
   // shift 1 = yesterday's daily bar
   double prevH = hi[1], prevL = lo[1], prevC = cl[1];
   double range = prevH - prevL;
   g_pv.P  = (prevH + prevL + prevC) / 3.0;
   g_pv.R1 = 2.0 * g_pv.P - prevL;
   g_pv.S1 = 2.0 * g_pv.P - prevH;
   g_pv.R2 = g_pv.P + range;
   g_pv.S2 = g_pv.P - range;
   g_pv.R3 = prevH + 2.0 * (g_pv.P - prevL);
   g_pv.S3 = prevL - 2.0 * (prevH - g_pv.P);
   g_pv.valid = true;
   g_pv_day = today;
   return true;
}

//+------------------------------------------------------------------+
//| Detect rejection at pivot level                                   |
//+------------------------------------------------------------------+
struct LevelHit { double level; double sl_anchor; double tp_target; };

bool DetectEntry(double atr, int &dir, LevelHit &hit)
{
   if(!g_pv.valid) return false;
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return false;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;
   double bo = opens[1], bh = highs[1], bl = lows[1], bc = closes[1];
   double body = MathAbs(bc - bo);
   if(body > atr * InpMaxBodyATR) return false;
   if(body < atr * InpMinBodyATR) return false;
   double upper = bh - MathMax(bo, bc);
   double lower = MathMin(bo, bc) - bl;
   double prox = atr * InpProximityATR;

   double sup_levels[3] = {g_pv.S1, g_pv.S2, g_pv.S3};
   double res_levels[3] = {g_pv.R1, g_pv.R2, g_pv.R3};
   // Long: bar low touched a support level, lower wick big, bullish close
   for(int i = 0; i < 3; i++)
   {
      double L = sup_levels[i];
      if(MathAbs(bl - L) <= prox && lower >= atr * InpMinWickATR && bc > bo)
      {
         hit.level = L;
         hit.sl_anchor = bl;
         // TP at next level above
         double tp = (i == 0) ? g_pv.P : ((i == 1) ? g_pv.S1 : g_pv.S2);
         if(tp <= bc) tp = g_pv.P;  // sanity
         hit.tp_target = tp;
         dir = +1;
         return true;
      }
   }
   for(int i = 0; i < 3; i++)
   {
      double L = res_levels[i];
      if(MathAbs(bh - L) <= prox && upper >= atr * InpMinWickATR && bc < bo)
      {
         hit.level = L;
         hit.sl_anchor = bh;
         double tp = (i == 0) ? g_pv.P : ((i == 1) ? g_pv.R1 : g_pv.R2);
         if(tp >= bc) tp = g_pv.P;
         hit.tp_target = tp;
         dir = -1;
         return true;
      }
   }
   return false;
}

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

bool OpenTrade(int dir, const LevelHit &hit, double atr)
{
   if(!IsSpreadOK()) return false;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = (dir > 0) ? ask : bid;
   double buf = atr * InpSLBufferATR;
   double sl, tp;
   if(dir > 0)
   {
      sl = NormalizeDouble(hit.sl_anchor - buf, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(MathMin(hit.tp_target, entry + dist * InpRRRatio), digits);
   }
   else
   {
      sl = NormalizeDouble(hit.sl_anchor + buf, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0) return false;
      tp = NormalizeDouble(MathMax(hit.tp_target, entry - dist * InpRRRatio), digits);
   }
   double real_sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(real_sl_dist);
   if(vol <= 0.0) return false;
   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f level=%.5f",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, hit.level));
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
   if(g_tf > PERIOD_H1) { Print("[",EA_TAG,"] Pivot EA needs intraday TF"); return INIT_FAILED; }
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
   if(MQLInfoInteger(MQL_TESTER)) { GlobalVariableDel(g_gv_consec); GlobalVariableDel(g_gv_breaker); g_consec_losses=0; g_breaker_day=0; }
   else StateLoad();
   g_today = DayStart(TimeCurrent());
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   LogInfo(StringFormat("INIT %s/%s magic=%lld Risk=%.1f%%", _Symbol, EnumToString(g_tf), InpMagicNumber, InpRiskPercent));
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
   if(has_pos) { g_open_ticket = ticket; CheckTimeStop(ticket, opened); return; }
   if(g_open_ticket != 0) { RecordTradeResult(g_open_ticket); g_open_ticket = 0; }

   if(!new_bar) return;
   if(!UpdatePivots()) return;
   if(!IsTradeAllowed())          return;
   if(IsDailyLossBreached())      return;
   if(IsCooldownActive())         return;
   if(IsLossBreakerActive())      return;
   if(IsDailyTradeLimitReached()) return;

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   int dir = 0;
   LevelHit hit;
   if(!DetectEntry(atr, dir, hit) || dir == 0) return;
   OpenTrade(dir, hit, atr);
}
//+------------------------------------------------------------------+
