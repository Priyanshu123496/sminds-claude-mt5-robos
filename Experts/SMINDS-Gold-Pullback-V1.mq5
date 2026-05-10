//+------------------------------------------------------------------+
//|                                  SMINDS-Gold-Pullback-V1.mq5     |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Trend-pullback continuation EA for XAUUSD M15.                  |
//|  DESIGNED AS A SIGNAL DIVERSIFIER TO TTR-XI-V12.                 |
//|                                                                  |
//|  Strategy thesis:                                                |
//|    TTR-XI-V12 trades EMA crosses (catches trend at start).       |
//|    This EA trades pullbacks-to-EMA20 (catches trend mid-move).   |
//|    Both are trend-aligned but signal timing differs, giving      |
//|    different drawdown windows and smoother combined PnL.         |
//|                                                                  |
//|  Setup:                                                          |
//|    1. EMA stack: 9 > 20 > 50 (long) or 9 < 20 < 50 (short)       |
//|    2. EMA200 trend agreement: price above EMA200 (long) or below |
//|    3. Pullback detected: 3+ bars retracing toward EMA20          |
//|    4. Reversal candle near EMA20 (within ±0.5×ATR)               |
//|    5. ADX ≥ 22 (trending market)                                 |
//|    6. Vol filter (ATR/baseline ≤ 1.5)                            |
//|    7. Session 7-20 UTC                                           |
//|    8. Spread guard                                               |
//|                                                                  |
//|  Stops/targets:                                                  |
//|    SL: pullback extreme ∓ 0.5 × ATR                              |
//|    TP: 2.0 × ATR (configurable)                                  |
//|                                                                  |
//|  Risk infrastructure (same suite as TTR-XI-V12):                 |
//|    - Dynamic lot halving (15% DD halve, 5% restore, hysteresis) |
//|    - Daily loss limit (3% equity)                                |
//|    - Cooldown (4 bars after loss)                                |
//|    - Consecutive-loss breaker (2 → halt for the day)             |
//|    - GlobalVariable state persistence                            |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Gold-Pullback V1 — trend pullback continuation"
#property description "XAUUSD M15 — designed to diversify TTR-XI-V12"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Strategy Identification ════════════════════════"
input long   InpMagicNumber       = 94736330;        // Magic (distinct from TTR-XI-V12=94736312)
input string InpOrderComment      = "GPB-V1";        // Order comment

input group "═══ Symbol / Timeframe Guard ══════════════════════"
input bool   InpRequireXAUUSD     = true;            // Reject if symbol is not XAU/Gold
input bool   InpRequireM15        = true;            // Reject if timeframe is not M15

input group "═══ EMA Stack ══════════════════════════════════════"
input int    InpEMAFastPeriod     = 9;               // Fast EMA (top of stack)
input int    InpEMAMedPeriod      = 20;              // Medium EMA (pullback target)
input int    InpEMASlowPeriod     = 50;              // Slow EMA (stack base)
input int    InpEMAFilterPeriod   = 200;             // EMA200 (macro trend filter)

input group "═══ Volatility / Trend Indicators ══════════════════"
input int    InpATRPeriod         = 14;              // ATR for SL/TP/distance
input int    InpATRBaselinePeriod = 50;              // Long ATR baseline
input int    InpADXPeriod         = 14;              // ADX period

input group "═══ Trend Gate (must be trending) ══════════════════"
input bool   InpUseADXGate        = true;            // Require trending market
input double InpMinADX            = 22.0;            // ADX must be ≥ this
input bool   InpUseSlopeFilter    = true;            // Require EMA50 to be sloping in trend dir
input int    InpSlopeBars         = 8;               // EMA50 slope lookback (bars)
input double InpMinSlopeATR       = 0.3;             // Min |EMA50 slope| / ATR over lookback

input group "═══ Pullback Detection ═══════════════════════════"
input int    InpMinPullbackBars   = 2;               // ≥ this many bars retracing toward EMA20
input double InpPullbackToEMAATR  = 0.6;             // Bar close must be within this × ATR of EMA20

input group "═══ Reversal Candle Confirmation ═════════════════"
input bool   InpUseEngulfing      = true;            // Accept bullish/bearish engulfing
input bool   InpUsePinBar         = true;            // Accept pin bar (long-wick rejection)
input double InpPinWickRatio      = 0.50;            // wick must be ≥ this fraction of range
input double InpPinBodyRatio      = 0.40;            // body must be ≤ this fraction of range

