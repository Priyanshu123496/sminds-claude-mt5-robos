//+------------------------------------------------------------------+
//|                                  SMINDS-Channel-Trader-V1.mq5    |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #2 (Parallel Regression Channel)          |
//|                                                                  |
//|  Derived from manual XAUUSD H1 screenshots showing repeated      |
//|  successful bounces inside an upward parallel channel.           |
//|                                                                  |
//|  Channel detection:                                              |
//|    Linear regression on last N bars (default 80).                |
//|    Boundaries = regression line ± K × stddev(residuals).         |
//|                                                                  |
//|  Entry: bar pierces a boundary then closes back inside it.       |
//|         (bullish reversal at lower; bearish at upper)            |
//|                                                                  |
//|  Exit: TP at opposite boundary set at entry time                 |
//|        SL just outside the touched boundary (ATR buffer)         |
//|        Optional time-stop, optional channel-break exit           |
//|                                                                  |
//|  Direction modes:                                                |
//|    0 = both directions (pure mean reversion)                     |
//|    1 = trend-aligned (longs only in rising channel, shorts in    |
//|        falling) — matches manual screenshots                     |
//|    2 = counter-trend bounces only                                |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Channel Trader V1 — XAUUSD H1"
#property description "Linear regression channel mean-reversion"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96100001;        // Magic number (per-account unique)
input string InpOrderComment      = "SMINDS-CH-V1"; // Order comment

input group "═══ Symbol / TF Guard ══════════════════════════════"
input bool             InpRequireGold = true;        // Require XAU/Gold symbol
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_H1;   // Required TF (PERIOD_CURRENT to disable)

input group "═══ Channel Detection ════════════════════════════"
input int    InpChannelLookback   = 100;             // Bars for regression
input double InpStdDevMult        = 2.0;             // K × stddev for boundary
input int    InpATRPeriod         = 14;              // ATR period (used in filters/SL)
input double InpMinChannelATR     = 1.5;             // Min channel width as multiple of ATR
input double InpMaxChannelATR     = 6.0;             // Max channel width as multiple of ATR
input double InpMinSlopeATR       = 0.05;            // Abs(slope) × lookback >= this × ATR (channel must trend)

input group "═══ Direction Mode ═══════════════════════════════"
input int    InpDirectionMode     = 1;               // 0=both, 1=trend-aligned, 2=counter-trend

input group "═══ Entry Trigger ════════════════════════════════"
// Bar must "pierce-and-recover": low/high goes outside, close returns inside
input bool   InpRequireReversalCandle = true;        // Bullish/bearish body in entry direction
input double InpPierceMinFracATR  = 0.10;            // Pierce depth must be >= this × ATR
input double InpPierceMaxFracATR  = 1.50;            // Pierce depth must be <= this × ATR (filter blowoffs)

input group "═══ Stop Loss / Take Profit ══════════════════════"
input double InpSLBufferATR       = 0.50;            // SL beyond touched boundary = this × ATR
input bool   InpTPAtMidline       = false;           // TP at midline (false = opposite boundary)
input double InpMinRRRatio        = 0.80;            // Reject if computed R:R below this

input group "═══ HTF Trend Filter ═════════════════════════════"
input bool             InpUseHTFFilter = true;       // Require HTF trend alignment
input ENUM_TIMEFRAMES  InpHTFPeriod    = PERIOD_H4;  // HTF used for trend
input int              InpHTFEMAPeriod = 50;         // HTF EMA period
input int              InpHTFSlopeBars = 6;          // Bars for HTF slope check

input group "═══ Position Sizing ════════════════════════════"
input bool   InpUseRiskBasedLot   = false;           // Risk-based vs fixed lot
input double InpRiskPercent       = 1.0;             // % equity per trade (when risk-based)
input double InpLotSize           = 0.10;            // Fixed lot (when not risk-based)
input double InpMaxLotSize        = 5.00;
input double InpMinLotSize        = 0.01;

input group "═══ Risk Circuit Breakers ════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 3;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 6;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 48;              // 48 H1 bars = 2 days
input bool   InpExitOnChannelBreak= true;            // Exit if price breaks far through opposite boundary

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 6;
input int    InpSessionEndHour    = 22;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 60;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;
input bool   InpDrawChannel       = true;            // Draw channel lines on chart

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-CH-V1"
#define GV_PREFIX "SMCH1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr     = INVALID_HANDLE;
int g_h_htf_ema = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;
datetime        g_today    = 0;
double          g_daily_start_bal = 0.0;

bool     g_last_loss       = false;
int      g_bars_since_loss = 9999;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;

