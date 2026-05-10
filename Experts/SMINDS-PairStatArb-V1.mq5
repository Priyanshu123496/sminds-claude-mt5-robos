//+------------------------------------------------------------------+
//|                                  SMINDS-PairStatArb-V1.mq5       |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  Strategy Factory — EA #11 (Pair Statistical Arbitrage)          |
//|                                                                  |
//|  Trades the SPREAD between two cointegrated symbols.             |
//|  When the log-spread z-score is extreme, expect reversion:       |
//|    z > +threshold  →  spread too high  → SHORT primary, LONG sec |
//|    z < -threshold  →  spread too low   → LONG primary, SHORT sec |
//|                                                                  |
//|  Both legs are opened simultaneously and closed together when:   |
//|    1. z-score returns within ±exit_z (mean reverted) — TP        |
//|    2. z-score moves further to ±stop_z (divergence) — SL         |
//|    3. Holding time > MaxHoldBars (time stop)                     |
//|                                                                  |
//|  Default pair: EURUSD (primary) ↔ GBPUSD (secondary).            |
//|  Both are USD-denominated, highly correlated, well-cointegrated  |
//|  in normal market regimes.                                        |
//|                                                                  |
//|  Strategy class: STATISTICAL ARBITRAGE / PAIR TRADING            |
//|  (genuinely uncorrelated with directional EAs — profits when     |
//|  the SPREAD moves regardless of underlying market direction)     |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property link      ""
#property version   "1.00"
#property description "SMINDS Pair Stat-Arb V1 — log-spread z-score mean reversion"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "═══ Identification ═════════════════════════════════"
input long   InpMagicNumber       = 97100001;
input string InpOrderComment      = "SMINDS-PSA-V1";

input group "═══ Symbol Pair ════════════════════════════════════"
input string InpSecondarySymbol   = "GBPUSD";        // Run on EURUSD by default

input group "═══ Spread / Z-Score ═══════════════════════════════"
input int    InpSpreadLookback    = 100;             // Longer lookback for stable mean
input double InpEntryZ            = 3.0;             // Only extreme deviations
input double InpExitZ             = 0.2;             // Tight reversion confirmation
input double InpStopZ             = 4.5;             // Wider stop

input group "═══ Position Sizing ═════════════════════════════"
input double InpLotPerLeg         = 0.10;            // Fixed lot on each leg

input group "═══ Position Management ════════════════════════"
input bool   InpUseTimeStop       = true;
input int    InpMaxHoldBars       = 100;             // Force-close if no resolution

input group "═══ Risk Circuit Breakers ════════════════════════"
input bool   InpUseDailyLossLimit = true;
input double InpMaxDailyLossPct   = 4.0;
input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 3;
input bool   InpUseCooldown       = true;
input int    InpCooldownBars      = 8;

input group "═══ Session Filter (UTC) ════════════════════════"
input bool   InpUseSession        = true;
input int    InpSessionStartHour  = 7;
input int    InpSessionEndHour    = 19;              // Avoid late illiquid hours (worse spreads)

input group "═══ Execution Safety ═════════════════════════════"
input int    InpMaxSpreadPoints   = 50;              // Per-leg max spread
input int    InpSlippagePoints    = 20;
input int    InpMaxRetries        = 3;
input int    InpRetryDelayMs      = 500;

input group "═══ Diagnostics ══════════════════════════════════"
input bool   InpVerbose           = false;

//+------------------------------------------------------------------+
//| Constants & state                                                 |
//+------------------------------------------------------------------+
#define EA_TAG    "SMINDS-PSA-V1"
#define GV_PREFIX "SMPSA1_"

CTrade      g_trade;
CSymbolInfo g_sym_pri;
CSymbolInfo g_sym_sec;

ENUM_TIMEFRAMES g_tf       = PERIOD_CURRENT;
datetime        g_last_bar = 0;
datetime        g_today    = 0;
double          g_daily_start_bal = 0.0;

bool     g_last_loss       = false;
int      g_bars_since_loss = 9999;
int      g_consec_losses   = 0;
datetime g_breaker_day     = 0;

// Pair trade state
enum PairState { PS_IDLE = 0, PS_LONG_PAIR = 1, PS_SHORT_PAIR = 2 };
PairState g_state          = PS_IDLE;
ulong     g_ticket_pri     = 0;        // primary leg ticket
ulong     g_ticket_sec     = 0;        // secondary leg ticket
double    g_entry_z        = 0.0;
datetime  g_entry_time     = 0;

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

