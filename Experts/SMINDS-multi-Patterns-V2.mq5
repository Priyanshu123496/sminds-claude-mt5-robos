//+------------------------------------------------------------------+
//|                                  SMINDS-multi-Patterns-V2.mq5  |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Phase 2: V1 + confluence filters (RSI, ADX, pullback, vol).     |
//|  Patterns now treated as continuation signals after pullback     |
//|  within HTF trend, not standalone reversal signals.              |
//|                                                                  |
//|  Detected patterns (long & short):                               |
//|    1. Engulfing (bullish/bearish)                                |
//|    2. Pin Bar / Hammer / Shooting Star                           |
//|    3. Morning Star / Evening Star (3-bar reversal)               |
//|    4. Inside Bar Breakout                                        |
//|                                                                  |
//|  Trend qualifier:                                                |
//|    - HTF (M15) EMA50 slope must agree with trade direction.      |
//|    - Optional: only long when price above HTF EMA50.             |
//|                                                                  |
//|  Risk model:                                                     |
//|    - 1.5% of equity per trade                                    |
//|    - SL = pattern extreme ± ATR buffer                           |
//|    - TP = 3 × SL distance (fixed 3:1 R:R)                        |
//|    - Hard time-stop after N M5 bars                              |
//|                                                                  |
//|  Compounding:                                                    |
//|    - Lot size derived from current equity each trade             |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS multi-pattern engine V1 — XAUUSD M5"
#property description "Engulfing + PinBar + Morning/Evening Star + Inside Bar"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 95001002;        // Magic number
input string InpOrderComment      = "SMINDS-MP-V2";  // Order comment

input group "═══ Symbol / TF Guard ══════════════════════════════"
input bool   InpRequireGold       = true;            // Require XAU/Gold symbol
input bool   InpRequireM5         = true;            // Require M5 timeframe

input group "═══ Risk & Position Sizing ════════════════════════"
input double InpRiskPercent       = 1.5;             // Risk % of equity per trade
input double InpMaxLotSize        = 5.00;            // Hard cap on lot
input double InpMinLotSize        = 0.01;            // Hard floor on lot
input bool   InpCompound          = true;            // Use current equity (compound) vs initial deposit

input group "═══ R:R Configuration ════════════════════════════"
input double InpRRRatio           = 3.0;             // TP distance = SL distance × this

input group "═══ Stop Loss Placement ══════════════════════════"
input int    InpATRPeriod         = 14;              // ATR period
input double InpATRBufferMult     = 0.5;             // SL extra buffer = ATR × this beyond pattern extreme

input group "═══ Pattern Selection ═════════════════════════════"
input bool   InpUseEngulfing      = true;            // Enable engulfing pattern
input bool   InpUsePinBar         = true;            // Enable pin bar (hammer / shooting star)
input bool   InpUseStar           = true;            // Enable morning/evening star
input bool   InpUseInsideBar      = true;            // Enable inside-bar breakout

input group "═══ Pattern Quality ═══════════════════════════════"
input double InpMinBodyATR        = 0.40;            // Min pattern body size as fraction of ATR (V2 tightened)
input double InpPinWickRatio      = 2.5;             // Pin bar long-wick must be >= this × body (V2 tightened)
input double InpPinOppWickMaxR    = 0.25;            // Pin bar opposite wick max as fraction of body (V2 tightened)
input double InpMinATRPrice       = 0.50;            // Min ATR (in price) to consider trades — skip dead markets

input group "═══ Confluence: Pullback Detection (V2) ════════════"
// Patterns are most reliable as CONTINUATION signals after a pullback,
// not as standalone reversal signals. Require evidence of recent pullback.
input bool   InpUsePullback       = true;            // Require pullback before entry
input int    InpFastEMA           = 20;              // EMA used for pullback detection (M5)
input int    InpPullbackLookback  = 6;               // Bars to look back for pullback
input bool   InpPullbackTouchEMA  = true;            // Require recent touch of EMA20

input group "═══ Confluence: RSI ═══════════════════════════════"
input bool   InpUseRSI            = true;
input int    InpRSIPeriod         = 14;
input double InpRSILongMin        = 35.0;            // Long: RSI on bar1 must be >= this (turning up from dip)
input double InpRSILongMax        = 65.0;            // Long: RSI must be <= this (not extreme overbought)
input double InpRSIShortMin       = 35.0;            // Short: RSI must be >= this (not extreme oversold)
input double InpRSIShortMax       = 65.0;            // Short: RSI must be <= this (turning down from peak)
input bool   InpRSIRequireTurn    = true;            // Long: RSI rising vs 3 bars ago; Short: RSI falling

