//+------------------------------------------------------------------+
//|                                  SMINDS-BB-Squeeze-V1.mq5        |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #5 (Bollinger Band Squeeze Breakout)      |
//|                                                                  |
//|  Classic John Carter setup:                                      |
//|    1. SQUEEZE: Bollinger Bands fully INSIDE Keltner Channel      |
//|       - Indicates compressed volatility / consolidation          |
//|       - The longer the squeeze, the more potent the breakout     |
//|    2. RELEASE: BB exits KC (volatility expands)                  |
//|    3. ENTRY: price closes above upper BB (long) or below lower   |
//|       BB (short) within N bars after release                     |
//|                                                                  |
//|  Direction filter: HTF EMA50 slope or position vs price          |
//|                                                                  |
//|  Strategy class: VOLATILITY EXPANSION (different from London-BO  |
//|  which uses time-based session range; this is structure-based)   |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS BB-Squeeze Breakout V1 — multi-symbol"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 96500001;
input string InpOrderComment      = "SMINDS-BBS-V1";

input group "═══ Symbol / TF Guard ══════════════════════════════"
input ENUM_TIMEFRAMES  InpRequireTF   = PERIOD_CURRENT;

input group "═══ Bollinger Bands ══════════════════════════════"
input int    InpBBPeriod          = 20;
input double InpBBStdDev          = 2.0;

input group "═══ Keltner Channel ══════════════════════════════"
input int    InpKCPeriod          = 20;
input double InpKCMultiplier      = 1.5;             // Width = EMA20 ± 1.5×ATR
input int    InpKCATRPeriod       = 14;

input group "═══ Squeeze Detection ════════════════════════════"
input int    InpMinSqueezeBars    = 6;               // Min consecutive bars in squeeze
input int    InpMaxSqueezeBars    = 100;             // Cap (avoid stale squeezes)
input int    InpEntryWindowBars   = 5;               // After release, wait this many bars max for breakout

input group "═══ Direction Filter ═════════════════════════════"
input bool   InpUseHTFFilter      = true;
input ENUM_TIMEFRAMES InpHTFPeriod= PERIOD_H1;
input int    InpHTFEMAPeriod      = 50;
input int    InpHTFSlopeBars      = 6;

input group "═══ Stop Loss / Take Profit ══════════════════════"
input int    InpATRPeriod         = 14;              // ATR for SL sizing
input double InpSLATRMult         = 1.5;             // SL = entry ± this × ATR
input double InpRRRatio           = 2.0;
input bool   InpUseTrailingTP     = true;
input double InpTrailActivateR    = 1.0;
input double InpTrailDistanceR    = 0.5;

input group "═══ Position Sizing ════════════════════════════"
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
input int    InpMaxTradesPerDay   = 3;

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 48;

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
#define EA_TAG    "SMINDS-BBS-V1"
#define GV_PREFIX "SMBBS1_"

CTrade      g_trade;
CSymbolInfo g_sym;

int g_h_bb       = INVALID_HANDLE;
int g_h_kc_ema   = INVALID_HANDLE;
int g_h_kc_atr   = INVALID_HANDLE;
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

// Squeeze state
bool     g_in_squeeze      = false;
int      g_squeeze_age     = 0;       // bars since squeeze started
bool     g_release_armed   = false;   // squeeze recently released, watching for breakout
int      g_release_age     = 0;       // bars since release

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
//| BB / KC reads                                                     |
//+------------------------------------------------------------------+
// iBands buffers: 0=middle, 1=upper, 2=lower
bool ReadBB(int shift, double &mid, double &up, double &low)
{
   if(!ReadBuf(g_h_bb, 0, shift, mid)) return false;
   if(!ReadBuf(g_h_bb, 1, shift, up))  return false;
   if(!ReadBuf(g_h_bb, 2, shift, low)) return false;
   return true;
}

// Keltner: EMA(period) ± mult × ATR(period)
bool ReadKC(int shift, double &mid, double &up, double &low)
{
   double ema = 0.0, atr = 0.0;
   if(!ReadBuf(g_h_kc_ema, 0, shift, ema)) return false;
   if(!ReadBuf(g_h_kc_atr, 0, shift, atr)) return false;
   mid = ema;
   up  = ema + InpKCMultiplier * atr;
   low = ema - InpKCMultiplier * atr;
   return true;
}

// True if BB are fully inside KC at given shift
bool IsSqueezeAt(int shift)
{
   double bbMid, bbUp, bbLow;
   double kcMid, kcUp, kcLow;
   if(!ReadBB(shift, bbMid, bbUp, bbLow)) return false;
   if(!ReadKC(shift, kcMid, kcUp, kcLow)) return false;
   return (bbUp < kcUp) && (bbLow > kcLow);
}

