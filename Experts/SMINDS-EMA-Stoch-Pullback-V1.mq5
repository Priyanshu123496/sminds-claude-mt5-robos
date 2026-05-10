//+------------------------------------------------------------------+
//|                          SMINDS-EMA-Stoch-Pullback-V1.mq5        |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #3 (EMA200 + Stochastic Pullback)         |
//|                                                                  |
//|  Derived from manual XAGUSD M5 screenshot showing successful     |
//|  pullback long: price came down to EMA200, Stochastic 9,3,3      |
//|  bottomed in oversold then crossed up, bullish candle closed     |
//|  back above EMA200 → 2:1 R:R win.                                |
//|                                                                  |
//|  Strategy:                                                       |
//|    Trend filter : price above (long) / below (short) EMA200      |
//|    Setup        : pullback to within `pullback band` of EMA200   |
//|                   in last N bars                                 |
//|    Trigger      : Stochastic %K cross %D from oversold (<25) for |
//|                   longs, overbought (>75) for shorts             |
//|    Confirmation : bar closes back in trend direction with body   |
//|    SL           : pullback swing low/high - ATR buffer           |
//|    TP           : R:R × SL distance (default 2:1)                |
//|                                                                  |
//|  Symbol-agnostic: works on any liquid pair / commodity.          |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS EMA-Stoch Pullback V1 — multi-symbol M5/M15"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96200001;        // Magic number (per-account unique)
input string InpOrderComment      = "SMINDS-ESP-V1"; // Order comment

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT; // Required TF (PERIOD_CURRENT = no constraint)

input group "═══ EMA Trend Filter ═════════════════════════════"
input int    InpEMAPeriod         = 200;             // EMA period
input bool   InpUseEMASlope       = true;            // Require EMA slope to agree
input int    InpEMASlopeBars      = 12;              // Slope lookback

input group "═══ Stochastic Trigger ═══════════════════════════"
input int    InpStochK            = 9;
input int    InpStochD            = 3;
input int    InpStochSlowing      = 3;
input double InpOversold          = 25.0;            // Long zone
input double InpOverbought        = 75.0;            // Short zone
input bool   InpRequireStochCross = true;            // %K must cross %D in trigger bar

input group "═══ Pullback Detection ═══════════════════════════"
input int    InpPullbackBars      = 8;               // Look back N bars for pullback
input double InpPullbackMaxATR    = 1.5;             // Pullback distance from EMA <= this × ATR
input bool   InpRequireEMATouch   = true;            // Bar low/high must reach the EMA

input group "═══ Entry Confirmation ═══════════════════════════"
input bool   InpRequireBodyClose  = true;            // Bullish/bearish candle body
input double InpMinBodyATR        = 0.30;            // Min body size as fraction of ATR

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLBufferATR       = 0.30;            // SL buffer beyond swing extreme
input double InpRRRatio           = 2.0;             // TP = R:R × SL distance

input group "═══ Position Sizing ════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 1.5;             // Boosted from 1.0% — DD99 has headroom
input double InpLotSize           = 0.10;            // Fallback fixed lot
input double InpMaxLotSize        = 5.00;
input double InpMinLotSize        = 0.01;

input group "═══ Risk Circuit Breakers ════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 4;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 8;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 60;              // 60 M5 bars = 5h, M15 = 15h

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 6;
input int    InpSessionEndHour    = 22;

input group "═══ Daily Trade Cap ═══════════════════════════════"
input int    InpMaxTradesPerDay   = 6;

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 80;
input int    InpSlippagePoints    = 30;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-ESP-V1"
#define GV_PREFIX "SMESP1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_ema   = INVALID_HANDLE;
int g_h_stoch = INVALID_HANDLE;
int g_h_atr   = INVALID_HANDLE;

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
datetime g_open_bar_time   = 0;

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

bool ReadBuf(int handle, int buf_idx, int shift, double &v)
{
   double buf[]; ArraySetAsSeries(buf, true);
   int n = shift + 1;
   if(CopyBuffer(handle, buf_idx, 0, n, buf) != n) return false;
   v = buf[shift];
   return MathIsValidNumber(v);
}

bool ReadEMA(int shift, double &v)   { return ReadBuf(g_h_ema,   0, shift, v); }
bool ReadStochK(int shift, double &v){ return ReadBuf(g_h_stoch, 0, shift, v); }
bool ReadStochD(int shift, double &v){ return ReadBuf(g_h_stoch, 1, shift, v); }
bool ReadATR(int shift, double &v)   { return ReadBuf(g_h_atr,   0, shift, v); }

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
         type = PositionGetInteger(POSITION_TYPE);
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
      g_today_trades    = 0;
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