input group "═══ Confluence: ADX Trend Strength ════════════════"
input bool   InpUseADX            = true;
input int    InpADXPeriod         = 14;
input double InpMinADX            = 22.0;            // Trend strength threshold

input group "═══ HTF Trend Filter ═════════════════════════════"
input bool             InpUseHTFTrend = true;        // Require HTF trend alignment
input ENUM_TIMEFRAMES  InpHTFPeriod   = PERIOD_M15;  // HTF used for trend
input int              InpHTFEMAPeriod= 50;          // HTF EMA period

input group "═══ Session Filter (UTC) ══════════════════════════"
input bool InpUseSession      = true;
input int  InpSessionStartHour= 7;
input int  InpSessionEndHour  = 20;

input group "═══ Risk Circuit Breakers ═════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 5.0;             // Max daily loss % of start-of-day balance
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 4;               // Halt for the day after N consec losses
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 6;               // Cooldown bars (M5) after a loss

input group "═══ Time Stop ═════════════════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 24;              // Force-close after this many M5 bars (24×5min = 2h)

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 50;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ═══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-MP-V2"
#define GV_PREFIX "SMP1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_atr   = INVALID_HANDLE;
int g_h_htf   = INVALID_HANDLE;
int g_h_rsi   = INVALID_HANDLE;
int g_h_adx   = INVALID_HANDLE;
int g_h_fast  = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;

datetime g_today           = 0;
double   g_daily_start_bal = 0.0;

bool     g_last_loss       = false;
int      g_bars_since_loss = 9999;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;
ulong    g_last_open_ticket= 0;     // last ticket we opened — used for result tracking on close

string g_gv_consec  = "";
string g_gv_breaker = "";

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
void LogInfo(string m) { PrintFormat("[%s] %s", EA_TAG, m); }
void LogWarn(string m) { PrintFormat("[%s] WARN: %s", EA_TAG, m); }
void LogError(string m){ PrintFormat("[%s] ERROR: %s", EA_TAG, m); }
void LogDebug(string m){ if(InpVerbose) PrintFormat("[%s] %s", EA_TAG, m); }

//+------------------------------------------------------------------+
//| Persistence                                                       |
//+------------------------------------------------------------------+
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_consec))
      g_consec_losses = (int)GlobalVariableGet(g_gv_consec);
   if(GlobalVariableCheck(g_gv_breaker))
      g_breaker_day = (datetime)(long)GlobalVariableGet(g_gv_breaker);
}

void StateSave()
{
   GlobalVariableSet(g_gv_consec,  (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)(long)g_breaker_day);
}

//+------------------------------------------------------------------+
//| Bar / indicator helpers                                           |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, bars) != 1) return false;
   if(g_last_bar == 0){ g_last_bar = bars[0]; return false; }
   if(bars[0] != g_last_bar){ g_last_bar = bars[0]; return true; }
   return false;
}

bool ReadBuffer(int handle, int shift, double &v)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int n = shift + 1;
   if(CopyBuffer(handle, 0, 0, n, buf) != n) return false;
   v = buf[shift];
   return MathIsValidNumber(v) && v != 0.0;
}

bool ReadHTF_EMA(int shift, double &v)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int n = shift + 1;
   if(CopyBuffer(g_h_htf, 0, 0, n, buf) != n) return false;
   v = buf[shift];
   return MathIsValidNumber(v) && v > 0.0;
}

//+------------------------------------------------------------------+
//| Lot sizing — risk-based, with optional compounding                |
//+------------------------------------------------------------------+
double NormalizeVol(double x)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || minv <= 0.0) return 0.0;
   double clipped = MathMax(minv, MathMin(maxv, x));
   int d = 2;
   for(int i=0; i<=8; i++)
   {
      double s = step * MathPow(10.0, i);
      if(MathAbs(s - MathRound(s)) < 1e-8){ d = i; break; }
   }
   return NormalizeDouble(MathFloor(clipped / step) * step, d);
}

