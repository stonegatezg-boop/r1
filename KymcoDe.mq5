//+------------------------------------------------------------------+
//|                                                   KymcoDe.mq5    |
//|   Deepco Core + Kymco Discipline (Production EA)                 |
//|   + Stealth Mode v2.0                                            |
//|                                                                  |
//|   Created:  2026-02-18 22:00 (server time)                        |
//|   Stealth:  2026-02-20 01:00 (server time)                        |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property copyright "KymcoDe"
//--- includes
#include <Trade/Trade.mqh>
//+------------------------------------------------------------------+
//| STEALTH KONFIGURACIJA                                            |
//| MT5 vrijeme = User vrijeme + 1h                                  |
//| User: Ned 00:01 - Pet 11:30 = MT5: Ned 01:01 - Pet 12:30        |
//| Blackout User: 14:30-15:30 = MT5: 15:30-16:30                   |
//+------------------------------------------------------------------+

//--- inputs
input group "=== TRADE POSTAVKE ==="
input double RiskPercent        = 0.5;     // Risk per trade %
input int    ATRperiod          = 20;
input int    ATRmaPeriod        = 100;
input int    DonchianPeriod     = 20;
input int    BBperiod           = 20;
input double BBdev              = 2.0;
input int    CooldownBars       = 5;
input int    MaxSpread          = 40;
input int    MagicNumber        = 9022026;
input double MaxDailyDD         = 3.0;     // %

input group "=== STEALTH POSTAVKE ==="
input bool   UseStealthMode     = true;    // Aktiviraj stealth mode
input int    OpenDelayMin       = 0;       // Min delay otvaranja (sek)
input int    OpenDelayMax       = 4;       // Max delay otvaranja (sek)
input int    SLDelayMin         = 7;       // Min delay za SL (sek)
input int    SLDelayMax         = 13;      // Max delay za SL (sek)
input double LargeCandleATR     = 3.0;     // Large candle filter (x ATR)

input group "=== TRAILING POSTAVKE ==="
input int    TrailActivatePips  = 500;     // Aktivacija trailinga (pips)
input int    TrailBEPipsMin     = 33;      // BE + min pips
input int    TrailBEPipsMax     = 38;      // BE + max pips

//--- Struktura za pending trade
struct PendingTradeInfo
{
   bool              active;
   ENUM_ORDER_TYPE   type;
   double            lot;
   double            intendedSL;
   double            intendedTP;
   datetime          signalTime;
   int               delaySeconds;
};

//--- Struktura za pending SL
struct PendingSLInfo
{
   bool     active;
   ulong    ticket;
   double   intendedSL;
   double   stealthTP;
   double   entryPrice;
   datetime openTime;
   int      delaySeconds;
   int      randomBEPips;
   int      trailLevel;
};

//--- globals
CTrade trade;
int atrHandle, bbHandle;
datetime lastBar = 0;
datetime lastTradeTime = 0;

