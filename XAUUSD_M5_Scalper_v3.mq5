//+------------------------------------------------------------------+
//|                                        XAUUSD_M5_Scalper_v3.mq5 |
//|                                  Copyright 2026, Manus AI Agent |
//|                                             https://manus.im    |
//|   Created: 05.03.2026 (Zagreb)                                  |
//|   Fixed: 05.03.2026 (Zagreb) - CLAUDE.md standard compliance    |
//|   - SL ODMAH pri otvaranju                                       |
//|   - 3-target partial close system                                |
//|   - 2-level trailing (BE + profit lock)                          |
//|   - Stealth TP (ne salje brokeru)                                |
//|   - Weekend filter                                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Manus AI Agent"
#property link      "https://manus.im"
#property version   "3.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//--- Keltner Channel Settings
input group "Keltner Channel Settings"
input int      InpKeltnerPeriod     = 20;       // Keltner Period (EMA)
input double   InpKeltnerMultiplier = 1.5;      // Keltner ATR Multiplier
input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_M5;// Trading Timeframe

//--- Trend Filters
input group "Trend Filters"
input int      InpM5_EMA_Period     = 200;      // M5 EMA Period
input int      InpH1_EMA_Period     = 50;       // H1 EMA Period
input ENUM_TIMEFRAMES InpH1_TF      = PERIOD_H1;// Higher Timeframe

//--- Risk Management
input group "Risk Management"
input double   InpLots              = 0.01;     // Fixed Lot Size
input int      InpStopLossPips      = 800;      // Fixed Stop Loss (Pips)
input int      InpMaxSpread         = 30;       // Max Spread (Points)
input long     InpMagicNum          = 556688;   // Magic Number (UNIQUE)

//--- Targets (Stealth TP)
input group "Targets (Pips) - Stealth TP"
input int      InpTarget1_Pips      = 200;      // Target 1 - close 33%
input int      InpTarget2_Pips      = 350;      // Target 2 - close 50% remaining
input int      InpTarget3_Pips      = 600;      // Target 3 - close all

//--- 2-Level Trailing
input group "2-Level Trailing (Pips)"
input int      InpTrailingStart1    = 500;      // L1: Pips for BE move
input int      InpBE_LockMin        = 38;       // L1: BE + min pips
input int      InpBE_LockMax        = 43;       // L1: BE + max pips
input int      InpTrailingStart2    = 800;      // L2: Pips for profit lock
input int      InpProfitLockMin     = 150;      // L2: Lock min pips
input int      InpProfitLockMax     = 200;      // L2: Lock max pips

//--- Trading Hours (GMT)
input group "Trading Hours (GMT)"
input bool     InpUseTradingHours   = true;     // Enable Trading Hours
input int      InpStartHour         = 8;        // Start Hour (GMT)
input int      InpEndHour           = 21;       // End Hour (GMT)

//--- Global variables
int      handle_ema_m5;
int      handle_ema_h1;
int      handle_atr;
int      handle_ema_keltner;
double   g_pipValue;
int      g_digits;

