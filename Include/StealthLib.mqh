//+------------------------------------------------------------------+
//|                                                  StealthLib.mqh  |
//|                        Stealth Trading Library v1.0              |
//|                        Za sve CALF/Clawder/KymcoDe EA            |
//|                        Created: 2026-02-20                        |
//+------------------------------------------------------------------+
#ifndef STEALTH_LIB_MQH
#define STEALTH_LIB_MQH

//+------------------------------------------------------------------+
//| STEALTH KONFIGURACIJA (MT5 vrijeme = user vrijeme + 1h)         |
//+------------------------------------------------------------------+
// Trading window: User Ned 00:01 - Pet 11:30 = MT5 Ned 01:01 - Pet 12:30
// Blackout: User 14:30-15:30 = MT5 15:30-16:30
// Large candle filter: > 3x ATR
// Random delay: 0-4 sekunde
// Delayed SL: 7-13 sekundi
// Trailing: 500 pips -> BE + 33-38 pips

//+------------------------------------------------------------------+
//| Struktura za pending trade (čeka random delay)                   |
//+------------------------------------------------------------------+
struct StealthPendingTrade
{
   bool              active;
   ENUM_ORDER_TYPE   type;
   double            lot;
   double            intendedSL;
   double            intendedTP;    // Stealth TP (interno)
   datetime          signalTime;
   int               delaySeconds;  // 0-4 random
   string            comment;
};

//+------------------------------------------------------------------+
//| Struktura za pending SL (čeka 7-13 sek nakon otvaranja)         |
//+------------------------------------------------------------------+
struct StealthPendingSL
{
   bool     active;
   ulong    ticket;
   double   intendedSL;
   double   stealthTP;
   datetime openTime;
   int      delaySeconds;  // 7-13 random
};

//+------------------------------------------------------------------+
//| Struktura za stealth position management                         |
//+------------------------------------------------------------------+
struct StealthPosition
{
   ulong    ticket;
   double   entryPrice;
   double   stealthTP;
   double   originalSL;
   int      trailLevel;      // 0=none, 1=BE
   int      randomBEPips;    // 33-38
};

//+------------------------------------------------------------------+
//| Global stealth varijable (deklarirati u EA)                      |
//+------------------------------------------------------------------+
// StealthPendingTrade  g_pendingTrade;
// StealthPendingSL     g_pendingSL;
// StealthPosition      g_stealthPositions[];
// int                  g_stealthPosCount = 0;

//+------------------------------------------------------------------+
//| Random broj u rasponu [min, max]                                 |
//+------------------------------------------------------------------+
int StealthRandomRange(int minVal, int maxVal)
{
   if(minVal >= maxVal) return minVal;
   return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
//| Inicijalizacija random generatora                                |
//+------------------------------------------------------------------+
void StealthInit()
{
   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
}

//+------------------------------------------------------------------+
//| Provjera trading window (MT5 vrijeme)                            |
//| User: Ned 00:01 - Pet 11:30                                      |
//| MT5:  Ned 01:01 - Pet 12:30                                      |
//+------------------------------------------------------------------+
bool StealthIsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Nedjelja (day_of_week = 0)
   if(dt.day_of_week == 0)
   {
      // MT5 01:01+ = User 00:01+
      if(dt.hour > 1 || (dt.hour == 1 && dt.min >= 1))
         return true;
      return false;
   }

   // Ponedjeljak - Četvrtak: cijeli dan (bez blackout provjere ovdje)
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

   // Petak: do MT5 12:30 = User 11:30
   if(dt.day_of_week == 5)
   {
      if(dt.hour < 12 || (dt.hour == 12 && dt.min <= 30))
         return true;
      return false;
   }

   // Subota
   return false;
}

//+------------------------------------------------------------------+
//| Provjera blackout perioda (ne otvaraj trade)                     |
//| User: 14:30 - 15:30                                              |
//| MT5:  15:30 - 16:30                                              |
//+------------------------------------------------------------------+
bool StealthIsBlackoutPeriod()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int minutes = dt.hour * 60 + dt.min;
   int blackoutStart = 15 * 60 + 30;  // MT5 15:30
   int blackoutEnd   = 16 * 60 + 30;  // MT5 16:30

   return (minutes >= blackoutStart && minutes < blackoutEnd);
}

