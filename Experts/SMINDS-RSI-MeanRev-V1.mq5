//+------------------------------------------------------------------+
//|                              SMINDS-RSI-MeanRev-V1.mq5           |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #6 (RSI Mean Reversion)                   |
//|                                                                  |
//|  Counter-trend strategy class — fades extreme RSI readings.      |
//|                                                                  |
//|  Setup:                                                          |
//|    1. Range filter — ADX < threshold (no strong trend)           |
//|       Without this filter, RSI mean rev fails in trends.         |
//|    2. RSI(14) crosses UP from oversold zone => long              |
//|    3. RSI(14) crosses DOWN from overbought zone => short         |
//|    4. Bullish/bearish candle confirms                            |
//|                                                                  |
//|  Exit:                                                           |
//|    - SL: ATR-based (tight, since mean rev should snap fast)      |
//|    - TP: 1.5:1 default (small targets — reversion is quick)      |
//|    - Time stop: cap holding period to avoid stale positions      |
//|                                                                  |
//|  Strategy class: COUNTER-TREND / MEAN REVERSION (uncorrelated    |
//|  with the trend, pullback, and volatility-breakout EAs).         |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS RSI Mean Reversion V1 — multi-symbol"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96600001;
input string InpOrderComment      = "SMINDS-RSI-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT;

input group "═══ RSI Trigger ══════════════════════════════════"
input int    InpRSIPeriod         = 14;
input double InpOversold          = 30.0;            // Long zone
input double InpOverbought        = 70.0;            // Short zone
input bool   InpRequireCrossOut   = true;            // Wait for RSI to exit OS/OB band (cross 30 up / 70 down)

input group "═══ Range Filter (no-trend regime) ═════════════════"
// Mean reversion fails in trends — ADX must be LOW for setup to fire
input bool   InpUseADXFilter      = true;
input int    InpADXPeriod         = 14;
input double InpMaxADX            = 25.0;            // ADX must be BELOW this

input group "═══ Optional HTF Counter-Trend Filter ═════════════"
// Classic mean rev is COUNTER-trend: only buy oversold dips when HTF is up
// Inverse mode: trade WITH HTF (mean rev as continuation in trend pullbacks)
input bool             InpUseHTFFilter = false;      // Optional HTF guidance
input int              InpHTFFilterMode= 0;          // 0=any, 1=with HTF (continuation), 2=against HTF (pure rev)
input ENUM_TIMEFRAMES  InpHTFPeriod    = PERIOD_H1;
input int              InpHTFEMAPeriod = 50;
input int              InpHTFSlopeBars = 6;

input group "═══ Confirmation Candle ══════════════════════════"
input bool   InpRequireBodyClose  = true;
input double InpMinBodyATR        = 0.30;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;
input double InpSLATRMult         = 1.5;             // SL = entry ± ATR × this
input double InpRRRatio           = 1.5;             // Mean rev: small targets, hits often
input bool   InpUseTrailingTP     = false;           // Off — reversion is fast, no need to trail

input group "═══ Position Sizing ════════════════════════════"
input bool   InpUseRiskBasedLot   = true;
input double InpRiskPercent       = 1.0;
input double InpLotSize           = 0.10;
input double InpMaxLotSize        = 5.00;
input double InpMinLotSize        = 0.01;

input group "═══ Risk Circuit Breakers ════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 4;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 6;
input int    InpMaxTradesPerDay   = 4;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 30;              // Mean rev should resolve quickly

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 6;
input int    InpSessionEndHour    = 22;

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
#define EA_TAG    "SMINDS-RSI-V1"
#define GV_PREFIX "SMRSI1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_rsi      = INVALID_HANDLE;
int g_h_adx      = INVALID_HANDLE;
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
//| Range / HTF / Trigger                                             |
//+------------------------------------------------------------------+
bool IsRangeRegime()
{
   if(!InpUseADXFilter) return true;
   double adx = 0.0;
   if(!ReadBuf(g_h_adx, 0, 0, adx)) return false;
   bool ok = adx < InpMaxADX;
   if(!ok) LogDebug(StringFormat("Skip: ADX %.1f >= %.1f (trend regime)", adx, InpMaxADX));
   return ok;
}