ulong    g_open_ticket     = 0;
datetime g_open_bar_time   = 0;
int      g_open_dir        = 0;
double   g_open_upper      = 0.0;
double   g_open_lower      = 0.0;

string   g_gv_consec  = "";
string   g_gv_breaker = "";

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
void LogInfo (string m) { PrintFormat("[%s] %s", EA_TAG, m); }
void LogWarn (string m) { PrintFormat("[%s] WARN: %s", EA_TAG, m); }
void LogError(string m) { PrintFormat("[%s] ERROR: %s", EA_TAG, m); }
void LogDebug(string m) { if(InpVerbose) PrintFormat("[%s] %s", EA_TAG, m); }

//+------------------------------------------------------------------+
//| State persistence                                                 |
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

bool ReadBuffer(int handle, int shift, double &v)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int n = shift + 1;
   if(CopyBuffer(handle, 0, 0, n, buf) != n) return false;
   v = buf[shift];
   return MathIsValidNumber(v) && v != 0.0;
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
         ticket    = t;
         type      = PositionGetInteger(POSITION_TYPE);
         open_time = (datetime)PositionGetInteger(POSITION_TIME);
         return true;
      }
   }
   ticket = 0; type = -1; open_time = 0;
   return false;
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
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today)
   {
      g_today           = today;
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
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(g_breaker_day == 0) return false;
   return (today <= g_breaker_day);
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long s = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return s <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Linear regression channel                                         |
//+------------------------------------------------------------------+
struct Channel
{
   bool   valid;
   double slope;        // per-bar slope
   double intercept;    // y at x = 0 (oldest bar in window)
   double stddev;       // residual stddev
   double upper_now;    // upper boundary at most-recent bar
   double lower_now;
   double mid_now;
   double width;
};

bool ComputeChannel(int lookback, double std_mult, Channel &ch)
{
   ch.valid = false;
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_tf, 0, lookback, closes) != lookback) return false;

   // x: 0 = oldest, N-1 = most recent. closes[0] is most recent.
   double sum_x = 0, sum_y = 0, sum_xy = 0, sum_xx = 0;
   for(int i = 0; i < lookback; i++)
   {
      double x = (double)(lookback - 1 - i);
      double y = closes[i];
      sum_x  += x;
      sum_y  += y;
      sum_xy += x * y;
      sum_xx += x * x;
   }
   double n = (double)lookback;
   double denom = n * sum_xx - sum_x * sum_x;
   if(MathAbs(denom) < 1e-10) return false;

   ch.slope     = (n * sum_xy - sum_x * sum_y) / denom;
   ch.intercept = (sum_y - ch.slope * sum_x) / n;

   double sum_r2 = 0.0;
   for(int i = 0; i < lookback; i++)
   {
      double x = (double)(lookback - 1 - i);
      double y_pred = ch.slope * x + ch.intercept;
      double r = closes[i] - y_pred;
      sum_r2 += r * r;
   }
   ch.stddev = MathSqrt(sum_r2 / n);

   double x_now = (double)(lookback - 1);
   ch.mid_now   = ch.slope * x_now + ch.intercept;
   ch.upper_now = ch.mid_now + std_mult * ch.stddev;
   ch.lower_now = ch.mid_now - std_mult * ch.stddev;
   ch.width     = ch.upper_now - ch.lower_now;
   ch.valid     = true;
   return true;
}

// Channel boundary at given bar shift (shift bars back)
void BoundsAtShift(const Channel &ch, int shift, double &upper, double &mid, double &lower)
{
   double dx = -(double)shift; // shift back = negative dx in slope term
   mid = ch.mid_now + ch.slope * dx;
   upper = mid + InpStdDevMult * ch.stddev;
   lower = mid - InpStdDevMult * ch.stddev;
}

//+------------------------------------------------------------------+
//| Channel quality filter                                            |
//+------------------------------------------------------------------+
bool ChannelIsTradeable(const Channel &ch, double atr, int &channel_dir)
{
   channel_dir = 0;
   if(!ch.valid || atr <= 0.0) return false;

   // Width within sensible band
   if(ch.width < atr * InpMinChannelATR)
   {
      LogDebug(StringFormat("Skip: channel too narrow %.2f < %.2f×ATR", ch.width, InpMinChannelATR));
      return false;
   }
   if(ch.width > atr * InpMaxChannelATR)
   {
      LogDebug(StringFormat("Skip: channel too wide %.2f > %.2f×ATR", ch.width, InpMaxChannelATR));
      return false;
   }

   // Channel must trend (not flat)
   double slope_total = MathAbs(ch.slope) * (double)InpChannelLookback;
   if(slope_total < atr * InpMinSlopeATR)
   {
      LogDebug(StringFormat("Skip: slope total %.2f < %.2f×ATR", slope_total, InpMinSlopeATR));
      return false;
   }

   channel_dir = (ch.slope > 0.0) ? 1 : -1;
   return true;
}