double ComputeLot(double sl_distance_price)
{
   if(sl_distance_price <= 0.0) return 0.0;

   double risk_capital = InpCompound
                          ? AccountInfoDouble(ACCOUNT_EQUITY)
                          : AccountInfoDouble(ACCOUNT_BALANCE);  // ACCOUNT_BALANCE will reflect deposit when no trades open
   double risk_amount  = risk_capital * (InpRiskPercent / 100.0);
   if(risk_amount <= 0.0) return 0.0;

   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0) return 0.0;

   // loss for 1 lot at the proposed SL distance
   double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
   if(loss_per_lot <= 0.0) return 0.0;

   double raw_lot = risk_amount / loss_per_lot;
   raw_lot = MathMax(InpMinLotSize, MathMin(InpMaxLotSize, raw_lot));
   return NormalizeVol(raw_lot);
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
//| HTF trend                                                         |
//+------------------------------------------------------------------+
// Returns +1 = uptrend, -1 = downtrend, 0 = flat / unavailable
int GetHTFTrend(double &htf_ema)
{
   if(!ReadHTF_EMA(0, htf_ema)) return 0;
   double htf_ema_old = 0.0;
   if(!ReadHTF_EMA(3, htf_ema_old)) return 0;

   // Use slope direction; price-vs-ema as secondary
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool slope_up   = htf_ema > htf_ema_old;
   bool slope_down = htf_ema < htf_ema_old;
   bool price_up   = price > htf_ema;
   bool price_down = price < htf_ema;

   if(slope_up && price_up)   return  1;
   if(slope_down && price_down) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Pattern detection                                                 |
//|  All work on the JUST-CLOSED bars, accessed as shift 1,2,3        |
//+------------------------------------------------------------------+
struct Bar { double o, h, l, c; };

bool LoadBar(int shift, Bar &b)
{
   double op[], hi[], lo[], cl[];
   ArraySetAsSeries(op, true); ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true); ArraySetAsSeries(cl, true);
   int need = shift + 1;
   if(CopyOpen (_Symbol, g_tf, 0, need, op) != need) return false;
   if(CopyHigh (_Symbol, g_tf, 0, need, hi) != need) return false;
   if(CopyLow  (_Symbol, g_tf, 0, need, lo) != need) return false;
   if(CopyClose(_Symbol, g_tf, 0, need, cl) != need) return false;
   b.o = op[shift]; b.h = hi[shift]; b.l = lo[shift]; b.c = cl[shift];
   return true;
}

double Body(const Bar &b){ return MathAbs(b.c - b.o); }
double Range(const Bar &b){ return b.h - b.l; }
bool   Bull(const Bar &b){ return b.c > b.o; }
bool   Bear(const Bar &b){ return b.c < b.o; }
double UpperWick(const Bar &b){ return b.h - MathMax(b.o, b.c); }
double LowerWick(const Bar &b){ return MathMin(b.o, b.c) - b.l; }

// Pattern result: 0 = none, +1 = bullish, -1 = bearish
// extreme is the price level used as SL anchor (low for bull, high for bear)
struct PatternHit
{
   int    dir;       // +1 bullish, -1 bearish
   string name;
   double extreme;   // SL anchor price (pattern low for bull, high for bear)
};

bool DetectEngulfing(double atr, PatternHit &hit)
{
   Bar b1, b2;
   if(!LoadBar(1, b1) || !LoadBar(2, b2)) return false;
   double atr_floor = atr * InpMinBodyATR;

   // Bullish engulfing: prior bear, current bull, current body engulfs prior body
   if(Bear(b2) && Bull(b1) &&
      b1.o <= b2.c && b1.c >= b2.o &&
      Body(b1) >= Body(b2) &&
      Body(b1) >= atr_floor)
   {
      hit.dir     = +1;
      hit.name    = "BullEngulf";
      hit.extreme = MathMin(b1.l, b2.l);
      return true;
   }
   // Bearish engulfing
   if(Bull(b2) && Bear(b1) &&
      b1.o >= b2.c && b1.c <= b2.o &&
      Body(b1) >= Body(b2) &&
      Body(b1) >= atr_floor)
   {
      hit.dir     = -1;
      hit.name    = "BearEngulf";
      hit.extreme = MathMax(b1.h, b2.h);
      return true;
   }
   return false;
}

