//+------------------------------------------------------------------+
//|                                  SMINDS-Gold-Scalper-V1.mq5      |
//|                                       Sminds Global Inc. (c)2026 |
//|                                                                  |
//|  EMPIRICAL TEST: "small profits many trades @ 2:1 RR"            |
//|  on XAUUSD M5. Used to demonstrate why this approach fails       |
//|  on retail XAU vs the medium-frequency TTR-XI-V12 approach.      |
//|                                                                  |
//|  Strategy: EMA5/EMA13 cross with EMA50 trend filter              |
//|    SL: 1.0 × ATR(14)                                             |
//|    TP: 2.0 × ATR(14)                                             |
//|    No quality filters — fires on every cross (high frequency)    |
//|                                                                  |
//|  Risk infrastructure: minimal — only spread guard + breaker.     |
//|  Goal is to expose raw cost-of-friction effect, not optimize.    |
//+------------------------------------------------------------------+
#property copyright "Sminds Global Inc."
#property version   "1.00"
#property description "SMINDS Gold-Scalper V1 — empirical scalping test"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>

input long   InpMagicNumber       = 94736340;
input string InpOrderComment      = "GSC-V1";

input bool   InpRequireXAUUSD     = true;
input bool   InpRequireM5         = true;

input int    InpEMAFastPeriod     = 5;
input int    InpEMASlowPeriod     = 13;
input int    InpEMAFilterPeriod   = 50;
input int    InpATRPeriod         = 14;

input double InpSLATRMultiplier   = 1.0;             // 1×ATR SL
input double InpTPATRMultiplier   = 2.0;             // 2×ATR TP — exact 2:1 RR

input double InpLotSize           = 0.10;
input double InpMinLotSize        = 0.01;
input double InpMaxLotSize        = 1.00;

input int    InpSessionStartHour  = 7;
input int    InpSessionEndHour    = 20;
input int    InpMaxSpreadPoints   = 50;
input int    InpSlippagePoints    = 30;

input bool   InpUseLossBreaker    = true;
input int    InpMaxConsecLosses   = 4;               // higher tolerance for scalper

#define EA_TAG "GSC-V1"

CTrade        g_trade;
CSymbolInfo   g_sym;

int  g_h_ema_fast    = INVALID_HANDLE;
int  g_h_ema_slow    = INVALID_HANDLE;
int  g_h_ema_filter  = INVALID_HANDLE;
int  g_h_atr         = INVALID_HANDLE;

ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;
datetime g_last_bar = 0;
int g_consec_losses = 0;
datetime g_breaker_day = 0;
datetime g_open_position_time = 0;
ulong g_open_position_ticket = 0;

double Get1(int handle, int shift)
{
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
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

bool BreakerOK()
{
   if(!InpUseLossBreaker) return true;
   datetime today = (datetime)((long)TimeCurrent() / 86400 * 86400);
   return g_breaker_day != today;
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

void OpenPosition(bool is_long, double sl, double tp)
{
   double lot = NormalizeLot(InpLotSize);
   if(is_long)
      g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpOrderComment);
   else
      g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpOrderComment);
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
         if(InpUseLossBreaker && g_consec_losses >= InpMaxConsecLosses)
            g_breaker_day = (datetime)((long)TimeCurrent() / 86400 * 86400);
      }
      else g_consec_losses = 0;
      g_open_position_time = 0;
      g_open_position_ticket = 0;
      break;
   }
}

int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;
   string up = _Symbol; StringToUpper(up);
   if(InpRequireXAUUSD && StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
   { Print("[GSC-V1] Symbol must be XAU/Gold"); return INIT_FAILED; }
   if(InpRequireM5 && g_tf != PERIOD_M5)
   { Print("[GSC-V1] Timeframe must be M5"); return INIT_FAILED; }
   if(!g_sym.Name(_Symbol)) return INIT_FAILED;
   if(!SymbolSelect(_Symbol, true)) return INIT_FAILED;

   g_h_ema_fast    = iMA(_Symbol, g_tf, InpEMAFastPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_slow    = iMA(_Symbol, g_tf, InpEMASlowPeriod,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ema_filter  = iMA(_Symbol, g_tf, InpEMAFilterPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_atr         = iATR(_Symbol, g_tf, InpATRPeriod);
   if(g_h_ema_fast == INVALID_HANDLE || g_h_ema_slow == INVALID_HANDLE ||
      g_h_ema_filter == INVALID_HANDLE || g_h_atr == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   PrintFormat("[%s] INIT %s/%s SL=%.1fATR TP=%.1fATR (2:1 RR)",
               EA_TAG, _Symbol, EnumToString(g_tf),
               InpSLATRMultiplier, InpTPATRMultiplier);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   int handles[] = { g_h_ema_fast, g_h_ema_slow, g_h_ema_filter, g_h_atr };
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
}

void TryEntry()
{
   double atr = Get1(g_h_atr, 1);
   if(atr <= 0) return;

   double f1 = Get1(g_h_ema_fast, 1);
   double f2 = Get1(g_h_ema_fast, 2);
   double s1 = Get1(g_h_ema_slow, 1);
   double s2 = Get1(g_h_ema_slow, 2);
   double e  = Get1(g_h_ema_filter, 1);
   if(f1 <= 0 || f2 <= 0 || s1 <= 0 || s2 <= 0 || e <= 0) return;

   double c1 = iClose(_Symbol, g_tf, 1);

   bool bull_cross = (f2 <= s2 && f1 > s1);
   bool bear_cross = (f2 >= s2 && f1 < s1);

   if(bull_cross && c1 > e)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - InpSLATRMultiplier * atr;
      double tp = ask + InpTPATRMultiplier * atr;
      OpenPosition(true, sl, tp);
      g_open_position_time = TimeCurrent();
   }
   else if(bear_cross && c1 < e)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + InpSLATRMultiplier * atr;
      double tp = bid - InpTPATRMultiplier * atr;
      OpenPosition(false, sl, tp);
      g_open_position_time = TimeCurrent();
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
      return;
   }
   else if(g_open_position_ticket != 0)
   {
      CheckLastClosedTradePnL();
   }

   if(!new_bar) return;
   if(!BreakerOK()) return;
   if(!InSession(cur_bar)) return;
   if(!SpreadOK()) return;

   TryEntry();
}
//+------------------------------------------------------------------+
