//+------------------------------------------------------------------+
//|                                  SMINDS-Gold-Pyramid-V1.mq5      |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Pyramid scaler EA — rides the same triple-EMA-cross signal as   |
//|  TTR-XI-V12 but enters AFTER price has moved +1×ATR in trend     |
//|  direction. Acts as a second position in confirmed winning       |
//|  trades, amplifying the per-trend PnL by 1.5-1.8× when the trend |
//|  is real.                                                        |
//|                                                                  |
//|  Entry logic:                                                    |
//|    1. Detect Triple-EMA cross (EMA9 crosses EMA20, both vs EMA200)|
//|    2. Mark cross level (price at cross bar close)                |
//|    3. Wait for price to advance +1.0×ATR from cross level        |
//|    4. Wait for first bullish/bearish reversal candle             |
//|    5. Enter at next bar open                                     |
//|                                                                  |
//|  Stops/targets:                                                  |
//|    SL = cross level - 0.3×ATR (tight — original cross is the     |
//|         logical invalidation point)                              |
//|    TP = entry + 2.0×ATR (rides further than TTR-XI's exit)       |
//|                                                                  |
//|  Risk: 0.10 lots base (HALF of TTR-XI's 0.20)                   |
//|                                                                  |
//|  Goal: amplify TTR-XI's $13,940 → $19-21k by adding ~$5-7k       |
//|        from second positions in confirmed trends.                |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS Gold-Pyramid V1 — TTR-XI trend amplifier"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input long   InpMagicNumber       = 94736350;
input string InpOrderComment      = "GPY-V1";

input bool   InpRequireXAUUSD     = true;
input bool   InpRequireM15        = true;

input int    InpEMAFastPeriod     = 9;
input int    InpEMASlowPeriod     = 20;
input int    InpEMAFilterPeriod   = 200;
input int    InpATRPeriod         = 14;
input int    InpATRBaselinePeriod = 50;
input int    InpADXPeriod         = 14;

input bool   InpUseADXFilter      = true;
input double InpMinADX            = 25.0;
input bool   InpUseVolFilter      = true;
input double InpMaxATRRatio       = 1.5;

input double InpTriggerATRMult    = 1.0;             // Wait for price to advance this × ATR from cross
input int    InpMaxBarsAfterCross = 12;              // Cross signal expires after N bars
input bool   InpRequireReversal   = true;            // Need a reversal-style entry candle (small consolidation)

input double InpSLATRBuffer       = 0.3;             // SL = cross level ∓ this × ATR
input double InpSLMaxATR          = 2.0;             // Cap SL distance
input double InpTPATRMultiplier   = 2.0;             // TP = entry ± this × ATR
input double InpMinRR             = 1.0;

input double InpLotSize           = 0.20;            // Match TTR-XI's lot size
input double InpMinLotSize        = 0.01;
input double InpMaxLotSize        = 1.00;

input bool   InpUseDynLots        = true;
input double InpDDHalvePercent    = 15.0;
input double InpDDRestorePercent  = 5.0;

input int    InpSessionStartHour  = 7;
input int    InpSessionEndHour    = 20;

input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 3.0;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 4;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 2;

input int    InpMaxSpreadPoints   = 50;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;

#define EA_TAG     "GPY-V1"
#define GV_PREFIX  "GPYV1_"

CTrade        g_trade;
CSymbolInfo   g_sym;

int  g_h_fast    = INVALID_HANDLE;
int  g_h_slow    = INVALID_HANDLE;
int  g_h_filter  = INVALID_HANDLE;
int  g_h_atr     = INVALID_HANDLE;
int  g_h_atr_base = INVALID_HANDLE;
int  g_h_adx     = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;

string g_gv_peak;
string g_gv_consec;
string g_gv_breaker;

double   g_peak_equity     = 0.0;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;
datetime g_last_bar        = 0;
bool     g_last_trade_was_loss = false;
int      g_bars_since_loss = 9999;
bool     g_lots_halved     = false;
datetime g_today           = 0;
double   g_daily_start_bal = 0.0;
ulong    g_open_position_ticket = 0;
datetime g_open_position_time   = 0;