bool DetectPinBar(double atr, PatternHit &hit)
{
   Bar b1;
   if(!LoadBar(1, b1)) return false;
   double bd = Body(b1);
   double rng = Range(b1);
   if(rng <= 0.0) return false;
   double uw = UpperWick(b1);
   double lw = LowerWick(b1);
   double atr_floor = atr * InpMinBodyATR;
   // Total range should be meaningful
   if(rng < atr_floor) return false;
   // Avoid dojis with no body — require body at least 5% of range
   if(bd < rng * 0.05) return false;

   // Bullish pin / hammer: long lower wick
   if(lw >= bd * InpPinWickRatio &&
      uw <= bd * InpPinOppWickMaxR)
   {
      hit.dir     = +1;
      hit.name    = "BullPin";
      hit.extreme = b1.l;
      return true;
   }
   // Bearish pin / shooting star
   if(uw >= bd * InpPinWickRatio &&
      lw <= bd * InpPinOppWickMaxR)
   {
      hit.dir     = -1;
      hit.name    = "BearPin";
      hit.extreme = b1.h;
      return true;
   }
   return false;
}

bool DetectStar(double atr, PatternHit &hit)
{
   Bar b1, b2, b3;
   if(!LoadBar(1, b1) || !LoadBar(2, b2) || !LoadBar(3, b3)) return false;
   double atr_floor = atr * InpMinBodyATR;
   double small_body = atr * 0.20;

   // Morning star: bear b3 (large body), small body b2, bull b1 closes above b3 mid
   if(Bear(b3) && Body(b3) >= atr_floor &&
      Body(b2) <= small_body &&
      Bull(b1) && Body(b1) >= atr_floor &&
      b1.c > (b3.o + b3.c) * 0.5)
   {
      hit.dir     = +1;
      hit.name    = "MorningStar";
      hit.extreme = MathMin(MathMin(b1.l, b2.l), b3.l);
      return true;
   }
   // Evening star
   if(Bull(b3) && Body(b3) >= atr_floor &&
      Body(b2) <= small_body &&
      Bear(b1) && Body(b1) >= atr_floor &&
      b1.c < (b3.o + b3.c) * 0.5)
   {
      hit.dir     = -1;
      hit.name    = "EveningStar";
      hit.extreme = MathMax(MathMax(b1.h, b2.h), b3.h);
      return true;
   }
   return false;
}

// Inside bar: bar2 is "mother", bar1 is fully inside bar2.
// Trigger: current bar (shift 0) breaks above mother high (long) or below mother low (short)
bool DetectInsideBar(double atr, PatternHit &hit)
{
   Bar b0, b1, b2;
   if(!LoadBar(0, b0) || !LoadBar(1, b1) || !LoadBar(2, b2)) return false;
   // Inside relationship between bar1 (most recent closed) and bar2 (mother)
   if(b1.h >= b2.h || b1.l <= b2.l) return false;
   if(Range(b2) < atr * 0.5) return false;   // mother bar should be meaningful
   // Breakout direction by current price relative to mother extremes
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price > b2.h)
   {
      hit.dir     = +1;
      hit.name    = "InsideBarUp";
      hit.extreme = b2.l;
      return true;
   }
   if(price < b2.l)
   {
      hit.dir     = -1;
      hit.name    = "InsideBarDown";
      hit.extreme = b2.h;
      return true;
   }
   return false;
}

// Returns true if any enabled pattern fires; populates `hit`
bool ScanPatterns(double atr, PatternHit &hit)
{
   if(InpUseEngulfing && DetectEngulfing(atr, hit)) return true;
   if(InpUseStar       && DetectStar(atr, hit))     return true;
   if(InpUsePinBar     && DetectPinBar(atr, hit))   return true;
   if(InpUseInsideBar  && DetectInsideBar(atr, hit))return true;
   return false;
}