//+------------------------------------------------------------------+
//| HTF trend                                                         |
//+------------------------------------------------------------------+
int GetHTFTrend()
{
   if(!InpUseHTFFilter) return 0; // 0 = no constraint when disabled (will treat as match)
   double ema_now = 0.0, ema_old = 0.0;
   if(!ReadBuffer(g_h_htf_ema, 0, ema_now)) return 0;
   if(!ReadBuffer(g_h_htf_ema, InpHTFSlopeBars, ema_old)) return 0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool slope_up   = ema_now > ema_old;
   bool slope_down = ema_now < ema_old;
   bool price_up   = price > ema_now;
   bool price_down = price < ema_now;
   if(slope_up && price_up)     return  1;
   if(slope_down && price_down) return -1;
   return 0; // mixed / flat
}

//+------------------------------------------------------------------+
//| Entry detection (on completed bar)                                |
//+------------------------------------------------------------------+
struct EntrySignal
{
   int    dir;       // +1 long, -1 short, 0 none
   double sl_anchor; // boundary level used for SL
   double tp_target; // opposite boundary at entry time
};

bool DetectEntry(const Channel &ch, double atr, EntrySignal &sig)
{
   sig.dir = 0; sig.sl_anchor = 0; sig.tp_target = 0;

   // Use last completed bar (shift 1)
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);  ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyHigh (_Symbol, g_tf, 0, 2, highs)  != 2) return false;
   if(CopyLow  (_Symbol, g_tf, 0, 2, lows)   != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;

   double upper_b1, mid_b1, lower_b1;
   BoundsAtShift(ch, 1, upper_b1, mid_b1, lower_b1);

   double bar_open  = opens[1];
   double bar_high  = highs[1];
   double bar_low   = lows[1];
   double bar_close = closes[1];
   bool bullish     = bar_close > bar_open;
   bool bearish     = bar_close < bar_open;

   double pierce_min = atr * InpPierceMinFracATR;
   double pierce_max = atr * InpPierceMaxFracATR;

   // Long trigger: low pierced lower boundary, close back above lower
   if(bar_low <= lower_b1 && bar_close > lower_b1)
   {
      double pierce_depth = lower_b1 - bar_low;
      if(pierce_depth >= pierce_min && pierce_depth <= pierce_max)
      {
         if(!InpRequireReversalCandle || bullish)
         {
            sig.dir       = +1;
            sig.sl_anchor = lower_b1;
            sig.tp_target = InpTPAtMidline ? mid_b1 : upper_b1;
            return true;
         }
      }
   }
   // Short trigger
   if(bar_high >= upper_b1 && bar_close < upper_b1)
   {
      double pierce_depth = bar_high - upper_b1;
      if(pierce_depth >= pierce_min && pierce_depth <= pierce_max)
      {
         if(!InpRequireReversalCandle || bearish)
         {
            sig.dir       = -1;
            sig.sl_anchor = upper_b1;
            sig.tp_target = InpTPAtMidline ? mid_b1 : lower_b1;
            return true;
         }
      }
   }
   return false;
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

bool OpenTrade(const EntrySignal &sig, double atr, const Channel &ch)
{
   if(!IsSpreadOK()){ LogDebug("Skip: spread"); return false; }

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (sig.dir > 0) ? ask : bid;
   double buffer = atr * InpSLBufferATR;

   double sl = (sig.dir > 0)
             ? NormalizeDouble(sig.sl_anchor - buffer, digits)
             : NormalizeDouble(sig.sl_anchor + buffer, digits);
   sl = EnforceMinStop(sl, entry, sig.dir > 0);

   double tp = NormalizeDouble(sig.tp_target, digits);

   double sl_dist = MathAbs(entry - sl);
   double tp_dist = MathAbs(tp - entry);
   if(sl_dist <= 0.0 || tp_dist <= 0.0)
   {
      LogWarn("Bad SL/TP distance");
      return false;
   }
   double rr = tp_dist / sl_dist;
   if(rr < InpMinRRRatio)
   {
      LogDebug(StringFormat("Skip: R:R %.2f < min %.2f", rr, InpMinRRRatio));
      return false;
   }

   double vol = ComputeLotSize(sl_dist);
   if(vol <= 0.0){ LogWarn("Lot calc zero"); return false; }

   bool ok = ExecOrder(sig.dir > 0, vol, sl, tp);
   if(ok)
   {
      g_open_dir       = sig.dir;
      g_open_upper     = ch.upper_now;
      g_open_lower     = ch.lower_now;
      datetime times[]; ArraySetAsSeries(times, true);
      if(CopyTime(_Symbol, g_tf, 0, 1, times) == 1) g_open_bar_time = times[0];
      LogInfo(StringFormat("%s %.2f @ %.2f SL=%.2f TP=%.2f (R:R=%.2f atr=%.2f w=%.2f)",
              sig.dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, rr, atr, ch.width));
   }
   return ok;
}

bool ClosePosition(ulong ticket)
{
   for(int a = 1; a <= InpMaxRetries; a++)
   {
      if(g_trade.PositionClose(ticket)) return true;
      uint rc = g_trade.ResultRetcode();
      LogWarn(StringFormat("Close %d/%d rc=%u (%s)", a, InpMaxRetries, rc, g_trade.ResultRetcodeDescription()));
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
      g_last_loss = true;
      g_bars_since_loss = 0;
      g_consec_losses++;
      if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
      {
         g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
         LogWarn(StringFormat("Circuit breaker tripped at %d losses", g_consec_losses));
      }
      LogInfo(StringFormat("Loss %.2f. Consec=%d", total, g_consec_losses));
   }
   else
   {
      g_last_loss = false;
      g_bars_since_loss = 9999;
      if(g_consec_losses > 0) LogInfo(StringFormat("Win %.2f. Consec reset", total));
      g_consec_losses = 0;
      g_breaker_day = 0;
   }
   StateSave();
}

//+------------------------------------------------------------------+
//| Time stop / channel-break exit                                    |
//+------------------------------------------------------------------+
void ManageOpenPosition(ulong ticket, datetime open_time)
{
   if(InpUseTimeStop && open_time != 0)
   {
      datetime times[]; ArraySetAsSeries(times, true);
      if(CopyTime(_Symbol, g_tf, 0, 1, times) == 1)
      {
         long held = (long)((times[0] - open_time) / PeriodSeconds(g_tf));
         if(held >= InpMaxHoldBars)
         {
            LogInfo(StringFormat("Time stop after %d bars", (int)held));
            if(ClosePosition(ticket)) RecordTradeResult(ticket);
            return;
         }
      }
   }
   if(InpExitOnChannelBreak && g_open_dir != 0)
   {
      // Re-compute channel; if price has broken far past target boundary (>1×ATR), close
      Channel ch;
      double atr = 0.0;
      if(ReadBuffer(g_h_atr, 0, atr) && atr > 0.0 &&
         ComputeChannel(InpChannelLookback, InpStdDevMult, ch))
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(g_open_dir > 0 && bid > ch.upper_now + atr)
         {
            LogInfo("Channel-break exit (long, price beyond upper)");
            if(ClosePosition(ticket)) RecordTradeResult(ticket);
            return;
         }
         if(g_open_dir < 0 && ask < ch.lower_now - atr)
         {
            LogInfo("Channel-break exit (short, price beyond lower)");
            if(ClosePosition(ticket)) RecordTradeResult(ticket);
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Channel drawing (visual aid in tester / chart)                    |
//+------------------------------------------------------------------+
void DrawChannel(const Channel &ch)
{
   if(!InpDrawChannel || !ch.valid) return;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, InpChannelLookback, times) != InpChannelLookback) return;
   datetime t_old = times[InpChannelLookback - 1];
   datetime t_new = times[0];

   double upper_old, mid_old, lower_old;
   BoundsAtShift(ch, InpChannelLookback - 1, upper_old, mid_old, lower_old);

   string nm_u = "SMCH_upper", nm_m = "SMCH_mid", nm_l = "SMCH_lower";
   ObjectDelete(0, nm_u); ObjectDelete(0, nm_m); ObjectDelete(0, nm_l);
   ObjectCreate(0, nm_u, OBJ_TREND, 0, t_old, upper_old, t_new, ch.upper_now);
   ObjectCreate(0, nm_m, OBJ_TREND, 0, t_old, mid_old,   t_new, ch.mid_now);
   ObjectCreate(0, nm_l, OBJ_TREND, 0, t_old, lower_old, t_new, ch.lower_now);
   ObjectSetInteger(0, nm_u, OBJPROP_COLOR, clrTomato);
   ObjectSetInteger(0, nm_m, OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, nm_l, OBJPROP_COLOR, clrSeaGreen);
   ObjectSetInteger(0, nm_u, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm_m, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm_l, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm_m, OBJPROP_STYLE, STYLE_DOT);
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   string up = _Symbol; StringToUpper(up);
   if(InpRequireGold && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   { LogError("Symbol must be XAU/Gold (override InpRequireGold to disable)"); return INIT_FAILED; }
   if(InpRequireTF != PERIOD_CURRENT && g_tf != InpRequireTF)
   { LogError(StringFormat("Timeframe must be %s", EnumToString(InpRequireTF))); return INIT_FAILED; }

   if(!g_sym.Name(_Symbol)){ LogError("CSymbolInfo init failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)){ LogError("SymbolSelect failed"); return INIT_FAILED; }

   if(InpChannelLookback < 30){ LogError("Channel lookback too small"); return INIT_PARAMETERS_INCORRECT; }
   if(InpStdDevMult <= 0.0){ LogError("StdDev mult must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDirectionMode < 0 || InpDirectionMode > 2){ LogError("DirectionMode 0/1/2"); return INIT_PARAMETERS_INCORRECT; }

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
      g_breaker_day   = 0;
   }
   else
      StateLoad();

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("Channel: lookback=%d std=%.2f minW=%.1fxATR maxW=%.1fxATR minSlope=%.2fxATR",
           InpChannelLookback, InpStdDevMult, InpMinChannelATR, InpMaxChannelATR, InpMinSlopeATR));
   LogInfo(StringFormat("DirMode=%d HTF=%s/EMA%d  Sess=%02d-%02d UTC",
           InpDirectionMode, EnumToString(InpHTFPeriod), InpHTFEMAPeriod,
           InpSessionStartHour, InpSessionEndHour));
   LogInfo(StringFormat("Lot: %s base=%.2f risk=%.1f%% min=%.2f max=%.2f",
           InpUseRiskBasedLot ? "RISK" : "FIXED", InpLotSize, InpRiskPercent, InpMinLotSize, InpMaxLotSize));
   LogInfo(StringFormat("SL=ATRx%.2f buffer  TP=%s  MinR:R=%.2f",
           InpSLBufferATR, InpTPAtMidline ? "MID" : "OPP_BOUND", InpMinRRRatio));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr     != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_htf_ema != INVALID_HANDLE) IndicatorRelease(g_h_htf_ema);
   if(InpDrawChannel)
   {
      ObjectDelete(0, "SMCH_upper");
      ObjectDelete(0, "SMCH_mid");
      ObjectDelete(0, "SMCH_lower");
   }
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
      ManageOpenPosition(ticket, opened);
      return;
   }

   // Detect closed-position (record result)
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
      g_open_dir    = 0;
   }

   if(!new_bar) return;

   // Risk gates
   if(!IsSessionAllowed())   { LogDebug("Skip: session");   return; }
   if(IsDailyLossBreached()) { LogDebug("Skip: daily loss");return; }
   if(IsCooldownActive())    { LogDebug("Skip: cooldown");  return; }
   if(IsLossBreakerActive()) { LogDebug("Skip: breaker");   return; }

   // ATR
   double atr = 0.0;
   if(!ReadBuffer(g_h_atr, 0, atr) || atr <= 0.0) return;

   // Channel
   Channel ch;
   if(!ComputeChannel(InpChannelLookback, InpStdDevMult, ch)) return;
   DrawChannel(ch);

   int channel_dir = 0;
   if(!ChannelIsTradeable(ch, atr, channel_dir)) return;

   // HTF trend (only when filter active)
   int htf_dir = GetHTFTrend();
   if(InpUseHTFFilter && htf_dir == 0)
   {
      LogDebug("Skip: HTF flat");
      return;
   }

   // Detect entry on closed bar
   EntrySignal sig;
   if(!DetectEntry(ch, atr, sig)) return;

   // Apply direction-mode filter
   if(InpDirectionMode == 1)         // trend-aligned with channel
   {
      if(sig.dir != channel_dir) { LogDebug("Skip: dir vs channel slope"); return; }
   }
   else if(InpDirectionMode == 2)    // counter-channel only
   {
      if(sig.dir == channel_dir) { LogDebug("Skip: with channel slope (counter-only mode)"); return; }
   }

   // HTF alignment
   if(InpUseHTFFilter && sig.dir != htf_dir)
   {
      LogDebug(StringFormat("Skip: dir %d vs HTF %d", sig.dir, htf_dir));
      return;
   }

   OpenTrade(sig, atr, ch);
}
//+------------------------------------------------------------------+