//+------------------------------------------------------------------+
//| Provjera velike svijeće (> 3x ATR)                               |
//+------------------------------------------------------------------+
bool StealthIsLargeCandle(int atrHandle, double multiplier = 3.0)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;

   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double candleSize = high - low;

   return (candleSize > multiplier * atr[0]);
}

//+------------------------------------------------------------------+
//| Generiraj random delay za otvaranje (0-4 sek)                    |
//+------------------------------------------------------------------+
int StealthGetOpenDelay()
{
   return StealthRandomRange(0, 4);
}

//+------------------------------------------------------------------+
//| Generiraj random delay za SL (7-13 sek)                          |
//+------------------------------------------------------------------+
int StealthGetSLDelay()
{
   return StealthRandomRange(7, 13);
}

//+------------------------------------------------------------------+
//| Generiraj random BE pips (33-38)                                 |
//+------------------------------------------------------------------+
int StealthGetBEPips()
{
   return StealthRandomRange(33, 38);
}

//+------------------------------------------------------------------+
//| Provjeri je li prošao delay                                      |
//+------------------------------------------------------------------+
bool StealthDelayPassed(datetime startTime, int delaySeconds)
{
   return (TimeCurrent() >= startTime + delaySeconds);
}

//+------------------------------------------------------------------+
//| Izračunaj profit u pipsima                                       |
//+------------------------------------------------------------------+
double StealthGetProfitPips(ulong ticket, double entryPrice)
{
   if(!PositionSelectByTicket(ticket)) return 0;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double currentPrice;

   if(posType == POSITION_TYPE_BUY)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (currentPrice - entryPrice) / point;
   }
   else
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (entryPrice - currentPrice) / point;
   }
}

//+------------------------------------------------------------------+
//| Provjeri stealth TP hit                                          |
//+------------------------------------------------------------------+
bool StealthCheckTPHit(ulong ticket, double stealthTP)
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(stealthTP <= 0) return false;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentPrice;

   if(posType == POSITION_TYPE_BUY)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (currentPrice >= stealthTP);
   }
   else
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (currentPrice <= stealthTP);
   }
}

//+------------------------------------------------------------------+
//| Trailing: pomakni SL na BE + random pips kada profit > 500 pips  |
//+------------------------------------------------------------------+
bool StealthShouldTrailToBE(double profitPips, int currentTrailLevel)
{
   return (profitPips >= 500 && currentTrailLevel < 1);
}

//+------------------------------------------------------------------+
//| Izračunaj BE + pips SL                                           |
//+------------------------------------------------------------------+
double StealthCalculateBESL(double entryPrice, ENUM_POSITION_TYPE posType, int bePips)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(posType == POSITION_TYPE_BUY)
      return NormalizeDouble(entryPrice + bePips * point, digits);
   else
      return NormalizeDouble(entryPrice - bePips * point, digits);
}

//+------------------------------------------------------------------+
//| Kombinirani filter: može li se otvoriti trade?                   |
//+------------------------------------------------------------------+
bool StealthCanOpenTrade(int atrHandle)
{
   // 1. Trading window
   if(!StealthIsTradingWindow())
      return false;

   // 2. Blackout period
   if(StealthIsBlackoutPeriod())
      return false;

   // 3. Large candle filter
   if(StealthIsLargeCandle(atrHandle, 3.0))
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Debug print za stealth status                                    |
//+------------------------------------------------------------------+
void StealthDebugPrint()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   Print("=== STEALTH STATUS ===");
   Print("MT5 Time: ", dt.hour, ":", dt.min, " (User: ", dt.hour-1, ":", dt.min, ")");
   Print("Day: ", dt.day_of_week, " (0=Sun, 5=Fri)");
   Print("Trading Window: ", StealthIsTradingWindow() ? "YES" : "NO");
   Print("Blackout Period: ", StealthIsBlackoutPeriod() ? "YES" : "NO");
}

#endif // STEALTH_LIB_MQH
//+------------------------------------------------------------------+
