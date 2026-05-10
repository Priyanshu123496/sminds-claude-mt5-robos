//+------------------------------------------------------------------+
//|                                  SMINDS-News-Event-V1.mq5        |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  News-Event Volatility Breakout EA.                              |
//|                                                                  |
//|  Strategy: trade momentum bars during known high-impact news     |
//|    event windows (±4 hours around scheduled event times).        |
//|    Volatility expansion is empirically reliable around scheduled |
//|    events (FOMC, NFP, CPI). EA fires when a candle body ≥        |
//|    threshold ATR confirms direction.                             |
//|                                                                  |
//|  Setup:                                                          |
//|    1. TimeCurrent within event window [-30 min, +4 hours]        |
//|    2. Bar[1] body ≥ 1.0 × ATR                                    |
//|    3. Bar[1] close in upper 40% (long) or lower 40% (short)      |
//|    4. ATR not extreme (< 2.5 × baseline)                         |
//|                                                                  |
//|  Stops/targets:                                                  |
//|    SL = candle opposite extreme ∓ 0.5 × ATR                      |
//|    TP = entry ± 2.0 × ATR                                        |
//|    Time-stop: close all event-related positions after event+8h   |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS News-Event V1 — volatility breakout on scheduled events"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input long   InpMagicNumber       = 94736360;
input string InpOrderComment      = "NWE-V1";

input bool   InpRequireXAUUSD     = false;           // Tradable on XAU or EURUSD
input bool   InpRequireH1         = true;            // H1 timeframe

input int    InpATRPeriod         = 14;
input int    InpATRBaselinePeriod = 50;

input double InpMinBodyATR        = 1.0;             // Bar body must be ≥ this × ATR
input double InpMaxATRRatio       = 2.5;             // Reject if ATR > baseline × this
input double InpCloseInUpperFrac  = 0.60;            // Long: bar close in upper (1-frac) of range; default upper 40%

input int    InpEventLeadMin      = 30;              // Minutes BEFORE event we open the window
input int    InpEventLagHours     = 4;               // Hours AFTER event we keep window open
input int    InpMaxHoldHours      = 8;               // Force close after this many hours

input double InpSLBufferATR       = 0.5;
input double InpTPATRMultiplier   = 2.0;

input double InpLotSize           = 0.10;
input double InpMinLotSize        = 0.01;
input double InpMaxLotSize        = 1.00;

input int    InpMaxSpreadPoints   = 80;              // Wider tolerance for news periods
input int    InpSlippagePoints    = 50;
input int    InpMaxRetries        = 3;

#define EA_TAG "NWE-V1"

CTrade        g_trade;
CSymbolInfo   g_sym;
int  g_h_atr     = INVALID_HANDLE;
int  g_h_atr_base = INVALID_HANDLE;
ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;
datetime g_last_bar = 0;
datetime g_open_position_time = 0;
ulong    g_open_position_ticket = 0;
datetime g_last_event_traded = 0;

// ── Hardcoded major event times (UTC) for Jan-May 2026 ──────
// FOMC, NFP, CPI — major USD impact events
// Format: yyyy.MM.dd HH:mm (string parsed at init)
string g_event_strings[] = {
   // NFP (first Friday of each month, 12:30 UTC)
   "2026.01.02 13:30",
   "2026.02.06 13:30",
   "2026.03.06 13:30",
   "2026.04.03 12:30",  // April after DST
   "2026.05.01 12:30",
   // CPI (mid-month, 12:30 UTC)
   "2026.01.14 13:30",
   "2026.02.11 13:30",
   "2026.03.11 12:30",
   "2026.04.08 12:30",
   "2026.05.13 12:30",
   // FOMC (rate decisions, 18:00 UTC)
   "2026.01.28 19:00",
   "2026.03.18 18:00",
   "2026.05.06 18:00"
};
datetime g_event_times[];

void LogInfo(string msg)  { PrintFormat("[%s] %s", EA_TAG, msg); }
void LogError(string msg) { PrintFormat("[%s] ERROR: %s", EA_TAG, msg); }