int GetHTFTrend()
{
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

// Detect RSI cross out of OB/OS zone on bar 1 (just-closed)
//   Long  : RSI[2] <= Oversold AND RSI[1] > Oversold (crossed up)
//   Short : RSI[2] >= Overbought AND RSI[1] < Overbought (crossed down)
int DetectRSITrigger()
{
   double r1 = 0.0, r2 = 0.0;
   if(!ReadBuf(g_h_rsi, 0, 1, r1)) return 0;
   if(!ReadBuf(g_h_rsi, 0, 2, r2)) return 0;

   if(InpRequireCrossOut)
   {
      if(r2 <= InpOversold   && r1 > InpOversold)   return +1;
      if(r2 >= InpOverbought && r1 < InpOverbought) return -1;
      return 0;
   }
   else
   {
      // Looser: just being below oversold or above overbought on bar 1
      if(r1 < InpOversold)   return +1;
      if(r1 > InpOverbought) return -1;
      return 0;
   }
}

bool DetectConfirmation(int dir, double atr)
{
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return false;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return false;

   double body = MathAbs(closes[1] - opens[1]);
   if(InpRequireBodyClose && body < atr * InpMinBodyATR) return false;

   if(dir > 0)
   {
      if(InpRequireBodyClose && closes[1] <= opens[1]) return false;
      return true;
   }
   else
   {
      if(InpRequireBodyClose && closes[1] >= opens[1]) return false;
      return true;
   }
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

bool OpenTrade(int dir, double atr)
{
   if(!IsSpreadOK()) return false;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry  = (dir > 0) ? ask : bid;
   double sl_dist = atr * InpSLATRMult;

   double sl, tp;
   if(dir > 0)
   {
      sl = NormalizeDouble(entry - sl_dist, digits);
      sl = EnforceMinStop(sl, entry, true);
      tp = NormalizeDouble(entry + (entry - sl) * InpRRRatio, digits);
   }
   else
   {
      sl = NormalizeDouble(entry + sl_dist, digits);
      sl = EnforceMinStop(sl, entry, false);
      tp = NormalizeDouble(entry - (sl - entry) * InpRRRatio, digits);
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

   if(InpOversold >= InpOverbought){ LogError("Oversold must be < Overbought"); return INIT_PARAMETERS_INCORRECT; }
   if(InpHTFFilterMode < 0 || InpHTFFilterMode > 2){ LogError("HTFFilterMode 0/1/2"); return INIT_PARAMETERS_INCORRECT; }

   g_h_rsi     = iRSI(_Symbol, g_tf, InpRSIPeriod, PRICE_CLOSE);
   g_h_adx     = iADX(_Symbol, g_tf, InpADXPeriod);
   g_h_atr     = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_htf_ema = iMA (_Symbol, InpHTFPeriod, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_h_rsi == INVALID_HANDLE || g_h_adx == INVALID_HANDLE ||
      g_h_atr == INVALID_HANDLE || g_h_htf_ema == INVALID_HANDLE)
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

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("RSI(%d) OS=%.0f OB=%.0f  CrossOut=%s",
           InpRSIPeriod, InpOversold, InpOverbought, InpRequireCrossOut ? "Y" : "N"));
   LogInfo(StringFormat("Range filter: ADX(%d) < %.1f  (regime gate)",
           InpADXPeriod, InpMaxADX));
   LogInfo(StringFormat("HTF=%s mode=%d  R:R=%.1f  SL=ATRx%.1f  Risk=%.1f%%",
           InpUseHTFFilter ? "ON" : "OFF", InpHTFFilterMode,
           InpRRRatio, InpSLATRMult, InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_rsi      != INVALID_HANDLE) IndicatorRelease(g_h_rsi);
   if(g_h_adx      != INVALID_HANDLE) IndicatorRelease(g_h_adx);
   if(g_h_atr      != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_htf_ema  != INVALID_HANDLE) IndicatorRelease(g_h_htf_ema);
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

   // Range regime check
   if(!IsRangeRegime()) return;

   // RSI trigger
   int dir = DetectRSITrigger();
   if(dir == 0) return;

   // HTF filter (optional, modes 1=continuation, 2=against)
   if(InpUseHTFFilter)
   {
      int htf_dir = GetHTFTrend();
      if(htf_dir == 0) return;
      if(InpHTFFilterMode == 1 && dir != htf_dir) return;     // require same dir
      if(InpHTFFilterMode == 2 && dir == htf_dir) return;     // require opposite (pure rev)
   }

   // ATR + confirmation
   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;
   if(!DetectConfirmation(dir, atr))
   {
      LogDebug("Skip: no confirmation candle");
      return;
   }

   OpenTrade(dir, atr);
}
//+------------------------------------------------------------------+