datetime DayStart(datetime t) { return (datetime)((long)t / 86400 * 86400); }

double NormalizeVolFor(string symbol, double x)
{
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
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

bool FindPositionByTicket(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
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

bool IsSpreadOK(string symbol)
{
   if(InpMaxSpreadPoints <= 0) return true;
   long s = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   return s <= InpMaxSpreadPoints;
}

//+------------------------------------------------------------------+
//| Spread / z-score computation                                      |
//+------------------------------------------------------------------+
// Returns true if z-score computed; populates z_now and stats
bool ComputeZScore(double &z_now, double &spread_now, double &mean_out, double &std_out)
{
   double cl_pri[], cl_sec[];
   ArraySetAsSeries(cl_pri, true); ArraySetAsSeries(cl_sec, true);
   int need = InpSpreadLookback + 1;
   if(CopyClose(_Symbol,            g_tf, 0, need, cl_pri) != need) return false;
   if(CopyClose(InpSecondarySymbol, g_tf, 0, need, cl_sec) != need) return false;

   // Build log-spread series for last InpSpreadLookback bars (shift 1..lookback)
   // Use bar 1 as "now" so we trade on closed-bar data
   double spreads[];
   ArrayResize(spreads, InpSpreadLookback);
   for(int i = 0; i < InpSpreadLookback; i++)
   {
      int shift = i + 1;
      if(cl_pri[shift] <= 0.0 || cl_sec[shift] <= 0.0) return false;
      spreads[i] = MathLog(cl_pri[shift]) - MathLog(cl_sec[shift]);
   }

   // Mean & stddev of spreads
   double sum = 0.0;
   for(int i = 0; i < InpSpreadLookback; i++) sum += spreads[i];
   double mean = sum / InpSpreadLookback;

   double sum_sq = 0.0;
   for(int i = 0; i < InpSpreadLookback; i++)
   {
      double d = spreads[i] - mean;
      sum_sq += d * d;
   }
   double std = MathSqrt(sum_sq / InpSpreadLookback);
   if(std < 1e-10) return false;

   spread_now = spreads[0];      // most recent (bar 1) spread
   mean_out = mean;
   std_out  = std;
   z_now = (spread_now - mean) / std;
   return true;
}

//+------------------------------------------------------------------+
//| Position management                                               |
//+------------------------------------------------------------------+
// Opens a pair trade. dir=+1 LONG_PAIR (long primary, short secondary),
// dir=-1 SHORT_PAIR (short primary, long secondary)
bool OpenPair(int dir, double z_value)
{
   if(!IsSpreadOK(_Symbol))             { LogDebug("Skip: primary spread");   return false; }
   if(!IsSpreadOK(InpSecondarySymbol))  { LogDebug("Skip: secondary spread"); return false; }

   double vol_pri = NormalizeVolFor(_Symbol,            InpLotPerLeg);
   double vol_sec = NormalizeVolFor(InpSecondarySymbol, InpLotPerLeg);
   if(vol_pri <= 0 || vol_sec <= 0){ LogWarn("Lot calc failed"); return false; }

   bool pri_ok = false, sec_ok = false;

   if(dir > 0)
   {
      // LONG_PAIR: long primary, short secondary
      pri_ok = g_trade.Buy (vol_pri, _Symbol,            0.0, 0.0, 0.0, InpOrderComment + "-priL");
      if(pri_ok) g_ticket_pri = g_trade.ResultOrder();
      sec_ok = g_trade.Sell(vol_sec, InpSecondarySymbol, 0.0, 0.0, 0.0, InpOrderComment + "-secS");
      if(sec_ok) g_ticket_sec = g_trade.ResultOrder();
   }
   else
   {
      // SHORT_PAIR: short primary, long secondary
      pri_ok = g_trade.Sell(vol_pri, _Symbol,            0.0, 0.0, 0.0, InpOrderComment + "-priS");
      if(pri_ok) g_ticket_pri = g_trade.ResultOrder();
      sec_ok = g_trade.Buy (vol_sec, InpSecondarySymbol, 0.0, 0.0, 0.0, InpOrderComment + "-secL");
      if(sec_ok) g_ticket_sec = g_trade.ResultOrder();
   }

   if(!pri_ok || !sec_ok)
   {
      LogWarn(StringFormat("Pair-open failure pri=%s sec=%s — closing successful leg", pri_ok?"OK":"FAIL", sec_ok?"OK":"FAIL"));
      // If only one leg succeeded, close it immediately
      if(pri_ok && g_ticket_pri != 0) g_trade.PositionClose(g_ticket_pri);
      if(sec_ok && g_ticket_sec != 0) g_trade.PositionClose(g_ticket_sec);
      g_ticket_pri = 0; g_ticket_sec = 0;
      return false;
   }

   // Need to actually find the position tickets — ResultOrder returns the order ticket,
   // not the position ticket. Look them up by symbol+magic.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym == _Symbol)            g_ticket_pri = t;
      else if(sym == InpSecondarySymbol) g_ticket_sec = t;
   }

   g_state      = (dir > 0) ? PS_LONG_PAIR : PS_SHORT_PAIR;
   g_entry_z    = z_value;
   g_entry_time = TimeCurrent();
   LogInfo(StringFormat("OPEN %s pair: z=%.2f  vol=%.2f/%.2f  primary=%s  secondary=%s  tickets=%I64u/%I64u",
           dir > 0 ? "LONG" : "SHORT", z_value, vol_pri, vol_sec,
           _Symbol, InpSecondarySymbol, g_ticket_pri, g_ticket_sec));
   return true;
}

bool ClosePair(string reason, double z_now)
{
   bool any_closed = false;
   double total_pl = 0.0;

   if(g_ticket_pri != 0 && PositionSelectByTicket(g_ticket_pri))
   {
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(g_ticket_pri))
      {
         total_pl += pl;
         any_closed = true;
         LogDebug(StringFormat("Closed primary leg %I64u P/L=%.2f", g_ticket_pri, pl));
      }
   }
   if(g_ticket_sec != 0 && PositionSelectByTicket(g_ticket_sec))
   {
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_trade.PositionClose(g_ticket_sec))
      {
         total_pl += pl;
         any_closed = true;
         LogDebug(StringFormat("Closed secondary leg %I64u P/L=%.2f", g_ticket_sec, pl));
      }
   }

   if(any_closed)
   {
      LogInfo(StringFormat("CLOSE pair (%s): entryZ=%.2f exitZ=%.2f totalP/L=%.2f",
              reason, g_entry_z, z_now, total_pl));
      // Account loss/win
      if(total_pl < 0.0)
      {
         g_last_loss = true;
         g_bars_since_loss = 0;
         g_consec_losses++;
         if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
         {
            g_breaker_day = DayStart(TimeCurrent());
         }
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

   g_state = PS_IDLE;
   g_ticket_pri = 0;
   g_ticket_sec = 0;
   g_entry_z = 0.0;
   g_entry_time = 0;
   return any_closed;
}

// Verify legs are still open; if either was externally closed, close the other
bool VerifyLegs()
{
   bool pri_ok = (g_ticket_pri != 0) && PositionSelectByTicket(g_ticket_pri);
   bool sec_ok = (g_ticket_sec != 0) && PositionSelectByTicket(g_ticket_sec);
   if(g_state == PS_IDLE) return true;
   if(!pri_ok && !sec_ok)
   {
      // Both already gone (e.g., external SL fill on broker side)
      LogInfo("Both legs externally closed");
      g_state = PS_IDLE;
      g_ticket_pri = 0; g_ticket_sec = 0;
      return false;
   }
   if(!pri_ok || !sec_ok)
   {
      LogWarn(StringFormat("One leg gone (pri=%s sec=%s) — closing remaining",
              pri_ok ? "OK" : "GONE", sec_ok ? "OK" : "GONE"));
      // Close the other leg
      if(pri_ok) g_trade.PositionClose(g_ticket_pri);
      if(sec_ok) g_trade.PositionClose(g_ticket_sec);
      ClosePair("partial-leg-recovery", 0.0);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   // Validate primary symbol is available
   if(!g_sym_pri.Name(_Symbol)){ LogError("Primary CSymbolInfo init failed"); return INIT_FAILED; }
   if(!SymbolSelect(_Symbol, true)){ LogError("SymbolSelect primary failed"); return INIT_FAILED; }

   // Validate secondary symbol
   if(StringLen(InpSecondarySymbol) < 3 || InpSecondarySymbol == _Symbol)
   { LogError("Invalid InpSecondarySymbol"); return INIT_PARAMETERS_INCORRECT; }
   if(!g_sym_sec.Name(InpSecondarySymbol))
   { LogError(StringFormat("Secondary symbol '%s' init failed", InpSecondarySymbol)); return INIT_FAILED; }
   if(!SymbolSelect(InpSecondarySymbol, true))
   { LogError(StringFormat("Cannot select secondary '%s' in market watch", InpSecondarySymbol)); return INIT_FAILED; }

   if(InpSpreadLookback < 30){ LogError("Spread lookback too small"); return INIT_PARAMETERS_INCORRECT; }
   if(InpEntryZ <= InpExitZ || InpStopZ <= InpEntryZ)
   { LogError("Z thresholds must satisfy: ExitZ < EntryZ < StopZ"); return INIT_PARAMETERS_INCORRECT; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long acct = AccountInfoInteger(ACCOUNT_LOGIN);
   g_gv_consec  = StringFormat("%s%lld_%s_%s_consec",  GV_PREFIX, acct, _Symbol, InpSecondarySymbol);
   g_gv_breaker = StringFormat("%s%lld_%s_%s_breaker", GV_PREFIX, acct, _Symbol, InpSecondarySymbol);
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
   g_state           = PS_IDLE;
   g_ticket_pri      = 0;
   g_ticket_sec      = 0;

   LogInfo("─────── INIT ───────");
   LogInfo(StringFormat("Pair: %s (primary) <-> %s (secondary)  TF=%s",
           _Symbol, InpSecondarySymbol, EnumToString(g_tf)));
   LogInfo(StringFormat("Spread lookback=%d  Entry|z|>=%.2f  Exit|z|<=%.2f  Stop|z|>=%.2f",
           InpSpreadLookback, InpEntryZ, InpExitZ, InpStopZ));
   LogInfo(StringFormat("Lot/leg=%.2f  Session=%02d-%02d UTC  TimeStop=%dbars",
           InpLotPerLeg, InpSessionStartHour, InpSessionEndHour, InpMaxHoldBars));
   LogInfo("────────────────────");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   StateSave();
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   bool new_bar = IsNewBar();
   if(new_bar && g_last_loss && g_bars_since_loss < 9999) g_bars_since_loss++;

   // ── Compute current spread/z ──
   double z, spread, mean, std;
   if(!ComputeZScore(z, spread, mean, std)) return;

   // ── If we hold a pair, check for exit ──
   if(g_state != PS_IDLE)
   {
      if(!VerifyLegs()) return;     // legs missing — already cleaned up

      // TP: z reverted close to mean
      if(MathAbs(z) < InpExitZ)
      {
         ClosePair("z-reverted-to-mean", z);
         return;
      }

      // SL: z continues to diverge
      if((g_state == PS_LONG_PAIR && z < -InpStopZ) ||
         (g_state == PS_SHORT_PAIR && z > InpStopZ))
      {
         ClosePair("stop-z-divergence", z);
         return;
      }

      // Time stop
      if(InpUseTimeStop && new_bar && g_entry_time != 0)
      {
         long held_sec = (long)(TimeCurrent() - g_entry_time);
         long bars_held = held_sec / PeriodSeconds(g_tf);
         if(bars_held >= InpMaxHoldBars)
         {
            ClosePair("time-stop", z);
            return;
         }
      }
      return;   // still in the trade, no entry logic
   }

   // ── No active pair: look for entry ──
   if(!new_bar) return;

   if(!IsSessionAllowed())   return;
   if(IsDailyLossBreached()) return;
   if(IsCooldownActive())    return;
   if(IsLossBreakerActive()) return;

   if(z <= -InpEntryZ)
   {
      // Spread too LOW (primary cheap relative to secondary)
      // → expect spread to rise → LONG primary, SHORT secondary
      LogInfo(StringFormat("Entry signal LONG_PAIR  z=%.2f  spread=%.6f  mean=%.6f  std=%.6f",
              z, spread, mean, std));
      OpenPair(+1, z);
   }
   else if(z >= InpEntryZ)
   {
      // Spread too HIGH (primary rich relative to secondary)
      // → expect spread to fall → SHORT primary, LONG secondary
      LogInfo(StringFormat("Entry signal SHORT_PAIR z=%.2f  spread=%.6f  mean=%.6f  std=%.6f",
              z, spread, mean, std));
      OpenPair(-1, z);
   }
}
//+------------------------------------------------------------------+