PendingTradeInfo g_pendingTrade;
PendingSLInfo    g_positions[];
int              g_posCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_M5, ATRperiod);
   bbHandle  = iBands(_Symbol, PERIOD_M5, BBperiod, 0, BBdev, PRICE_CLOSE);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   g_pendingTrade.active = false;
   ArrayResize(g_positions, 0);
   g_posCount = 0;

   Print("=== KymcoDe v2.0 STEALTH MODE ===");
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
   IndicatorRelease(bbHandle);
}
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
   if(minVal >= maxVal) return minVal;
   return minVal + (MathRand() % (maxVal - minVal + 1));
}
//+------------------------------------------------------------------+
//| STEALTH: Trading Window (User Ned 00:01 - Pet 11:30)             |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // MT5 vrijeme (user + 1h)
   // User Ned 00:01 = MT5 Ned 01:01
   if(dt.day_of_week == 0)
   {
      if(dt.hour > 1 || (dt.hour == 1 && dt.min >= 1))
         return true;
      return false;
   }

   // Pon - Cet: cijeli dan
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

   // User Pet 11:30 = MT5 Pet 12:30
   if(dt.day_of_week == 5)
   {
      if(dt.hour < 12 || (dt.hour == 12 && dt.min <= 30))
         return true;
      return false;
   }

   return false;
}
//+------------------------------------------------------------------+
//| STEALTH: Blackout Period (User 14:30-15:30 = MT5 15:30-16:30)   |
//+------------------------------------------------------------------+
bool IsBlackoutPeriod()
{
   if(!UseStealthMode) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int minutes = dt.hour * 60 + dt.min;
   int blackoutStart = 15 * 60 + 30;  // MT5 15:30
   int blackoutEnd   = 16 * 60 + 30;  // MT5 16:30

   return (minutes >= blackoutStart && minutes < blackoutEnd);
}
//+------------------------------------------------------------------+
//| STEALTH: Large Candle Filter (> 3x ATR)                          |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
   if(!UseStealthMode) return false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;

   double high = iHigh(_Symbol, PERIOD_M5, 1);
   double low  = iLow(_Symbol, PERIOD_M5, 1);
   double candleSize = high - low;

   return (candleSize > LargeCandleATR * atr[0]);
}
//+------------------------------------------------------------------+
bool IsHighVolatility()
{
   double atr[1], atrs[];
   ArraySetAsSeries(atrs, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) != 1) return false;
   if(CopyBuffer(atrHandle, 0, 1, ATRmaPeriod, atrs) < ATRmaPeriod) return false;
   double sum = 0;
   for(int i=0;i<ATRmaPeriod;i++) sum += atrs[i];
   double atrMA = sum / ATRmaPeriod;
   return (atr[0] > atrMA);
}
//+------------------------------------------------------------------+
void DonchianSignal()
{
   double high[], low[], close[];
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);
   if(CopyHigh(_Symbol, PERIOD_M5, 1, DonchianPeriod, high) < DonchianPeriod) return;
   if(CopyLow (_Symbol, PERIOD_M5, 1, DonchianPeriod, low ) < DonchianPeriod) return;
   if(CopyClose(_Symbol, PERIOD_M5, 1, 1, close) != 1) return;
   double upper = high[ArrayMaximum(high)];
   double lower = low[ArrayMinimum(low)];
   if(close[0] > upper)
      QueueTrade(ORDER_TYPE_BUY, lower);
   else if(close[0] < lower)
      QueueTrade(ORDER_TYPE_SELL, upper);
}
//+------------------------------------------------------------------+
void BollingerSignal()
{
   double upper[1], lower[1], close[1];
   if(CopyBuffer(bbHandle, 1, 1, 1, upper) != 1) return;
   if(CopyBuffer(bbHandle, 2, 1, 1, lower) != 1) return;
   if(CopyClose (_Symbol, PERIOD_M5, 1, 1, close) != 1) return;
   double highPrev = iHigh(_Symbol, PERIOD_M5, 1);
   double lowPrev  = iLow (_Symbol, PERIOD_M5, 1);
   if(close[0] > upper[0])
      QueueTrade(ORDER_TYPE_SELL, highPrev);
   else if(close[0] < lower[0])
      QueueTrade(ORDER_TYPE_BUY, lowPrev);
}
//+------------------------------------------------------------------+
//| STEALTH: Queue trade s random delay-em                           |
//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type, double stop)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((type == ORDER_TYPE_BUY && stop >= entry) ||
      (type == ORDER_TYPE_SELL && stop <= entry)) return;

   double slDist = MathAbs(entry - stop);
   double lot = CalculateLot(slDist);
   if(lot <= 0) return;

   double tp = (type == ORDER_TYPE_BUY)
               ? entry + 2 * slDist
               : entry - 2 * slDist;

   if(UseStealthMode)
   {
      g_pendingTrade.active = true;
      g_pendingTrade.type = type;
      g_pendingTrade.lot = lot;
      g_pendingTrade.intendedSL = stop;
      g_pendingTrade.intendedTP = tp;
      g_pendingTrade.signalTime = TimeCurrent();
      g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
      Print("KymcoDe: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
   }
   else
   {
      ExecuteTrade(type, lot, stop, tp);
   }
}
//+------------------------------------------------------------------+
//| STEALTH: Execute trade (bez SL/TP - dodaje se kasnije)           |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok;
   if(UseStealthMode)
   {
      // STEALTH: Otvori bez SL i TP
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, 0, 0, "KymcoDe")
           : trade.Sell(lot, _Symbol, entry, 0, 0, "KymcoDe");
   }
   else
   {
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, sl, tp, "KymcoDe")
           : trade.Sell(lot, _Symbol, entry, sl, tp, "KymcoDe");
   }

   if(ok)
   {
      lastTradeTime = TimeCurrent();

      if(UseStealthMode)
      {
         // Dodaj u pending SL listu
         ulong ticket = trade.ResultOrder();
         ArrayResize(g_positions, g_posCount + 1);
         g_positions[g_posCount].active = true;
         g_positions[g_posCount].ticket = ticket;
         g_positions[g_posCount].intendedSL = sl;
         g_positions[g_posCount].stealthTP = tp;
         g_positions[g_posCount].entryPrice = entry;
         g_positions[g_posCount].openTime = TimeCurrent();
         g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
         g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
         g_positions[g_posCount].trailLevel = 0;
         g_posCount++;
         Print("KymcoDe STEALTH: Opened ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " #", ticket, ", SL delay ", g_positions[g_posCount-1].delaySeconds, "s");
      }
   }
}
//+------------------------------------------------------------------+
double CalculateLot(double slDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slPoints = slDist / point;
   double lot = riskMoney / (slPoints * tickValue / tickSize);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   return MathMax(min, MathMin(max, lot));
}
//+------------------------------------------------------------------+
//| STEALTH: Provjeri pending trade delay                            |
//+------------------------------------------------------------------+
void ProcessPendingTrade()
{
   if(!g_pendingTrade.active) return;

   if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
   {
      ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                   g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
      g_pendingTrade.active = false;
   }
}
//+------------------------------------------------------------------+
//| STEALTH: Upravljaj pozicijama (SL delay, TP, trailing)           |
//+------------------------------------------------------------------+
void ManageStealthPositions()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = g_posCount - 1; i >= 0; i--)
   {
      if(!g_positions[i].active) continue;

      ulong ticket = g_positions[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         // Pozicija zatvorena
         g_positions[i].active = false;
         continue;
      }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- 1. Delayed SL (postavi SL nakon 7-13 sek)
      if(currentSL == 0 && g_positions[i].intendedSL != 0)
      {
         if(TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds)
         {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
               Print("KymcoDe STEALTH: SL set for #", ticket, " @ ", sl);
         }
      }

      //--- 2. Stealth TP check
      if(g_positions[i].stealthTP > 0)
      {
         bool tpHit = false;
         if(posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP)
            tpHit = true;
         if(posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP)
            tpHit = true;

         if(tpHit)
         {
            trade.PositionClose(ticket);
            Print("KymcoDe STEALTH: TP hit for #", ticket);
            g_positions[i].active = false;
            continue;
         }
      }

      //--- 3. Trailing: 500 pips -> BE + 33-38 pips
      if(g_positions[i].trailLevel < 1 && currentSL > 0)
      {
         double profitPips = 0;
         if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - g_positions[i].entryPrice) / point;
         else
            profitPips = (g_positions[i].entryPrice - currentPrice) / point;

         if(profitPips >= TrailActivatePips)
         {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
               newSL = g_positions[i].entryPrice + g_positions[i].randomBEPips * point;
            else
               newSL = g_positions[i].entryPrice - g_positions[i].randomBEPips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = false;
            if(posType == POSITION_TYPE_BUY && newSL > currentSL) shouldModify = true;
            if(posType == POSITION_TYPE_SELL && newSL < currentSL) shouldModify = true;

            if(shouldModify)
            {
               if(trade.PositionModify(ticket, newSL, 0))
               {
                  g_positions[i].trailLevel = 1;
                  Print("KymcoDe STEALTH: Trail BE+", g_positions[i].randomBEPips, " for #", ticket);
               }
            }
         }
      }
   }

   // Cleanup inactive
   CleanupPositions();
}
//+------------------------------------------------------------------+
void CleanupPositions()
{
   int newCount = 0;
   for(int i = 0; i < g_posCount; i++)
   {
      if(g_positions[i].active)
      {
         if(i != newCount)
            g_positions[newCount] = g_positions[i];
         newCount++;
      }
   }
   if(newCount != g_posCount)
   {
      g_posCount = newCount;
      ArrayResize(g_positions, g_posCount);
   }
}
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
            return true;
   }
   return false;
}
//+------------------------------------------------------------------+
double CurrentDailyDD()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, TimeCurrent());
   double pnl = 0;
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol)
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   return (pnl / bal) * 100.0;
}
//+------------------------------------------------------------------+
void OnTick()
{
   // STEALTH: Uvijek procesiraj pending i manage positions
   ProcessPendingTrade();
   ManageStealthPositions();

   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == lastBar) return;
   lastBar = barTime;

   // Provjere za novi trade
   if(!IsTradingWindow()) return;
   if(IsBlackoutPeriod()) return;
   if(IsLargeCandle()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   if(CurrentDailyDD() <= -MaxDailyDD) return;
   if(HasOpenPosition()) return;
   if(g_pendingTrade.active) return;  // Vec cekamo na trade
   if(TimeCurrent() - lastTradeTime < CooldownBars * PeriodSeconds(PERIOD_M5)) return;

   if(IsHighVolatility())
      DonchianSignal();
   else
      BollingerSignal();
}
//+------------------------------------------------------------------+