input group "═══ Vol-Spike Filter ════════════════════════════"
input bool   InpUseVolFilter      = true;            // Skip when ATR/baseline too high
input double InpMaxATRRatio       = 1.5;             // Reject if ATR > baseline × this

input group "═══ Stops / Targets ═══════════════════════════════"
input double InpSLBufferATR       = 0.5;             // SL = pullback extreme ∓ this × ATR
input double InpSLMaxATR          = 2.0;             // Cap SL distance to ≤ this × ATR
input double InpTPATRMultiplier   = 2.0;             // TP = entry ± this × ATR
input double InpMinRR             = 1.0;             // Skip if RR < this

input group "═══ Position Sizing ═══════════════════════════════"
input double InpLotSize           = 0.20;            // Base lot size
input double InpMinLotSize        = 0.01;            // Hard floor
input double InpMaxLotSize        = 1.00;            // Hard cap

input group "═══ Dynamic Lot Sizing (DD Guard) ═════════════════"
input bool   InpUseDynLots        = true;            // Enable dynamic lot reduction
input double InpDDHalvePercent    = 15.0;            // Halve when DD ≥ this %
input double InpDDRestorePercent  = 5.0;             // Restore when DD < this %

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSessionFilter  = true;            // Restrict to active hours
input int    InpSessionStartHour  = 7;               // Session open (UTC)
input int    InpSessionEndHour    = 20;              // Session close (UTC)

input group "═══ Risk Circuit Breakers ═══════════════════════"
input bool   InpUseDailyLossLimit = true;            // Halt on daily loss
input double InpMaxDailyLossPct   = 3.0;             // Max daily loss % of start-of-day balance
input bool   InpUseCooldown       = true;            // Cooldown after a loss
input int    InpCooldownBars      = 4;               // Cooldown duration (M15 bars)
input bool   InpUseLossBreaker    = true;            // Halt after N consecutive losses
input int    InpMaxConsecLosses   = 2;               // Trip threshold

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 50;              // Skip entry if spread > this (0=disabled)
input int    InpSlippagePoints    = 30;              // Max acceptable slippage on market orders
input int    InpMaxRetries        = 3;               // Retry attempts for trade ops
input int    InpRetryDelayMs      = 500;             // Delay between retries

input group "═══ Diagnostics ═════════════════════════════════"
input bool   InpVerboseLogging    = false;           // Log every filter rejection (noisy)

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG     "GPB-V1"
#define GV_PREFIX  "GPBV1_"

CTrade        g_trade;
CSymbolInfo   g_sym;

int  g_h_ema_fast    = INVALID_HANDLE;
int  g_h_ema_med     = INVALID_HANDLE;
int  g_h_ema_slow    = INVALID_HANDLE;
int  g_h_ema_filter  = INVALID_HANDLE;
int  g_h_atr         = INVALID_HANDLE;
int  g_h_atr_base    = INVALID_HANDLE;
int  g_h_adx         = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;

string g_gv_peak;
string g_gv_consec;
string g_gv_breaker;
string g_gv_balance;

double   g_peak_equity     = 0.0;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;
double   g_last_balance    = 0.0;

datetime g_last_bar              = 0;
bool     g_last_trade_was_loss   = false;
int      g_bars_since_loss       = 9999;
bool     g_lots_halved           = false;
datetime g_today                 = 0;
double   g_daily_start_bal       = 0.0;
ulong    g_open_position_ticket  = 0;
datetime g_open_position_time    = 0;

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
void LogInfo(string msg)    { PrintFormat("[%s] %s", EA_TAG, msg); }
void LogError(string msg)   { PrintFormat("[%s] ERROR: %s", EA_TAG, msg); }
void LogVerbose(string msg) { if(InpVerboseLogging) PrintFormat("[%s] %s", EA_TAG, msg); }

//+------------------------------------------------------------------+
//| State persistence                                                 |
//+------------------------------------------------------------------+
void StateSave()
{
   GlobalVariableSet(g_gv_peak,    g_peak_equity);
   GlobalVariableSet(g_gv_consec,  (double)g_consec_losses);
   GlobalVariableSet(g_gv_breaker, (double)g_breaker_day);
   GlobalVariableSet(g_gv_balance, g_last_balance);
}
void StateLoad()
{
   if(GlobalVariableCheck(g_gv_peak))    g_peak_equity   = GlobalVariableGet(g_gv_peak);
   else                                  g_peak_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(g_gv_consec))  g_consec_losses = (int)GlobalVariableGet(g_gv_consec);
   if(GlobalVariableCheck(g_gv_breaker)) g_breaker_day   = (datetime)(long)GlobalVariableGet(g_gv_breaker);
   if(GlobalVariableCheck(g_gv_balance)) g_last_balance  = GlobalVariableGet(g_gv_balance);
   else                                  g_last_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//| Indicator value fetchers                                          |