// Cross signal tracking
struct CrossSignal
{
   int      direction;       // +1 bull, -1 bear, 0 none
   double   level;           // close at cross bar
   datetime bar_time;
   int      bars_old;
};
CrossSignal g_signal;

void LogInfo(string msg)  { PrintFormat("[%s] %s", EA_TAG, msg); }
void LogError(string msg) { PrintFormat("[%s] ERROR: %s", EA_TAG, msg); }

double Get1(int handle, int shift)
{
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
}

void StateSave()
{
   GlobalVariableSet(g_gv_peak, g_peak_equity);
   GlobalVariableSet(g_gv_consec, (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)g_breaker_day);
}
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_peak))    g_peak_equity = GlobalVariableGet(g_gv_peak);
   else                                  g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(g_gv_consec))  g_consec_losses = (int)GlobalVariableGet(g_gv_consec);
   if(GlobalVariableCheck(g_gv_breaker)) g_breaker_day = (datetime)(long)GlobalVariableGet(g_gv_breaker);
}

double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   if(step <= 0) step = 0.01;
   double mn = MathMax(g_sym.LotsMin(), InpMinLotSize);
   double mx = MathMin(g_sym.LotsMax(), InpMaxLotSize);
   lot = MathFloor(lot / step) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   return NormalizeDouble(lot, 2);
}

double ComputeLot()
{
   double lot = InpLotSize;
   if(InpUseDynLots)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_peak_equity = MathMax(g_peak_equity, equity);
      double dd_pct = (g_peak_equity > 0) ? 100.0 * (g_peak_equity - equity) / g_peak_equity : 0.0;
      if(!g_lots_halved && dd_pct >= InpDDHalvePercent) g_lots_halved = true;
      else if(g_lots_halved && dd_pct < InpDDRestorePercent) g_lots_halved = false;
      if(g_lots_halved) lot *= 0.5;
   }
   return NormalizeLot(lot);
}

bool InSession(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

bool SpreadOK()
{
   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spr <= InpMaxSpreadPoints;
}

bool ADXOK()
{
   if(!InpUseADXFilter) return true;
   double adx = Get1(g_h_adx, 1);
   return adx >= InpMinADX;
}

bool VolOK()
{
   if(!InpUseVolFilter) return true;
   double atr  = Get1(g_h_atr, 1);
   double base = Get1(g_h_atr_base, 1);
   if(base <= 0) return false;
   return (atr / base) < InpMaxATRRatio;
}

bool DailyLossOK()
{
   if(!InpUseDailyLossLimit) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today) { g_today = today; g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE); }
   double cur_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss_pct = 100.0 * (g_daily_start_bal - cur_bal) / MathMax(g_daily_start_bal, 0.01);
   return loss_pct < InpMaxDailyLossPct;
}

bool BreakerOK()
{
   if(!InpUseLossBreaker) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   return g_breaker_day != today;
}

bool CooldownOK()
{
   if(!InpUseCooldown) return true;
   if(g_last_trade_was_loss && g_bars_since_loss < InpCooldownBars) return false;
   return true;
}

bool HaveOurPosition(ulong &ticket_out)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ticket_out = t;
      return true;
   }
   return false;
}

void OpenPosition(bool is_long, double sl, double tp)
{
   double lot = ComputeLot();
   double stops_lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = g_sym.Point();
   double min_dist = stops_lvl * pt;

   if(is_long)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask - sl < min_dist) sl = ask - min_dist - pt;
      if(tp - ask < min_dist) tp = ask + min_dist + pt;
      for(int r = 0; r < InpMaxRetries; r++)
      {
         if(g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("BUY %.2f @ %.5f SL=%.5f TP=%.5f", lot, ask, sl, tp));
            return;
         }
      }
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(sl - bid < min_dist) sl = bid + min_dist + pt;
      if(bid - tp < min_dist) tp = bid - min_dist - pt;
      for(int r = 0; r < InpMaxRetries; r++)
      {
         if(g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("SELL %.2f @ %.5f SL=%.5f TP=%.5f", lot, bid, sl, tp));
            return;
         }
      }
   }
}

