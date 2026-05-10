//+------------------------------------------------------------------+
//|                                  SMINDS-RoundNum-V1.mq5          |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #13 (Round Number Reversion)              |
//|                                                                  |
//|  Trades rejection at psychological round-number levels:          |
//|    EURUSD: 1.1000, 1.0500, 1.0000, etc.                          |
//|    XAUUSD: 4500, 4550, 4600, ...                                 |
//|    USDJPY: 150.00, 150.50, 151.00, ...                           |
//|                                                                  |
//|  These levels often act as support/resistance because:           |
//|    - Stop-loss/take-profit clusters from human traders           |
//|    - Option strike concentrations                                |
//|    - Order book activity from algo traders too                   |
//|                                                                  |
//|  Strategy:                                                       |
//|    1. Compute the level grid (round to nearest configured step)  |
//|    2. When price approaches a level (within X pips)              |
//|    3. AND a rejection candle forms (long wick + opposite close)  |
//|    4. Enter against the rejection direction                      |
//|    5. SL just beyond the level, TP at next level (or fixed RR)   |
//|                                                                  |
//|  Strategy class: PSYCHOLOGICAL LEVEL REVERSION                   |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS Round Number Reversion V1"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97300001;
input string InpOrderComment      = "SMINDS-RN-V1";

input group "═══ Round Number Grid ═══════════════════════════"
// Grid step depends on instrument:
//   EURUSD/GBPUSD/etc 4-5 digit: 0.0050 (50 pips), 0.0100 (100 pips)
//   USDJPY/EURJPY/etc 2-3 digit: 0.50 (50 pips), 1.00 (100 pips)
//   XAUUSD: 50.0 (50 dollars), 100.0
//   BTCUSD: 1000, 5000
input double InpGridStepPrice     = 0.0;             // 0 = auto-detect from symbol digits
input double InpProximityATR      = 0.5;             // Approach within this × ATR triggers level watch

input group "═══ Rejection Candle ═══════════════════════════"
input double InpMinWickATR        = 0.6;             // Wick towards level >= this × ATR
input double InpMaxBodyATR        = 0.5;             // Body <= this × ATR (true rejection candle)
input double InpMinBodyATR        = 0.10;            // But not pure doji

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;            // SL beyond rejection extreme
input double InpRRRatio           = 1.5;
input bool   InpTPAtNextLevel     = false;           // TP = next round level (else use RR)

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

#define EA_TAG    "SMINDS-RN-V1"
#define GV_PREFIX "SMRN1_"

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

double   g_grid_step       = 0.0;       // computed in OnInit

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
//| Round-number grid                                                 |
//+------------------------------------------------------------------+
// Auto-detect grid step based on symbol digits & price:
//   5-digit forex (e.g., EURUSD ~1.10): 0.0050 (50 pips)
//   3-digit JPY pairs (e.g., USDJPY ~150): 0.50 (50 pips)
//   2-digit gold (XAUUSD ~4500): 50.0
double AutoDetectGridStep()
{
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) bid = 1.0;

   // Forex 5-digit (e.g., 1.10987)
   if(digits >= 5)
   {
      return 0.0050;  // 50 pips
   }
   // JPY pairs 3-digit (e.g., 150.123)
   if(digits == 3 && bid > 50.0 && bid < 500.0)
   {
      return 0.50;
   }
   // Gold (XAUUSD ~4500, 2-digit price)
   if(digits == 2 && bid > 1000.0)
   {
      return 50.0;
   }
   // Silver (XAGUSD ~30, 3-digit)
   if(digits == 3 && bid > 10.0 && bid < 100.0)
   {
      return 1.0;
   }
   // Default: 50 pips equivalent based on point
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return point * 500.0;
}

// Find the nearest round-number level to a given price.
// Returns the level itself; sets is_above if level > price.
double NearestLevel(double price, bool &level_above)
{
   double k = MathRound(price / g_grid_step);
   double level = k * g_grid_step;
   level_above = (level > price);
   return level;
}

// Find the nearest level ABOVE the price (next resistance candidate)
double LevelAbove(double price)
{
   return MathCeil(price / g_grid_step) * g_grid_step;
}
double LevelBelow(double price)
{
   return MathFloor(price / g_grid_step) * g_grid_step;
}

//+------------------------------------------------------------------+
//| Entry detection: rejection at round level                         |
//+------------------------------------------------------------------+
// Returns +1 long (rejected at level below — buying off support),
//         -1 short (rejected at level above — selling off resistance),
//         0 none
struct LevelHit { double level; double sl_anchor; double tp_target; };

bool DetectEntry(double atr, int &dir, LevelHit &hit)
{
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return false;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;

   double bar_open = opens[1], bar_high = highs[1], bar_low = lows[1], bar_close = closes[1];
   double body = MathAbs(bar_close - bar_open);

   // Body size constraints: pure rejection candle (small body, big wick)
   if(body > atr * InpMaxBodyATR) return false;
   if(body < atr * InpMinBodyATR) return false;

   double upper_wick = bar_high - MathMax(bar_open, bar_close);
   double lower_wick = MathMin(bar_open, bar_close) - bar_low;
   double prox       = atr * InpProximityATR;

   // Resistance rejection: high reached up to a round level above, then closed below
   double resistance = LevelAbove(MathMax(bar_open, bar_close));
   if(MathAbs(bar_high - resistance) <= prox &&
      upper_wick >= atr * InpMinWickATR &&
      bar_close < bar_open)   // bearish candle
   {
      hit.level     = resistance;
      hit.sl_anchor = bar_high;  // SL beyond the wick high
      hit.tp_target = LevelBelow(bar_close);  // TP at next level below
      dir = -1;
      return true;
   }

   // Support rejection: low reached down to a round level below, then closed above
   double support = LevelBelow(MathMin(bar_open, bar_close));
   if(MathAbs(bar_low - support) <= prox &&
      lower_wick >= atr * InpMinWickATR &&
      bar_close > bar_open)   // bullish candle
   {
      hit.level     = support;
      hit.sl_anchor = bar_low;
      hit.tp_target = LevelAbove(bar_close);
      dir = +1;
      return true;
   }

   return false;
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

bool OpenTrade(int dir, const LevelHit &hit, double atr)
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
      sl = NormalizeDouble(hit.sl_anchor - buf, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0) return false;
      tp = InpTPAtNextLevel
             ? NormalizeDouble(hit.tp_target, digits)
             : NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(hit.sl_anchor + buf, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0) return false;
      tp = InpTPAtNextLevel
             ? NormalizeDouble(hit.tp_target, digits)
             : NormalizeDouble(entry - dist * InpRRRatio, digits);
   }

   double real_sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(real_sl_dist);
   if(vol <= 0.0) return false;

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f level=%.5f atr=%.5f",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, hit.level, atr));
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
//| Init / Deinit / OnTick                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;

   g_grid_step = (InpGridStepPrice > 0.0) ? InpGridStepPrice : AutoDetectGridStep();
   if(g_grid_step <= 0.0){ LogError("Grid step zero"); return INIT_FAILED; }

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
   LogInfo(StringFormat("%s/%s  Magic=%lld  GridStep=%.5f  Risk=%.1f%%",
           _Symbol, EnumToString(g_tf), InpMagicNumber, g_grid_step, InpRiskPercent));
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

   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;

   int dir = 0;
   LevelHit hit;
   if(!DetectEntry(atr, dir, hit)) return;
   if(dir == 0) return;

   OpenTrade(dir, hit, atr);
}
//+------------------------------------------------------------------+