//+------------------------------------------------------------------+
double Get1(int handle, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Position size with dynamic DD halving                             |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double step = g_sym.LotsStep();
   double mn   = MathMax(g_sym.LotsMin(), InpMinLotSize);
   double mx   = MathMin(g_sym.LotsMax(), InpMaxLotSize);
   if(step <= 0) step = 0.01;
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
      if(!g_lots_halved && dd_pct >= InpDDHalvePercent)
      {
         g_lots_halved = true;
         LogInfo(StringFormat("DD %.2f%% ≥ %.1f%% — halving lots", dd_pct, InpDDHalvePercent));
      }
      else if(g_lots_halved && dd_pct < InpDDRestorePercent)
      {
         g_lots_halved = false;
         LogInfo(StringFormat("DD %.2f%% < %.1f%% — restoring lots", dd_pct, InpDDRestorePercent));
      }
      if(g_lots_halved) lot *= 0.5;
   }
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Reversal candle detection                                         |
//+------------------------------------------------------------------+
bool IsBullishReversal(double o, double h, double l, double c,
                       double prev_o, double prev_c)
{
   double range = h - l;
   if(range <= 0) return false;
   double body = MathAbs(c - o);

   if(InpUseEngulfing)
   {
      if(prev_c < prev_o && c > o && c >= prev_o && o <= prev_c)
         return true;
   }
   if(InpUsePinBar)
   {
      double lower_wick = MathMin(o, c) - l;
      if(lower_wick / range >= InpPinWickRatio &&
         body / range <= InpPinBodyRatio &&
         c > (l + range * 0.5))
         return true;
   }
   return false;
}

bool IsBearishReversal(double o, double h, double l, double c,
                       double prev_o, double prev_c)
{
   double range = h - l;
   if(range <= 0) return false;
   double body = MathAbs(c - o);

   if(InpUseEngulfing)
   {
      if(prev_c > prev_o && c < o && c <= prev_o && o >= prev_c)
         return true;
   }
   if(InpUsePinBar)
   {
      double upper_wick = h - MathMax(o, c);
      if(upper_wick / range >= InpPinWickRatio &&
         body / range <= InpPinBodyRatio &&
         c < (h - range * 0.5))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Filters                                                           |
//+------------------------------------------------------------------+
bool InSession(datetime t)
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(t, dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
}

bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spr <= InpMaxSpreadPoints;
}

bool TrendingOK()
{
   if(!InpUseADXGate) return true;
   double adx = Get1(g_h_adx, 1);
   if(adx < InpMinADX)
   {
      LogVerbose(StringFormat("Not trending — ADX=%.1f < %.1f", adx, InpMinADX));
      return false;
   }
   return true;
}

bool VolOK()
{
   if(!InpUseVolFilter) return true;
   double atr  = Get1(g_h_atr, 1);
   double base = Get1(g_h_atr_base, 1);
   if(base <= 0) return false;
   double r = atr / base;
   if(r >= InpMaxATRRatio)
   {
      LogVerbose(StringFormat("Vol reject — ATR/baseline=%.2f", r));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Risk gates                                                        |
//+------------------------------------------------------------------+
bool DailyLossOK()
{
   if(!InpUseDailyLossLimit) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today)
   {
      g_today           = today;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   double cur_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss_pct = 100.0 * (g_daily_start_bal - cur_bal) / MathMax(g_daily_start_bal, 0.01);
   if(loss_pct >= InpMaxDailyLossPct)
   {
      LogVerbose(StringFormat("Daily-loss halt — loss=%.2f%%", loss_pct));
      return false;
   }
   return true;
}

bool BreakerOK()
{
   if(!InpUseLossBreaker) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(g_breaker_day == today)
   {
      LogVerbose("Loss-breaker active for today");
      return false;
   }
   return true;
}

bool CooldownOK()
{
   if(!InpUseCooldown) return true;
   if(g_last_trade_was_loss && g_bars_since_loss < InpCooldownBars)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Position management                                               |
//+------------------------------------------------------------------+
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

void OpenPosition(bool is_long, double entry_ref, double sl, double tp, double lot)
{
   double stops_lvl_pts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = g_sym.Point();
   double min_dist = stops_lvl_pts * pt;

   if(is_long)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask - sl < min_dist) sl = ask - min_dist - pt;
      if(tp - bid < min_dist) tp = bid + min_dist + pt;
      for(int retry = 0; retry < InpMaxRetries; retry++)
      {
         if(g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("BUY %.2f @ %.5f SL=%.5f TP=%.5f", lot, ask, sl, tp));
            return;
         }
         Sleep(InpRetryDelayMs);
      }
      LogError("BUY failed");
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(sl - bid < min_dist) sl = bid + min_dist + pt;
      if(ask - tp < min_dist) tp = ask - min_dist - pt;
      for(int retry = 0; retry < InpMaxRetries; retry++)
      {
         if(g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpOrderComment))
         {
            LogInfo(StringFormat("SELL %.2f @ %.5f SL=%.5f TP=%.5f", lot, bid, sl, tp));
            return;
         }
         Sleep(InpRetryDelayMs);
      }
      LogError("SELL failed");
   }
}