void CheckLastClosedTradePnL()
{
   if(!HistorySelect(TimeCurrent() - 7*24*60*60, TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;
      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(t <= g_open_position_time && g_open_position_time != 0) break;

      double profit = HistoryDealGetDouble(d, DEAL_PROFIT)
                    + HistoryDealGetDouble(d, DEAL_SWAP)
                    + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(profit < 0)
      {
         g_consec_losses++;
         g_last_trade_was_loss = true;
         g_bars_since_loss = 0;
         if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
            g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
      }
      else
      {
         g_consec_losses = 0;
         g_last_trade_was_loss = false;
      }
      g_open_position_time = 0;
      g_open_position_ticket = 0;
      StateSave();
      break;
   }
}

int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   string up = _Symbol; StringToUpper(up);
   if(InpRequireXAUUSD && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   { LogError("Symbol must be XAU/Gold"); return INIT_FAILED; }
   if(InpRequireM15 && g_tf != PERIOD_M15)
   { LogError("TF must be M15"); return INIT_FAILED; }
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;

   g_h_fast     = iMA(_Symbol, g_tf, InpEMAFastPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_slow     = iMA(_Symbol, g_tf, InpEMASlowPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_filter   = iMA(_Symbol, g_tf, InpEMAFilterPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_atr      = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_atr_base = iATR(_Symbol, g_tf, InpATRBaselinePeriod);
   g_h_adx      = iADX(_Symbol, g_tf, InpADXPeriod);
   if(g_h_fast == INVALID_HANDLE || g_h_slow == INVALID_HANDLE ||
      g_h_filter == INVALID_HANDLE || g_h_atr == INVALID_HANDLE ||
      g_h_atr_base == INVALID_HANDLE || g_h_adx == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_peak    = StringFormat("%s%lld_%s_peak",    GV_PREFIX, acct, _Symbol);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);

   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(g_gv_peak);
      GlobalVariableDel(g_gv_consec);
      GlobalVariableDel(g_gv_breaker);
      g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_consec_losses = 0;
      g_breaker_day = 0;
   }
   else { StateLoad(); }

   LogInfo("─────────── INIT ───────────");
   LogInfo(StringFormat("Strategy : Pyramid scaler — wait %.1fATR after EMA cross", InpTriggerATRMult));
   LogInfo(StringFormat("Lot      : %.2f (half of TTR-XI's 0.20)", InpLotSize));
   LogInfo(StringFormat("SL/TP    : SL=cross±%.1fATR (cap %.1f) TP=%.1fATR", InpSLATRBuffer, InpSLMaxATR, InpTPATRMultiplier));
   LogInfo("────────────────────────────");

   g_today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_bars_since_loss = 9999;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   int handles[] = { g_h_fast, g_h_slow, g_h_filter, g_h_atr, g_h_atr_base, g_h_adx };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

// Detect Triple-EMA cross at bar [shift]: returns +1 (bull cross), -1 (bear cross), 0 none
int DetectCross(int shift)
{
   double f1 = Get1(g_h_fast, shift);
   double f2 = Get1(g_h_fast, shift + 1);
   double s1 = Get1(g_h_slow, shift);
   double s2 = Get1(g_h_slow, shift + 1);
   double e  = Get1(g_h_filter, shift);
   double c  = iClose(_Symbol, g_tf, shift);
   if(f1 <= 0 || f2 <= 0 || s1 <= 0 || s2 <= 0 || e <= 0) return 0;

   bool bull_cross = (f2 <= s2 && f1 > s1) && (c > e);
   bool bear_cross = (f2 >= s2 && f1 < s1) && (c < e);
   if(bull_cross) return +1;
   if(bear_cross) return -1;
   return 0;
}

bool IsBullishCandle(int shift)
{
   double o = iOpen(_Symbol, g_tf, shift);
   double c = iClose(_Symbol, g_tf, shift);
   return c > o;
}
bool IsBearishCandle(int shift)
{
   double o = iOpen(_Symbol, g_tf, shift);
   double c = iClose(_Symbol, g_tf, shift);
   return c < o;
}

void OnTick()
{
   datetime cur_bar = iTime(_Symbol, g_tf, 0);
   if(cur_bar == 0) return;
   bool new_bar = (cur_bar != g_last_bar);
   if(new_bar)
   {
      g_last_bar = cur_bar;
      g_bars_since_loss++;
      if(g_signal.direction != 0) g_signal.bars_old++;
      if(g_signal.bars_old > InpMaxBarsAfterCross)
      {
         g_signal.direction = 0; g_signal.level = 0.0;
         g_signal.bar_time = 0; g_signal.bars_old = 0;
      }
      if(InpUseDynLots)
      {
         double equity = AccountInfoDouble(ACCOUNT_EQUITY);
         g_peak_equity = MathMax(g_peak_equity, equity);
      }
      ulong t;
      if(g_open_position_ticket != 0 && !HaveOurPosition(t))
         CheckLastClosedTradePnL();
   }

   ulong cur_ticket;
   if(HaveOurPosition(cur_ticket))
   {
      g_open_position_ticket = cur_ticket;
      return;
   }
   else if(g_open_position_ticket != 0)
      CheckLastClosedTradePnL();

   if(!new_bar) return;

   if(!DailyLossOK()) return;
   if(!BreakerOK())   return;
   if(!CooldownOK()) return;
   if(!InSession(cur_bar)) return;
   if(!SpreadOK()) return;

   double atr = Get1(g_h_atr, 1);
   if(atr <= 0) return;

   // ── Detect a fresh cross at bar[1] ──
   int new_cross = DetectCross(1);
   if(new_cross != 0 && ADXOK() && VolOK())
   {
      g_signal.direction = new_cross;
      g_signal.level = iClose(_Symbol, g_tf, 1);
      g_signal.bar_time = iTime(_Symbol, g_tf, 1);
      g_signal.bars_old = 0;
   }

   // ── If we have an active signal, check trigger condition ──
   if(g_signal.direction == 0) return;

   double c1 = iClose(_Symbol, g_tf, 1);
   double trigger_distance = c1 - g_signal.level;

   if(g_signal.direction > 0)
   {
      // Long pyramid: price must be ≥ level + 1×ATR AND bar[1] must be bullish
      if(trigger_distance < InpTriggerATRMult * atr) return;
      if(InpRequireReversal && !IsBullishCandle(1)) return;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl_logical = g_signal.level - InpSLATRBuffer * atr;
      double sl_cap     = ask - InpSLMaxATR * atr;
      double sl = MathMax(sl_logical, sl_cap);
      double tp = ask + InpTPATRMultiplier * atr;
      double risk = ask - sl;
      double reward = tp - ask;
      if(risk > 0 && reward / risk >= InpMinRR)
      {
         OpenPosition(true, sl, tp);
         g_open_position_time = TimeCurrent();
         g_signal.direction = 0; g_signal.level = 0.0;
         g_signal.bar_time = 0; g_signal.bars_old = 0;
      }
   }
   else if(g_signal.direction < 0)
   {
      if(-trigger_distance < InpTriggerATRMult * atr) return;
      if(InpRequireReversal && !IsBearishCandle(1)) return;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl_logical = g_signal.level + InpSLATRBuffer * atr;
      double sl_cap     = bid + InpSLMaxATR * atr;
      double sl = MathMin(sl_logical, sl_cap);
      double tp = bid - InpTPATRMultiplier * atr;
      double risk = sl - bid;
      double reward = bid - tp;
      if(risk > 0 && reward / risk >= InpMinRR)
      {
         OpenPosition(false, sl, tp);
         g_open_position_time = TimeCurrent();
         g_signal.direction = 0; g_signal.level = 0.0;
         g_signal.bar_time = 0; g_signal.bars_old = 0;
      }
   }
}
//+------------------------------------------------------------------+