bool IsDailyTradeLimitReached()
{
   if(InpMaxTradesPerDay <= 0) return false;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   if(today != g_today)
   {
      g_today        = today;
      g_today_trades = 0;
      g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   return (g_today_trades >= InpMaxTradesPerDay);
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   long s = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return s <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Trend / pullback / trigger                                        |
//+------------------------------------------------------------------+

// Returns +1 = uptrend (price > EMA & EMA rising), -1 = downtrend, 0 = neutral
int GetTrendDirection()
{
   double ema_now = 0.0, ema_old = 0.0;
   if(!ReadEMA(0, ema_now) || !ReadEMA(InpEMASlopeBars, ema_old)) return 0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool slope_up   = ema_now > ema_old;
   bool slope_down = ema_now < ema_old;
   bool price_up   = price > ema_now;
   bool price_down = price < ema_now;

   if(InpUseEMASlope)
   {
      if(slope_up && price_up)     return  1;
      if(slope_down && price_down) return -1;
      return 0;
   }
   else
   {
      if(price_up)   return  1;
      if(price_down) return -1;
      return 0;
   }
}

// True if a recent pullback to EMA occurred (last InpPullbackBars bars)
// Long: at least one bar's low <= EMA (or within InpPullbackMaxATR × ATR above EMA)
// Short: at least one bar's high >= EMA (or within band below)
// Also returns the swing extreme for SL
bool DetectPullback(int dir, double atr, double &swing_extreme)
{
   double lows[], highs[];
   ArraySetAsSeries(lows, true); ArraySetAsSeries(highs, true);
   if(CopyLow (_Symbol, g_tf, 0, InpPullbackBars + 1, lows)  != InpPullbackBars + 1) return false;
   if(CopyHigh(_Symbol, g_tf, 0, InpPullbackBars + 1, highs) != InpPullbackBars + 1) return false;

   bool touched = false;
   double extreme = (dir > 0) ? DBL_MAX : 0.0;

   for(int s = 1; s <= InpPullbackBars; s++)
   {
      double ema_s = 0.0;
      if(!ReadEMA(s, ema_s)) continue;

      if(dir > 0)
      {
         // Within band (above or touching)
         double dist_above = lows[s] - ema_s;
         if(dist_above <= 0.0) touched = true;                              // crossed below
         else if(dist_above <= atr * InpPullbackMaxATR && !InpRequireEMATouch) touched = true;
         if(lows[s] < extreme) extreme = lows[s];
      }
      else
      {
         double dist_below = ema_s - highs[s];
         if(dist_below <= 0.0) touched = true;
         else if(dist_below <= atr * InpPullbackMaxATR && !InpRequireEMATouch) touched = true;
         if(highs[s] > extreme) extreme = highs[s];
      }
   }
   swing_extreme = extreme;
   return touched;
}

// Detect Stochastic trigger on bar 1 (just-closed)
// Long: %K crossed %D from below in oversold region
// Short: %K crossed %D from above in overbought region
bool DetectStochTrigger(int dir)
{
   double k1 = 0.0, k2 = 0.0, d1 = 0.0, d2 = 0.0;
   if(!ReadStochK(1, k1) || !ReadStochK(2, k2)) return false;
   if(!ReadStochD(1, d1) || !ReadStochD(2, d2)) return false;

   if(dir > 0)
   {
      // Was oversold recently and is rising; %K crossed up through %D
      if(InpRequireStochCross)
      {
         bool crossed_up = (k2 <= d2) && (k1 > d1);
         if(!crossed_up) return false;
      }
      // Recent oversold visit
      double k3 = 0.0;
      if(ReadStochK(3, k3))
      {
         if(MathMin(k1, MathMin(k2, k3)) > InpOversold) return false;  // never went into oversold
      }
      return true;
   }
   else
   {
      if(InpRequireStochCross)
      {
         bool crossed_down = (k2 >= d2) && (k1 < d1);
         if(!crossed_down) return false;
      }
      double k3 = 0.0;
      if(ReadStochK(3, k3))
      {
         if(MathMax(k1, MathMax(k2, k3)) < InpOverbought) return false;
      }
      return true;
   }
}

// Confirmation: bar 1 closed above EMA (long) / below EMA (short) with bullish/bearish body
bool DetectConfirmation(int dir, double atr)
{
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;
   double ema1 = 0.0;
   if(!ReadEMA(1, ema1)) return false;

   double body = MathAbs(closes[1] - opens[1]);
   if(body < atr * InpMinBodyATR && InpRequireBodyClose) return false;

   if(dir > 0)
   {
      if(closes[1] <= ema1) return false;
      if(InpRequireBodyClose && closes[1] <= opens[1]) return false;
      return true;
   }
   else
   {
      if(closes[1] >= ema1) return false;
      if(InpRequireBodyClose && closes[1] >= opens[1]) return false;
      return true;
   }
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

bool OpenTrade(int dir, double swing_extreme, double atr)
{
   if(!IsSpreadOK()){ LogDebug("Skip: spread"); return false; }

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double buffer = atr * InpSLBufferATR;
   double sl, tp;

   if(dir > 0)
   {
      sl = NormalizeDouble(swing_extreme - buffer, digits);
      sl = EnforceMinStop(sl, entry, true);
      double dist = entry - sl;
      if(dist <= 0.0){ LogWarn("Bad SL distance long"); return false; }
      tp = NormalizeDouble(entry + dist * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(swing_extreme + buffer, digits);
      sl = EnforceMinStop(sl, entry, false);
      double dist = sl - entry;
      if(dist <= 0.0){ LogWarn("Bad SL distance short"); return false; }
      tp = NormalizeDouble(entry - dist * InpRRRatio, digits);
   }

   double sl_dist = MathAbs(entry - sl);
   double vol = ComputeLotSize(sl_dist);
   if(vol <= 0.0){ LogWarn("Lot calc zero"); return false; }

   bool ok = ExecOrder(dir > 0, vol, sl, tp);
   if(ok)
   {
      g_today_trades++;
      datetime times[]; ArraySetAsSeries(times, true);
      if(CopyTime(_Symbol, g_tf, 0, 1, times) == 1) g_open_bar_time = times[0];
      LogInfo(StringFormat("%s %.2f @ %.5f SL=%.5f TP=%.5f #%d/day",
              dir > 0 ? "BUY" : "SELL", vol, entry, sl, tp, g_today_trades));
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

void ManageOpen(ulong ticket, datetime open_time)
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

   if(InpEMAPeriod < 20){ LogError("EMA period too small"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRRRatio < 0.5){ LogError("R:R too small"); return INIT_PARAMETERS_INCORRECT; }

   g_h_ema   = iMA   (_Symbol, g_tf, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_stoch = iStochastic(_Symbol, g_tf, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
   g_h_atr   = iATR  (_Symbol, g_tf, InpATRPeriod);
   if(g_h_ema == INVALID_HANDLE || g_h_stoch == INVALID_HANDLE || g_h_atr == INVALID_HANDLE)
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
   else
      StateLoad();

   g_today           = (datetime)((long)TimeCurrent() / 86400 * 86400);
   g_daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("EMA(%d)  Stoch(%d,%d,%d)  OS=%.0f OB=%.0f",
           InpEMAPeriod, InpStochK, InpStochD, InpStochSlowing, InpOversold, InpOverbought));
   LogInfo(StringFormat("Pullback: lookback=%d maxATR=%.1f touchEMA=%s",
           InpPullbackBars, InpPullbackMaxATR, InpRequireEMATouch ? "Y" : "N"));
   LogInfo(StringFormat("R:R=%.1f  SLbuf=%.2fxATR  Lot=%s risk=%.1f%%",
           InpRRRatio, InpSLBufferATR,
           InpUseRiskBasedLot ? "RISK" : "FIXED", InpRiskPercent));
   LogInfo(StringFormat("Session=%02d-%02d UTC  MaxTradesPerDay=%d",
           InpSessionStartHour, InpSessionEndHour, InpMaxTradesPerDay));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_ema   != INVALID_HANDLE) IndicatorRelease(g_h_ema);
   if(g_h_stoch != INVALID_HANDLE) IndicatorRelease(g_h_stoch);
   if(g_h_atr   != INVALID_HANDLE) IndicatorRelease(g_h_atr);
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
      ManageOpen(ticket, opened);
      return;
   }
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
   }

   if(!new_bar) return;

   // Risk gates
   if(!IsSessionAllowed())     { LogDebug("Skip: session");      return; }
   if(IsDailyLossBreached())   { LogDebug("Skip: daily loss");   return; }
   if(IsCooldownActive())      { LogDebug("Skip: cooldown");     return; }
   if(IsLossBreakerActive())   { LogDebug("Skip: breaker");      return; }
   if(IsDailyTradeLimitReached()){ LogDebug("Skip: daily-cap");  return; }

   // Trend
   int dir = GetTrendDirection();
   if(dir == 0) return;

   double atr = 0.0;
   if(!ReadATR(0, atr) || atr <= 0.0) return;

   // Pullback
   double swing = 0.0;
   if(!DetectPullback(dir, atr, swing))
   {
      LogDebug("Skip: no recent pullback to EMA");
      return;
   }

   // Stochastic
   if(!DetectStochTrigger(dir))
   {
      LogDebug("Skip: no Stoch trigger");
      return;
   }

   // Confirmation
   if(!DetectConfirmation(dir, atr))
   {
      LogDebug("Skip: no confirmation candle");
      return;
   }

   OpenTrade(dir, swing, atr);
}
//+------------------------------------------------------------------+