//+------------------------------------------------------------------+
//| Track last closed trade PnL for breaker / cooldown                |
//+------------------------------------------------------------------+
void CheckLastClosedTradePnL()
{
   if(!HistorySelect(TimeCurrent() - 7*24*60*60, TimeCurrent() + 60))
      return;
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
         {
            g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
            LogInfo(StringFormat("BREAKER tripped — halting today after %d losses", g_consec_losses));
         }
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

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   string up = _Symbol;
   StringToUpper(up);
   if(InpRequireXAUUSD && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   { LogError("Symbol must be XAU/Gold"); return INIT_FAILED; }
   if(InpRequireM15 && g_tf != PERIOD_M15)
   { LogError("Timeframe must be M15"); return INIT_FAILED; }
   if(!g_sym.Name(_Symbol)) { LogError("CSymbolInfo failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)) { LogError("SymbolSelect failed"); return INIT_FAILED; }

   if(!(InpEMAFastPeriod < InpEMAMedPeriod && InpEMAMedPeriod < InpEMASlowPeriod && InpEMASlowPeriod < InpEMAFilterPeriod))
   { LogError("EMA periods invalid"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDDHalvePercent <= InpDDRestorePercent) { LogError("DD hysteresis invalid"); return INIT_PARAMETERS_INCORRECT; }

   g_h_ema_fast    = iMA(_Symbol, g_tf, InpEMAFastPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_med     = iMA(_Symbol, g_tf, InpEMAMedPeriod,    0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_slow    = iMA(_Symbol, g_tf, InpEMASlowPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_filter  = iMA(_Symbol, g_tf, InpEMAFilterPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_atr         = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_atr_base    = iATR(_Symbol, g_tf, InpATRBaselinePeriod);
   g_h_adx         = iADX(_Symbol, g_tf, InpADXPeriod);

   if(g_h_ema_fast   == INVALID_HANDLE || g_h_ema_med    == INVALID_HANDLE ||
      g_h_ema_slow   == INVALID_HANDLE || g_h_ema_filter == INVALID_HANDLE ||
      g_h_atr        == INVALID_HANDLE || g_h_atr_base   == INVALID_HANDLE ||
      g_h_adx        == INVALID_HANDLE)
   { LogError("Indicator init failed"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_peak    = StringFormat("%s%lld_%s_peak",    GV_PREFIX, acct, _Symbol);
   g_gv_consec  = StringFormat("%s%lld_%s_consec",  GV_PREFIX, acct, _Symbol);
   g_gv_breaker = StringFormat("%s%lld_%s_breaker", GV_PREFIX, acct, _Symbol);
   g_gv_balance = StringFormat("%s%lld_%s_balance", GV_PREFIX, acct, _Symbol);

   if(MQLInfoInteger(MQL_TESTER))
   {
      GlobalVariableDel(g_gv_peak);
      GlobalVariableDel(g_gv_consec);
      GlobalVariableDel(g_gv_breaker);
      GlobalVariableDel(g_gv_balance);
      g_peak_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      g_consec_losses = 0;
      g_breaker_day   = 0;
      g_last_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   else { StateLoad(); }

   LogInfo("─────────── INIT ───────────");
   LogInfo(StringFormat("Symbol/TF      : %s / %s", _Symbol, EnumToString(g_tf)));
   LogInfo(StringFormat("Magic / Comment: %lld / %s", InpMagicNumber, InpOrderComment));
   LogInfo("Strategy       : TREND PULLBACK to EMA20 in trending markets");
   LogInfo(StringFormat("Trend stack    : EMA%d > EMA%d > EMA%d (vs EMA%d filter)",
                        InpEMAFastPeriod, InpEMAMedPeriod, InpEMASlowPeriod, InpEMAFilterPeriod));
   LogInfo(StringFormat("Trend gate     : ADX ≥ %.0f", InpMinADX));
   LogInfo(StringFormat("Pullback       : ≥ %d retracing bars, close within %.1f×ATR of EMA%d",
                        InpMinPullbackBars, InpPullbackToEMAATR, InpEMAMedPeriod));
   LogInfo(StringFormat("SL/TP          : SL=pullback±%.1fATR (cap %.1f)  TP=%.1fATR  MinRR=%.2f",
                        InpSLBufferATR, InpSLMaxATR, InpTPATRMultiplier, InpMinRR));
   LogInfo(StringFormat("Lot            : base=%.2f dyn=%s halve@%.0f%% restore@%.0f%%",
                        InpLotSize, InpUseDynLots ? "ON" : "OFF",
                        InpDDHalvePercent, InpDDRestorePercent));
   LogInfo(StringFormat("Risk Gates     : DailyLoss<=%.1f%% Cooldown=%d Breaker@%d losses",
                        InpMaxDailyLossPct, InpCooldownBars, InpMaxConsecLosses));
   LogInfo(StringFormat("Session        : %02d-%02d UTC", InpSessionStartHour, InpSessionEndHour));
   LogInfo("────────────────────────────");

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_bars_since_loss = 9999;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   int handles[] = { g_h_ema_fast, g_h_ema_med, g_h_ema_slow, g_h_ema_filter, g_h_atr, g_h_atr_base, g_h_adx };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
   LogInfo(StringFormat("Deinit (reason=%d)", reason));
}

//+------------------------------------------------------------------+
//| Detect bullish/bearish trend stack and pullback                   |
//+------------------------------------------------------------------+
//| Returns +1 if uptrend pullback ready, -1 if downtrend pullback,   |
//| 0 if no setup                                                     |
//+------------------------------------------------------------------+
int DetectPullbackDirection(double atr)
{
   double ef = Get1(g_h_ema_fast, 1);
   double em = Get1(g_h_ema_med, 1);
   double es = Get1(g_h_ema_slow, 1);
   double e2 = Get1(g_h_ema_filter, 1);
   if(ef <= 0 || em <= 0 || es <= 0 || e2 <= 0) return 0;

   double c1 = iClose(_Symbol, g_tf, 1);

   bool uptrend   = (ef > em && em > es && c1 > e2);
   bool downtrend = (ef < em && em < es && c1 < e2);

   if(!uptrend && !downtrend) return 0;

   // ── EMA50 slope filter — must be moving in trend direction ──
   if(InpUseSlopeFilter)
   {
      double es_now  = es;
      double es_back = Get1(g_h_ema_slow, 1 + InpSlopeBars);
      if(es_back <= 0) return 0;
      double slope = es_now - es_back;
      double slope_norm = MathAbs(slope) / atr;
      if(slope_norm < InpMinSlopeATR)
      {
         LogVerbose(StringFormat("Slope reject — EMA50 slope=%.2fATR < %.2f", slope_norm, InpMinSlopeATR));
         return 0;
      }
      if(uptrend && slope <= 0) return 0;
      if(downtrend && slope >= 0) return 0;
   }

   // Verify pullback toward EMA20: bar[1] close must be near EMA20
   double dist_to_med = MathAbs(c1 - em);
   if(dist_to_med > InpPullbackToEMAATR * atr)
   {
      LogVerbose(StringFormat("No pullback — close %.2f from EMA%d (need ≤ %.2f×ATR)",
                              dist_to_med/atr, InpEMAMedPeriod, InpPullbackToEMAATR));
      return 0;
   }

   // Count retracing bars: bars[2..K+1] moving toward EMA20 from the trend extreme
   // For uptrend: prior bars should have closed lower than EMA-stack peak (pullback down)
   // For downtrend: prior bars should have closed higher than EMA-stack trough
   int retraces = 0;
   if(uptrend)
   {
      // Look back from bar[2]: bar[i].close should be ≤ bar[i+1].close (descending)
      for(int i = 2; i <= InpMinPullbackBars + 2; i++)
      {
         double ci   = iClose(_Symbol, g_tf, i);
         double cip1 = iClose(_Symbol, g_tf, i + 1);
         if(ci <= cip1) retraces++;
         else break;
      }
   }
   else
   {
      for(int i = 2; i <= InpMinPullbackBars + 2; i++)
      {
         double ci   = iClose(_Symbol, g_tf, i);
         double cip1 = iClose(_Symbol, g_tf, i + 1);
         if(ci >= cip1) retraces++;
         else break;
      }
   }

   if(retraces < InpMinPullbackBars)
   {
      LogVerbose(StringFormat("Insufficient pullback bars: %d < %d", retraces, InpMinPullbackBars));
      return 0;
   }

   return uptrend ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Entry attempt                                                     |
//+------------------------------------------------------------------+
void TryEntry()
{
   double atr = Get1(g_h_atr, 1);
   if(atr <= 0) return;

   int dir = DetectPullbackDirection(atr);
   if(dir == 0) return;

   double o1 = iOpen(_Symbol,  g_tf, 1);
   double h1 = iHigh(_Symbol,  g_tf, 1);
   double l1 = iLow(_Symbol,   g_tf, 1);
   double c1 = iClose(_Symbol, g_tf, 1);
   double o2 = iOpen(_Symbol,  g_tf, 2);
   double c2 = iClose(_Symbol, g_tf, 2);

   if(dir > 0 && IsBullishReversal(o1, h1, l1, c1, o2, c2))
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      // SL: pullback low (bar[1] or recent bars min) - buffer
      double pb_low = l1;
      for(int i = 2; i <= InpMinPullbackBars + 2; i++)
         pb_low = MathMin(pb_low, iLow(_Symbol, g_tf, i));
      double sl_swing = pb_low - InpSLBufferATR * atr;
      double sl_cap   = ask - InpSLMaxATR * atr;
      double sl       = MathMax(sl_swing, sl_cap);
      double tp       = ask + InpTPATRMultiplier * atr;
      double risk = ask - sl, reward = tp - ask;
      if(risk <= 0 || reward <= 0 || reward / risk < InpMinRR)
      {
         LogVerbose(StringFormat("Long skip — RR=%.2f", reward/MathMax(risk,1e-9)));
         return;
      }
      double lot = ComputeLot();
      OpenPosition(true, c1, sl, tp, lot);
      g_open_position_time = TimeCurrent();
   }
   else if(dir < 0 && IsBearishReversal(o1, h1, l1, c1, o2, c2))
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double pb_high = h1;
      for(int i = 2; i <= InpMinPullbackBars + 2; i++)
         pb_high = MathMax(pb_high, iHigh(_Symbol, g_tf, i));
      double sl_swing = pb_high + InpSLBufferATR * atr;
      double sl_cap   = bid + InpSLMaxATR * atr;
      double sl       = MathMin(sl_swing, sl_cap);
      double tp       = bid - InpTPATRMultiplier * atr;
      double risk = sl - bid, reward = bid - tp;
      if(risk <= 0 || reward <= 0 || reward / risk < InpMinRR)
      {
         LogVerbose(StringFormat("Short skip — RR=%.2f", reward/MathMax(risk,1e-9)));
         return;
      }
      double lot = ComputeLot();
      OpenPosition(false, c1, sl, tp, lot);
      g_open_position_time = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime cur_bar = iTime(_Symbol, g_tf, 0);
   if(cur_bar == 0) return;

   bool new_bar = (cur_bar != g_last_bar);
   if(new_bar)
   {
      g_last_bar = cur_bar;
      g_bars_since_loss++;
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
      return;  // one-position-at-a-time
   }
   else if(g_open_position_ticket != 0)
   {
      CheckLastClosedTradePnL();
   }

   if(!new_bar) return;

   if(!DailyLossOK())   return;
   if(!BreakerOK())     return;
   if(!CooldownOK())    return;
   if(!InSession(cur_bar)) return;
   if(!SpreadOK())      return;
   if(!TrendingOK())    return;
   if(!VolOK())         return;

   TryEntry();
}
//+------------------------------------------------------------------+