//--- Partial close tracking
struct PartialTrack {
   ulong    ticket;
   bool     t1_closed;
   bool     t2_closed;
   double   originalLot;
   double   entryPrice;
   int      direction;     // +1 buy, -1 sell
   int      trailLevel;    // 0=none, 1=BE, 2=lock
   int      randomBE;      // Random BE offset
   int      randomL2;      // Random L2 lock
};
PartialTrack g_partials[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize indicator handles
   handle_ema_m5 = iMA(_Symbol, InpTimeframe, InpM5_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handle_ema_h1 = iMA(_Symbol, InpH1_TF, InpH1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handle_atr    = iATR(_Symbol, InpTimeframe, 14);
   handle_ema_keltner = iMA(_Symbol, InpTimeframe, InpKeltnerPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handle_ema_m5 == INVALID_HANDLE || handle_ema_h1 == INVALID_HANDLE ||
      handle_atr == INVALID_HANDLE || handle_ema_keltner == INVALID_HANDLE)
   {
      Print("[SCALPER V3] Error initializing indicators");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(50);

   g_pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   Print("[SCALPER V3] ══════════════════════════════════════");
   Print("[SCALPER V3] Inicijalizacija uspjesna");
   Print("[SCALPER V3] Symbol: ", _Symbol, " | Pip: ", g_pipValue);
   Print("[SCALPER V3] SL: ", InpStopLossPips, " pips ODMAH");
   Print("[SCALPER V3] Targets: ", InpTarget1_Pips, "/", InpTarget2_Pips, "/", InpTarget3_Pips, " pips (stealth)");
   Print("[SCALPER V3] Trail L1: BE+", InpBE_LockMin, "-", InpBE_LockMax, " @ ", InpTrailingStart1, " pips");
   Print("[SCALPER V3] Trail L2: Lock ", InpProfitLockMin, "-", InpProfitLockMax, " @ ", InpTrailingStart2, " pips");
   Print("[SCALPER V3] ══════════════════════════════════════");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handle_ema_m5);
   IndicatorRelease(handle_ema_h1);
   IndicatorRelease(handle_atr);
   IndicatorRelease(handle_ema_keltner);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Manage existing positions (Stealth TP + 2-Level Trailing)
   ManagePositions();

   //--- 2. Check for new bar
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, InpTimeframe, 0);
   if(last_bar_time == current_bar_time) return;
   last_bar_time = current_bar_time;

   //--- 3. Weekend filter (Friday >= 11:30 GMT)
   MqlDateTime dt;
   TimeGMT(dt);
   if(IsWeekendBlocked(dt)) return;

   //--- 4. Trading Hours
   if(InpUseTradingHours)
   {
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;
   }

   //--- 5. Spread check
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   //--- 6. Get Indicator Values (Previous Bar)
   double ema_m5[1], ema_h1[1], atr[1], ema_k[1];
   if(CopyBuffer(handle_ema_m5, 0, 1, 1, ema_m5) < 1) return;
   if(CopyBuffer(handle_ema_h1, 0, 1, 1, ema_h1) < 1) return;
   if(CopyBuffer(handle_atr, 0, 1, 1, atr) < 1) return;
   if(CopyBuffer(handle_ema_keltner, 0, 1, 1, ema_k) < 1) return;

   double upper_band = ema_k[0] + (InpKeltnerMultiplier * atr[0]);
   double lower_band = ema_k[0] - (InpKeltnerMultiplier * atr[0]);
   double close_prev = iClose(_Symbol, InpTimeframe, 1);
   double low_prev   = iLow(_Symbol, InpTimeframe, 1);
   double high_prev  = iHigh(_Symbol, InpTimeframe, 1);
   double close_h1   = iClose(_Symbol, InpH1_TF, 1);

   //--- 7. BUY Signal
   if(close_h1 > ema_h1[0] && close_prev > ema_m5[0])
   {
      if(low_prev <= lower_band && close_prev > lower_band)
      {
         if(!HasPosition(POSITION_TYPE_BUY))
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = NormalizeDouble(ask - (InpStopLossPips * g_pipValue), g_digits);

            // SL ODMAH - no TP (stealth)
            if(trade.Buy(InpLots, _Symbol, ask, sl, 0, "SCALPER_BUY"))
            {
               ulong ticket = trade.ResultOrder();
               Print("[SCALPER V3] BUY @ ", ask, " | SL: ", sl, " (ODMAH!)");
               AddPartialTrack(ticket, InpLots, ask, +1);
            }
         }
      }
   }

   //--- 8. SELL Signal
   if(close_h1 < ema_h1[0] && close_prev < ema_m5[0])
   {
      if(high_prev >= upper_band && close_prev < upper_band)
      {
         if(!HasPosition(POSITION_TYPE_SELL))
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl = NormalizeDouble(bid + (InpStopLossPips * g_pipValue), g_digits);

            // SL ODMAH - no TP (stealth)
            if(trade.Sell(InpLots, _Symbol, bid, sl, 0, "SCALPER_SELL"))
            {
               ulong ticket = trade.ResultOrder();
               Print("[SCALPER V3] SELL @ ", bid, " | SL: ", sl, " (ODMAH!)");
               AddPartialTrack(ticket, InpLots, bid, -1);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage positions: Stealth TP + 2-Level Trailing                  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagicNum) continue;

      ulong  ticket = pos.Ticket();
      double open   = pos.PriceOpen();
      double curSL  = pos.StopLoss();
      double curTP  = pos.TakeProfit();
      double curLot = pos.Volume();

      int pIdx = FindPartialTrack(ticket);

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitPips = (bid - open) / g_pipValue;

         //--- STEALTH TP: Target 1 (33%)
         if(pIdx >= 0 && !g_partials[pIdx].t1_closed && profitPips >= InpTarget1_Pips)
         {
            double closeLot = NormalizeDouble(g_partials[pIdx].originalLot * 0.33, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t1_closed = true;
               Print("[SCALPER V3] TARGET 1 (33%) @ ", bid, " | +", (int)profitPips, " pips");
            }
         }

         //--- STEALTH TP: Target 2 (50% remaining)
         if(pIdx >= 0 && g_partials[pIdx].t1_closed && !g_partials[pIdx].t2_closed && profitPips >= InpTarget2_Pips)
         {
            double closeLot = NormalizeDouble(curLot * 0.5, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t2_closed = true;
               Print("[SCALPER V3] TARGET 2 (50%) @ ", bid, " | +", (int)profitPips, " pips");
            }
         }

         //--- STEALTH TP: Target 3 (close all)
         if(profitPips >= InpTarget3_Pips)
         {
            if(trade.PositionClose(ticket))
            {
               Print("[SCALPER V3] TARGET 3 (100%) @ ", bid, " | +", (int)profitPips, " pips");
               RemovePartialTrack(ticket);
            }
            continue;
         }

         //--- 2-LEVEL TRAILING
         // L2: Lock 150-200 pips @ 800 pips profit
         if(pIdx >= 0 && g_partials[pIdx].trailLevel == 1 && profitPips >= InpTrailingStart2)
         {
            double newSL = NormalizeDouble(open + g_partials[pIdx].randomL2 * g_pipValue, g_digits);
            if(newSL > curSL)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 2;
                  Print("[SCALPER V3] L2: Lock +", g_partials[pIdx].randomL2, " pips @ ", newSL);
               }
            }
         }
         // L1: BE + 38-43 pips @ 500 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 0 && profitPips >= InpTrailingStart1)
         {
            double newSL = NormalizeDouble(open + g_partials[pIdx].randomBE * g_pipValue, g_digits);
            if(newSL > curSL)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 1;
                  Print("[SCALPER V3] L1: BE+", g_partials[pIdx].randomBE, " pips @ ", newSL);
               }
            }
         }
      }
      else if(pos.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPips = (open - ask) / g_pipValue;

         //--- STEALTH TP: Target 1 (33%)
         if(pIdx >= 0 && !g_partials[pIdx].t1_closed && profitPips >= InpTarget1_Pips)
         {
            double closeLot = NormalizeDouble(g_partials[pIdx].originalLot * 0.33, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t1_closed = true;
               Print("[SCALPER V3] TARGET 1 (33%) @ ", ask, " | +", (int)profitPips, " pips");
            }
         }

         //--- STEALTH TP: Target 2 (50% remaining)
         if(pIdx >= 0 && g_partials[pIdx].t1_closed && !g_partials[pIdx].t2_closed && profitPips >= InpTarget2_Pips)
         {
            double closeLot = NormalizeDouble(curLot * 0.5, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t2_closed = true;
               Print("[SCALPER V3] TARGET 2 (50%) @ ", ask, " | +", (int)profitPips, " pips");
            }
         }

         //--- STEALTH TP: Target 3 (close all)
         if(profitPips >= InpTarget3_Pips)
         {
            if(trade.PositionClose(ticket))
            {
               Print("[SCALPER V3] TARGET 3 (100%) @ ", ask, " | +", (int)profitPips, " pips");
               RemovePartialTrack(ticket);
            }
            continue;
         }

         //--- 2-LEVEL TRAILING
         // L2: Lock 150-200 pips @ 800 pips profit
         if(pIdx >= 0 && g_partials[pIdx].trailLevel == 1 && profitPips >= InpTrailingStart2)
         {
            double newSL = NormalizeDouble(open - g_partials[pIdx].randomL2 * g_pipValue, g_digits);
            if(newSL < curSL || curSL == 0)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 2;
                  Print("[SCALPER V3] L2: Lock +", g_partials[pIdx].randomL2, " pips @ ", newSL);
               }
            }
         }
         // L1: BE + 38-43 pips @ 500 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 0 && profitPips >= InpTrailingStart1)
         {
            double newSL = NormalizeDouble(open - g_partials[pIdx].randomBE * g_pipValue, g_digits);
            if(newSL < curSL || curSL == 0)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 1;
                  Print("[SCALPER V3] L1: BE+", g_partials[pIdx].randomBE, " pips @ ", newSL);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Partial tracking helpers                                         |
//+------------------------------------------------------------------+
void AddPartialTrack(ulong ticket, double lot, double entry, int dir)
{
   int size = ArraySize(g_partials);
   ArrayResize(g_partials, size + 1);

   g_partials[size].ticket      = ticket;
   g_partials[size].t1_closed   = false;
   g_partials[size].t2_closed   = false;
   g_partials[size].originalLot = lot;
   g_partials[size].entryPrice  = entry;
   g_partials[size].direction   = dir;
   g_partials[size].trailLevel  = 0;
   g_partials[size].randomBE    = InpBE_LockMin + MathRand() % (InpBE_LockMax - InpBE_LockMin + 1);
   g_partials[size].randomL2    = InpProfitLockMin + MathRand() % (InpProfitLockMax - InpProfitLockMin + 1);
}

int FindPartialTrack(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_partials); i++)
   {
      if(g_partials[i].ticket == ticket) return i;
   }
   return -1;
}

void RemovePartialTrack(ulong ticket)
{
   int idx = FindPartialTrack(ticket);
   if(idx < 0) return;

   int last = ArraySize(g_partials) - 1;
   if(idx != last) g_partials[idx] = g_partials[last];
   ArrayResize(g_partials, last);
}

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
bool HasPosition(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i))
      {
         if(pos.Symbol() == _Symbol && pos.Magic() == InpMagicNum && pos.PositionType() == type)
            return true;
      }
   }
   return false;
}

bool IsWeekendBlocked(MqlDateTime &dt)
{
   int dow  = dt.day_of_week;
   int hour = dt.hour;
   int min  = dt.min;

   // Friday >= 11:30 GMT
   if(dow == 5 && (hour > 11 || (hour == 11 && min >= 30))) return true;
   // Saturday
   if(dow == 6) return true;
   // Sunday before 00:01
   if(dow == 0 && hour < 1) return true;

   return false;
}
//+------------------------------------------------------------------+