//+------------------------------------------------------------------+
//| HTF trend                                                         |
//+------------------------------------------------------------------+
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

bool OpenBreakout(int dir, double atr)
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

   g_h_bb      = iBands(_Symbol, g_tf, InpBBPeriod, 0, InpBBStdDev, PRICE_CLOSE);
   g_h_kc_ema  = iMA   (_Symbol, g_tf, InpKCPeriod,    0, MODE_EMA, PRICE_CLOSE);
   g_h_kc_atr  = iATR  (_Symbol, g_tf, InpKCATRPeriod);
   g_h_atr     = iATR  (_Symbol, g_tf, InpATRPeriod);
   g_h_htf_ema = iMA   (_Symbol, InpHTFPeriod, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_h_bb == INVALID_HANDLE || g_h_kc_ema == INVALID_HANDLE || g_h_kc_atr == INVALID_HANDLE ||
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
   g_in_squeeze      = false;
   g_squeeze_age     = 0;
   g_release_armed   = false;
   g_release_age     = 0;

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Symbol/TF=%s/%s  Magic=%lld", _Symbol, EnumToString(g_tf), InpMagicNumber));
   LogInfo(StringFormat("BB(%d,%.1f)  KC(EMA%d, ATR%d × %.1f)  MinSqueeze=%dbars EntryWindow=%dbars",
           InpBBPeriod, InpBBStdDev, InpKCPeriod, InpKCATRPeriod, InpKCMultiplier,
           InpMinSqueezeBars, InpEntryWindowBars));
   LogInfo(StringFormat("HTF=%s/EMA%d  R:R=%.1f  SL=ATRx%.1f  Risk=%.1f%%",
           EnumToString(InpHTFPeriod), InpHTFEMAPeriod, InpRRRatio, InpSLATRMult, InpRiskPercent));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
   if(g_h_bb       != INVALID_HANDLE) IndicatorRelease(g_h_bb);
   if(g_h_kc_ema   != INVALID_HANDLE) IndicatorRelease(g_h_kc_ema);
   if(g_h_kc_atr   != INVALID_HANDLE) IndicatorRelease(g_h_kc_atr);
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
      ApplyTrail(ticket);
      CheckTimeStop(ticket, opened);
      return;
   }
   if(g_open_ticket != 0)
   {
      RecordTradeResult(g_open_ticket);
      g_open_ticket = 0;
   }

   if(!new_bar) return;

   // ── Squeeze state machine (operates on closed bar shift 1) ──
   bool sq_now = IsSqueezeAt(1);
   if(sq_now)
   {
      if(!g_in_squeeze) { g_in_squeeze = true; g_squeeze_age = 1; }
      else g_squeeze_age++;
      g_release_armed = false;
   }
   else
   {
      // Just released?
      if(g_in_squeeze && g_squeeze_age >= InpMinSqueezeBars && g_squeeze_age <= InpMaxSqueezeBars)
      {
         g_release_armed = true;
         g_release_age   = 1;
         LogDebug(StringFormat("Squeeze released after %d bars — armed", g_squeeze_age));
      }
      else if(g_release_armed)
      {
         g_release_age++;
         if(g_release_age > InpEntryWindowBars)
         {
            g_release_armed = false;
            LogDebug("Entry window expired");
         }
      }
      g_in_squeeze = false;
      g_squeeze_age = 0;
   }

   if(!g_release_armed) return;

   // Risk gates
   if(!IsSessionAllowed())     { return; }
   if(IsDailyLossBreached())   { return; }
   if(IsCooldownActive())      { return; }
   if(IsLossBreakerActive())   { return; }
   if(IsDailyTradeLimitReached()){ return; }

   // ATR + HTF
   double atr = 0.0;
   if(!ReadBuf(g_h_atr, 0, 0, atr) || atr <= 0.0) return;
   int htf_dir = GetHTFTrend();
   if(InpUseHTFFilter && htf_dir == 0) return;

   // Check breakout: did bar 1 close beyond BB?
   double opens[], closes[];
   ArraySetAsSeries(opens, true); ArraySetAsSeries(closes, true);
   if(CopyOpen (_Symbol, g_tf, 0, 2, opens)  != 2) return;
   if(CopyClose(_Symbol, g_tf, 0, 2, closes) != 2) return;

   double bbMid, bbUp, bbLow;
   if(!ReadBB(1, bbMid, bbUp, bbLow)) return;

   int dir = 0;
   if(closes[1] > bbUp)      dir = +1;
   else if(closes[1] < bbLow) dir = -1;

   if(dir == 0) return;
   if(InpUseHTFFilter && dir != htf_dir) return;

   if(OpenBreakout(dir, atr))
   {
      // Entry consumed — disarm release
      g_release_armed = false;
   }
}
//+------------------------------------------------------------------+