double Get1(int handle, int shift)
{
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
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

bool IsInEventWindow(datetime t, datetime &active_event_out)
{
   for(int i = 0; i < ArraySize(g_event_times); i++)
   {
      datetime ev = g_event_times[i];
      datetime win_start = ev - InpEventLeadMin * 60;
      datetime win_end   = ev + InpEventLagHours * 3600;
      if(t >= win_start && t <= win_end)
      {
         active_event_out = ev;
         return true;
      }
   }
   return false;
}

void OpenPosition(bool is_long, double sl, double tp)
{
   double lot = NormalizeLot(InpLotSize);
   double stops_lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt = g_sym.Point();
   double min_dist = stops_lvl * pt;

   if(is_long)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask - sl < min_dist) sl = ask - min_dist - pt;
      if(tp - ask < min_dist) tp = ask + min_dist + pt;
      for(int r = 0; r < InpMaxRetries; r++)
         if(g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpOrderComment)) {
            LogInfo(StringFormat("BUY %.2f @ %.5f SL=%.5f TP=%.5f", lot, ask, sl, tp));
            return;
         }
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(sl - bid < min_dist) sl = bid + min_dist + pt;
      if(bid - tp < min_dist) tp = bid - min_dist - pt;
      for(int r = 0; r < InpMaxRetries; r++)
         if(g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpOrderComment)) {
            LogInfo(StringFormat("SELL %.2f @ %.5f SL=%.5f TP=%.5f", lot, bid, sl, tp));
            return;
         }
   }
}

int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   if(InpRequireH1 && g_tf != PERIOD_H1)
   { LogError("TF must be H1"); return INIT_FAILED; }
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;

   g_h_atr      = iATR(_Symbol, g_tf, InpATRPeriod);
   g_h_atr_base = iATR(_Symbol, g_tf, InpATRBaselinePeriod);
   if(g_h_atr == INVALID_HANDLE || g_h_atr_base == INVALID_HANDLE)
      return INIT_FAILED;

   // Parse event strings
   ArrayResize(g_event_times, ArraySize(g_event_strings));
   for(int i = 0; i < ArraySize(g_event_strings); i++)
   {
      g_event_times[i] = StringToTime(g_event_strings[i]);
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   LogInfo("─────────── INIT ───────────");
   LogInfo(StringFormat("Strategy : News-event vol breakout (%d events loaded)", ArraySize(g_event_times)));
   LogInfo(StringFormat("Window   : -%d min to +%d hours around event", InpEventLeadMin, InpEventLagHours));
   LogInfo(StringFormat("Trigger  : Body ≥ %.1fATR + close in upper/lower %.0f%%", InpMinBodyATR, (1.0-InpCloseInUpperFrac)*100));
   LogInfo(StringFormat("SL/TP    : SL=cand±%.1fATR  TP=%.1fATR", InpSLBufferATR, InpTPATRMultiplier));
   LogInfo("────────────────────────────");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_atr_base != INVALID_HANDLE) IndicatorRelease(g_h_atr_base);
}

void ManagePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
   if((TimeCurrent() - open_time) > InpMaxHoldHours * 3600)
   {
      g_trade.PositionClose(ticket, InpSlippagePoints);
      LogInfo(StringFormat("Time-stop close after %d hours", InpMaxHoldHours));
   }
}

void TryEntry()
{
   datetime cur = TimeCurrent();
   datetime active_event = 0;
   if(!IsInEventWindow(cur, active_event)) return;
   if(g_last_event_traded == active_event) return;  // already traded this event

   double atr = Get1(g_h_atr, 1);
   double atr_base = Get1(g_h_atr_base, 1);
   if(atr <= 0 || atr_base <= 0) return;
   if(atr / atr_base > InpMaxATRRatio) return;

   double o = iOpen(_Symbol, g_tf, 1);
   double h = iHigh(_Symbol, g_tf, 1);
   double l = iLow(_Symbol, g_tf, 1);
   double c = iClose(_Symbol, g_tf, 1);
   double rng = h - l;
   if(rng <= 0) return;
   double body = MathAbs(c - o);

   if(body < InpMinBodyATR * atr) return;

   bool bullish_break = (c > o) && (c >= l + rng * InpCloseInUpperFrac);
   bool bearish_break = (c < o) && (c <= l + rng * (1.0 - InpCloseInUpperFrac));

   if(bullish_break)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = l - InpSLBufferATR * atr;
      double tp = ask + InpTPATRMultiplier * atr;
      OpenPosition(true, sl, tp);
      g_open_position_time = TimeCurrent();
      g_last_event_traded = active_event;
   }
   else if(bearish_break)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = h + InpSLBufferATR * atr;
      double tp = bid - InpTPATRMultiplier * atr;
      OpenPosition(false, sl, tp);
      g_open_position_time = TimeCurrent();
      g_last_event_traded = active_event;
   }
}

void OnTick()
{
   datetime cur_bar = iTime(_Symbol, g_tf, 0);
   if(cur_bar == 0) return;
   bool new_bar = (cur_bar != g_last_bar);
   if(new_bar) g_last_bar = cur_bar;

   ulong cur_ticket;
   if(HaveOurPosition(cur_ticket))
   {
      g_open_position_ticket = cur_ticket;
      if(new_bar) ManagePosition(cur_ticket);
      return;
   }

   if(!new_bar) return;

   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints > 0 && spr > InpMaxSpreadPoints) return;

   TryEntry();
}
//+------------------------------------------------------------------+