//+------------------------------------------------------------------+
//| Confluence checks (V2)                                            |
//+------------------------------------------------------------------+
// Returns true if the pattern has the structural / momentum context
// that makes it a high-probability continuation signal.
bool ConfluencePass(int dir, double atr)
{
   // ── ATR floor: skip dead/illiquid markets ──
   if(atr < InpMinATRPrice)
   {
      LogDebug(StringFormat("Skip: ATR %.2f < min %.2f", atr, InpMinATRPrice));
      return false;
   }

   // ── ADX trend strength ──
   if(InpUseADX)
   {
      double adx = 0.0;
      if(!ReadBuffer(g_h_adx, 0, adx)) return false;
      if(adx < InpMinADX)
      {
         LogDebug(StringFormat("Skip: ADX %.1f < %.1f", adx, InpMinADX));
         return false;
      }
   }

   // ── RSI band + direction confirmation ──
   if(InpUseRSI)
   {
      double rsi_now = 0.0, rsi_old = 0.0;
      if(!ReadBuffer(g_h_rsi, 1, rsi_now)) return false;
      if(!ReadBuffer(g_h_rsi, 4, rsi_old)) return false;
      if(dir > 0)
      {
         if(rsi_now < InpRSILongMin || rsi_now > InpRSILongMax)
         { LogDebug(StringFormat("Skip: long RSI %.1f outside [%.0f-%.0f]", rsi_now, InpRSILongMin, InpRSILongMax)); return false; }
         if(InpRSIRequireTurn && rsi_now <= rsi_old)
         { LogDebug(StringFormat("Skip: long RSI not rising (%.1f<=%.1f)", rsi_now, rsi_old)); return false; }
      }
      else
      {
         if(rsi_now < InpRSIShortMin || rsi_now > InpRSIShortMax)
         { LogDebug(StringFormat("Skip: short RSI %.1f outside [%.0f-%.0f]", rsi_now, InpRSIShortMin, InpRSIShortMax)); return false; }
         if(InpRSIRequireTurn && rsi_now >= rsi_old)
         { LogDebug(StringFormat("Skip: short RSI not falling (%.1f>=%.1f)", rsi_now, rsi_old)); return false; }
      }
   }

   // ── Pullback / EMA touch within recent bars ──
   if(InpUsePullback && InpPullbackTouchEMA)
   {
      double fast_ema_now = 0.0;
      if(!ReadBuffer(g_h_fast, 1, fast_ema_now)) return false;

      // Examine last InpPullbackLookback bars: did price recently touch EMA20?
      // For long: at least one bar's low <= EMA in lookback window
      // For short: at least one bar's high >= EMA in lookback window
      Bar bx;
      bool touched = false;
      for(int s = 1; s <= InpPullbackLookback; s++)
      {
         if(!LoadBar(s, bx)) continue;
         double ema_s = 0.0;
         if(!ReadBuffer(g_h_fast, s, ema_s)) continue;
         if(dir > 0 && bx.l <= ema_s){ touched = true; break; }
         if(dir < 0 && bx.h >= ema_s){ touched = true; break; }
      }
      if(!touched)
      {
         LogDebug("Skip: no recent EMA touch (no pullback)");
         return false;
      }
   }

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

bool OpenTrade(int dir, double extreme, double atr, string pname)
{
   if(!IsSpreadOK()){ LogDebug("Skip: spread"); return false; }

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry  = (dir > 0) ? ask : bid;
   double buffer = atr * InpATRBufferMult;
   double sl, tp;
   if(dir > 0)
   {
      sl = NormalizeDouble(extreme - buffer, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0){ LogWarn("Bad SL distance long"); return false; }
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(extreme + buffer, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0){ LogWarn("Bad SL distance short"); return false; }
      tp = NormalizeDouble(entry - dist * InpRRRatio, digits);
   }

   double sl_dist = MathAbs(entry - sl);
   double vol = ComputeLot(sl_dist);
   if(vol <= 0.0){ LogWarn("Lot calc returned 0"); return false; }

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      LogInfo(StringFormat("%s %s %.2f @ %.2f SL=%.2f TP=%.2f (risk=%.1f%% lot=%.2f)",
              dir > 0 ? "BUY" : "SELL", pname, vol, entry, sl, tp, InpRiskPercent, vol));
      // Capture the just-opened ticket so we can record P/L when it closes
      ulong t = 0; long ty = -1; datetime ot = 0;
      if(FindOurPosition(t, ty, ot)) g_last_open_ticket = t;
   }
   return ok;
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

void CheckTimeStop(ulong ticket, datetime open_time)
{
   if(!InpUseTimeStop || open_time == 0) return;
   datetime now;
   datetime times[]; ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, g_tf, 0, 1, times) != 1) return;
   now = times[0];
   long bars_held = (long)((now - open_time) / PeriodSeconds(g_tf));
   if(bars_held >= InpMaxHoldBars)
   {
      LogInfo(StringFormat("Time stop: closing ticket %I64u after %d bars", ticket, (int)bars_held));
      if(g_trade.PositionClose(ticket)) RecordTradeResult(ticket);
   }
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   string up = _Symbol; StringToUpper(up);
   if(InpRequireGold && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   { LogError("Symbol must be XAU/Gold"); return INIT_FAILED; }
   if(InpRequireM5 && g_tf != PERIOD_M5)
   { LogError("Timeframe must be M5"); return INIT_FAILED; }

   if(!g_sym.Name(_Symbol)){ LogError("CSymbolInfo failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)){ LogError("SymbolSelect failed"); return INIT_FAILED; }

   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
   { LogError("Risk % must be in (0,10]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRRRatio < 1.0)
   { LogError("R:R must be >= 1.0"); return INIT_PARAMETERS_INCORRECT; }

   g_h_atr  = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_htf  = iMA(_Symbol, InpHTFPeriod, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_rsi  = iRSI(_Symbol, g_tf, InpRSIPeriod, PRICE_CLOSE);
   g_h_adx  = iADX(_Symbol, g_tf, InpADXPeriod);
   g_h_fast = iMA(_Symbol, g_tf, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_h_atr == INVALID_HANDLE || g_h_htf == INVALID_HANDLE ||
      g_h_rsi == INVALID_HANDLE || g_h_adx == INVALID_HANDLE ||
      g_h_fast== INVALID_HANDLE)
   { LogError("Indicator handle failed"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   StateLoad();

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF %s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("Risk=%.2f%% R:R=%.1f  Compound=%s",
           InpRiskPercent, InpRRRatio, InpCompound ? "ON" : "OFF"));
   LogInfo(StringFormat("Patterns: Engulf=%s Pin=%s Star=%s Inside=%s",
           InpUseEngulfing?"Y":"N", InpUsePinBar?"Y":"N",
           InpUseStar?"Y":"N", InpUseInsideBar?"Y":"N"));
   LogInfo(StringFormat("HTF=%s EMA%d  Session=%02d-%02d UTC",
           EnumToString(InpHTFPeriod), InpHTFEMAPeriod,
           InpSessionStartHour, InpSessionEndHour));
   LogInfo(StringFormat("Gates: DailyLoss<=%.1f%% Cooldown=%d bars Breaker@%d losses",
           InpMaxDailyLossPct, InpCooldownBars, InpMaxConsecLosses));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_atr  != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_htf  != INVALID_HANDLE) IndicatorRelease(g_h_htf);
   if(g_h_rsi  != INVALID_HANDLE) IndicatorRelease(g_h_rsi);
   if(g_h_adx  != INVALID_HANDLE) IndicatorRelease(g_h_adx);
   if(g_h_fast != INVALID_HANDLE) IndicatorRelease(g_h_fast);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   bool new_bar = IsNewBar();
   if(new_bar)
   {
      if(g_last_loss && g_bars_since_loss < 9999) g_bars_since_loss++;
   }

   ulong ticket = 0; long ptype = -1; datetime opened = 0;
   bool has_pos = FindOurPosition(ticket, ptype, opened);

   // ── Manage open position ──
   if(has_pos)
   {
      g_last_open_ticket = ticket;     // refresh
      CheckTimeStop(ticket, opened);
      return;
   }

   // ── No open position: did our last trade just close? ──
   if(g_last_open_ticket != 0)
   {
      RecordTradeResult(g_last_open_ticket);
      g_last_open_ticket = 0;
   }

   // Only act on new bar to avoid intra-bar repeated signals
   if(!new_bar) return;

   // ── Risk gates ──
   if(!IsSessionAllowed())   { LogDebug("Skip: session");   return; }
   if(IsDailyLossBreached()) { LogDebug("Skip: daily loss");return; }
   if(IsCooldownActive())    { LogDebug("Skip: cooldown");  return; }
   if(IsLossBreakerActive()) { LogDebug("Skip: breaker");   return; }

   // ── ATR & HTF ──
   double atr = 0.0;
   if(!ReadBuffer(g_h_atr, 0, atr) || atr <= 0.0) return;
   double htf_ema = 0.0;
   int htf_dir = GetHTFTrend(htf_ema);
   if(InpUseHTFTrend && htf_dir == 0) { LogDebug("Skip: HTF flat"); return; }

   // ── Pattern scan ──
   PatternHit hit;
   hit.dir = 0; hit.extreme = 0.0; hit.name = "";
   if(!ScanPatterns(atr, hit)) return;

   if(InpUseHTFTrend && hit.dir != htf_dir)
   {
      LogDebug(StringFormat("Skip: %s vs HTF %d", hit.name, htf_dir));
      return;
   }

   // ── Confluence gates (RSI / ADX / pullback / ATR floor) ──
   if(!ConfluencePass(hit.dir, atr)) return;

   OpenTrade(hit.dir, hit.extreme, atr, hit.name);
}
//+------------------------------------------------------------------+
