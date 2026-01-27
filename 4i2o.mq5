//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                        Version 1.5 |
//|                                     Chandelier Exit + RSI Filter   |
//|                                                                    |
//|  v1.5 FIXES:                                                       |
//|  - Reverted to bar 1/2 signal detection (v1.4 was too delayed)    |
//|  - Kept currentDir validation to prevent false signals            |
//|  - Pip model: 1 pip = SYMBOL_TRADE_TICK_SIZE                      |
//+------------------------------------------------------------------+
#property copyright "4i2o"
#property link      ""
#property version   "1.5"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Chandelier Exit Settings ==="
input int      CE_ATR_Period       = 10;       // ATR Period
input double   CE_ATR_Multiplier   = 3.2;      // ATR Multiplier
input bool     CE_UseClosePrice    = true;     // Use Close Price for Extremums

input group "=== RSI Settings ==="
input int      RSI_Period          = 14;       // RSI Period
input double   RSI_Threshold       = 50.0;     // RSI Threshold (BUY>50, SELL<50)

input group "=== Trade Settings ==="
input double   LotSize             = 0.01;     // Lot Size
input int      TP_Min_Pips         = 95;       // Take Profit Min (MT5 pips)
input int      TP_Max_Pips         = 105;      // Take Profit Max (MT5 pips)
input int      SL_Min_Pips         = 1500;     // Stop Loss Min (MT5 pips)
input int      SL_Max_Pips         = 1600;     // Stop Loss Max (MT5 pips)
input bool     CloseOnOppositeSignal = true;   // Close on Opposite CE Signal
input ulong    MagicNumber         = 412024;   // Magic Number

input group "=== Debug ==="
input bool     EnableDebugLog     = false;    // Enable Debug Logging

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastBarTime      = 0;
datetime g_lastSignalBar    = 0;
int      g_atrHandle        = INVALID_HANDLE;
int      g_rsiHandle        = INVALID_HANDLE;
CTrade   g_trade;

// Tick/pip model (v1.4: NO multiplication)
double   g_tickSize         = 0;
double   g_pipSize          = 0;
int      g_digits           = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(CE_ATR_Period <= 0 || RSI_Period <= 0)
   {
      Print("Error: Invalid period parameters");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, CE_ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR handle: ", GetLastError());
      return(INIT_FAILED);
   }

   g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("Error creating RSI handle: ", GetLastError());
      return(INIT_FAILED);
   }

   int waitCount = 0;
   while(BarsCalculated(g_atrHandle) <= 0 || BarsCalculated(g_rsiHandle) <= 0)
   {
      Sleep(10);
      waitCount++;
      if(waitCount > 500)
      {
         Print("Error: Indicator data not ready");
         return(INIT_FAILED);
      }
   }

   if(!InitializeTickModel())
   {
      Print("Error: Failed to initialize tick model");
      return(INIT_FAILED);
   }

   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(10);

   MathSrand((int)GetTickCount());

   Print("=== 4i2o EA v1.5 Initialized ===");
   Print("CE: Period=", CE_ATR_Period, " Mult=", CE_ATR_Multiplier, " UseClose=", CE_UseClosePrice);
   Print("RSI: Period=", RSI_Period, " Threshold=", RSI_Threshold);
   Print("Pip Model: 1 pip = ", g_pipSize, " (tickSize)");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Initialize tick/pip model - v1.4 FIX                              |
//|                                                                    |
//| CRITICAL: 1 pip = SYMBOL_TRADE_TICK_SIZE (NO multiplication)      |
//+------------------------------------------------------------------+
bool InitializeTickModel()
{
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(g_tickSize <= 0)
   {
      Print("Warning: SYMBOL_TRADE_TICK_SIZE invalid, using SYMBOL_POINT");
      g_tickSize = point;
   }

   if(g_tickSize <= 0)
   {
      Print("Error: Cannot determine tick size");
      return false;
   }

   // v1.4 FIX: 1 pip = 1 tick (MT5 native, NO *10)
   g_pipSize = g_tickSize;

   Print("Tick Model: tickSize=", g_tickSize, " pipSize=", g_pipSize, " digits=", g_digits);

   return true;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar())
      return;

   int currentDir = 0;
   int dir1 = 0, dir2 = 0;
   bool buySignal = false, sellSignal = false;

   if(!CalculateChandelierExit(currentDir, dir1, dir2, buySignal, sellSignal))
      return;

   // RSI from bar 1 (same bar as CE signal, fully closed)
   double rsiValue = GetRSI(1);
   if(rsiValue < 0)
      return;

   if(EnableDebugLog)
   {
      Print("CE State: currentDir=", currentDir, " dir1=", dir1, " dir2=", dir2,
            " buySignal=", buySignal, " sellSignal=", sellSignal, " RSI=", rsiValue);
   }

   bool hasPosition = HasOpenPosition();

   // Handle opposite signal closing
   if(hasPosition && CloseOnOppositeSignal)
   {
      int posType = GetPositionType();

      // Close only if CURRENT direction confirms the signal
      if(posType == POSITION_TYPE_BUY && sellSignal && currentDir == -1)
      {
         if(ClosePosition())
            hasPosition = false;
      }
      else if(posType == POSITION_TYPE_SELL && buySignal && currentDir == 1)
      {
         if(ClosePosition())
            hasPosition = false;
      }
   }

   if(hasPosition)
      return;

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(g_lastSignalBar == currentBar)
      return;

   //+---------------------------------------------------------------+
   //| SIGNAL VALIDATION (v1.4)                                       |
   //|                                                                 |
   //| Additional check: current direction must match signal          |
   //| - BUY signal requires currentDir == 1 (we're in uptrend)      |
   //| - SELL signal requires currentDir == -1 (we're in downtrend)  |
   //|                                                                 |
   //| This prevents false signals when CE state doesn't match       |
   //+---------------------------------------------------------------+

   // BUY: signal + RSI > 50 + current direction is LONG
   if(buySignal && rsiValue > RSI_Threshold && currentDir == 1)
   {
      if(EnableDebugLog)
         Print(">>> Opening BUY: RSI=", rsiValue, " dir1=", dir1, " dir2=", dir2);

      if(OpenTrade(ORDER_TYPE_BUY))
         g_lastSignalBar = currentBar;
   }
   // SELL: signal + RSI < 50 + current direction is SHORT
   else if(sellSignal && rsiValue < RSI_Threshold && currentDir == -1)
   {
      if(EnableDebugLog)
         Print(">>> Opening SELL: RSI=", rsiValue, " dir1=", dir1, " dir2=", dir2);

      if(OpenTrade(ORDER_TYPE_SELL))
         g_lastSignalBar = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Check for new bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
      return false;

   g_lastBarTime = currentBarTime;
   return true;
}

//+------------------------------------------------------------------+
//| Calculate Chandelier Exit - v1.5                                  |
//|                                                                    |
//| Returns:                                                           |
//| - currentDir: current CE direction at bar 1 (1=long, -1=short)   |
//| - dir1, dir2: directions at bar 1 and bar 2                       |
//| - buySignal: true if direction flipped to long at bar 1          |
//| - sellSignal: true if direction flipped to short at bar 1        |
//|                                                                    |
//| v1.5: Reverted to bar 1/2 (v1.4 bar 2/3 was too delayed)         |
//+------------------------------------------------------------------+
bool CalculateChandelierExit(int &currentDir, int &dir1, int &dir2, bool &buySignal, bool &sellSignal)
{
   int minBarsForSignal = 3;  // bars 0, 1, 2
   int windowRequirement = CE_ATR_Period;
   int trailingWarmup = 50;

   int barsNeeded = minBarsForSignal + windowRequirement + trailingWarmup;
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);

   if(totalBars < barsNeeded)
      return false;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_atrHandle, 0, 0, barsNeeded, atrBuffer) < barsNeeded)
      return false;

   double closeBuffer[], highBuffer[], lowBuffer[];
   ArraySetAsSeries(closeBuffer, true);
   ArraySetAsSeries(highBuffer, true);
   ArraySetAsSeries(lowBuffer, true);

   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, closeBuffer) < barsNeeded)
      return false;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, highBuffer) < barsNeeded)
      return false;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, lowBuffer) < barsNeeded)
      return false;

   double longStopArr[], shortStopArr[];
   int    dirArr[];
   ArrayResize(longStopArr, barsNeeded);
   ArrayResize(shortStopArr, barsNeeded);
   ArrayResize(dirArr, barsNeeded);
   ArrayInitialize(longStopArr, 0);
   ArrayInitialize(shortStopArr, 0);
   ArrayInitialize(dirArr, 0);

   int firstValidBar = barsNeeded - CE_ATR_Period;

   // Process from oldest to newest
   for(int i = firstValidBar; i >= 0; i--)
   {
      double atr = CE_ATR_Multiplier * atrBuffer[i];

      // Calculate highest/lowest over EXACTLY CE_ATR_Period bars
      double highestVal = -DBL_MAX;
      double lowestVal  = DBL_MAX;

      for(int j = i; j < i + CE_ATR_Period; j++)
      {
         if(CE_UseClosePrice)
         {
            if(closeBuffer[j] > highestVal) highestVal = closeBuffer[j];
            if(closeBuffer[j] < lowestVal)  lowestVal = closeBuffer[j];
         }
         else
         {
            if(highBuffer[j] > highestVal) highestVal = highBuffer[j];
            if(lowBuffer[j] < lowestVal)   lowestVal = lowBuffer[j];
         }
      }

      double longStopRaw  = highestVal - atr;
      double shortStopRaw = lowestVal + atr;

      if(i < firstValidBar)
      {
         double longStopPrev  = longStopArr[i + 1];
         double shortStopPrev = shortStopArr[i + 1];
         double closePrev     = closeBuffer[i + 1];
         double closeCurrent  = closeBuffer[i];
         int    dirPrev       = dirArr[i + 1];

         // Trailing stop logic (matches PineScript exactly)
         if(closePrev > longStopPrev)
            longStopArr[i] = MathMax(longStopRaw, longStopPrev);
         else
            longStopArr[i] = longStopRaw;

         if(closePrev < shortStopPrev)
            shortStopArr[i] = MathMin(shortStopRaw, shortStopPrev);
         else
            shortStopArr[i] = shortStopRaw;

         // Direction logic (matches PineScript exactly)
         // dir := close > shortStopPrev ? 1 : close < longStopPrev ? -1 : dir
         if(closeCurrent > shortStopPrev)
            dirArr[i] = 1;
         else if(closeCurrent < longStopPrev)
            dirArr[i] = -1;
         else
            dirArr[i] = dirPrev;
      }
      else
      {
         longStopArr[i]  = longStopRaw;
         shortStopArr[i] = shortStopRaw;
         dirArr[i]       = 1;
      }
   }

   // Return current direction (bar 1 = last fully closed)
   currentDir = dirArr[1];

   // v1.5: Signal detection uses bar 1 and bar 2 (immediate detection)
   // This matches TradingView timing: signal at bar N, entry at open of bar N+1
   dir1 = dirArr[1];  // Last closed bar
   dir2 = dirArr[2];  // Bar before that

   // Signal: direction changed at bar 1
   buySignal  = (dir1 == 1  && dir2 == -1);
   sellSignal = (dir1 == -1 && dir2 == 1);

   return true;
}

//+------------------------------------------------------------------+
//| Get RSI value at specified bar index                              |
//+------------------------------------------------------------------+
double GetRSI(int barIndex)
{
   double rsiBuffer[];
   ArraySetAsSeries(rsiBuffer, true);

   if(CopyBuffer(g_rsiHandle, 0, barIndex, 1, rsiBuffer) < 1)
      return -1;

   return rsiBuffer[0];
}

//+------------------------------------------------------------------+
//| Check if position exists (filtered by Symbol AND MagicNumber)     |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get position type (filtered by Symbol AND MagicNumber)            |
//+------------------------------------------------------------------+
int GetPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
      {
         return (int)PositionGetInteger(POSITION_TYPE);
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Get position ticket (filtered by Symbol AND MagicNumber)          |
//+------------------------------------------------------------------+
ulong GetPositionTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
      {
         return ticket;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Close position with verification                                  |
//+------------------------------------------------------------------+
bool ClosePosition()
{
   ulong ticket = GetPositionTicket();
   if(ticket == 0)
      return false;

   if(!g_trade.PositionClose(ticket))
   {
      Print("PositionClose failed: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
      return false;
   }

   uint retcode = g_trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Position close verification failed: ", retcode);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Normalize price to valid tick size multiple                       |
//+------------------------------------------------------------------+
double NormalizeToTick(double price)
{
   if(g_tickSize <= 0)
      return NormalizeDouble(price, g_digits);

   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, g_digits);
}

//+------------------------------------------------------------------+
//| Generate random integer in range [min, max]                       |
//+------------------------------------------------------------------+
int RandomInRange(int minVal, int maxVal)
{
   if(minVal >= maxVal)
      return minVal;

   return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
//| Open trade with random TP/SL - v1.4 pip model                     |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType)
{
   int tpPips = RandomInRange(TP_Min_Pips, TP_Max_Pips);
   int slPips = RandomInRange(SL_Min_Pips, SL_Max_Pips);

   // v1.4: pipSize = tickSize (no multiplication)
   double tpDistance = tpPips * g_pipSize;
   double slDistance = slPips * g_pipSize;

   double price, sl, tp;

   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = NormalizeToTick(price - slDistance);
      tp = NormalizeToTick(price + tpDistance);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = NormalizeToTick(price + slDistance);
      tp = NormalizeToTick(price - tpDistance);
   }

   // Log trade details
   Print("Trade: ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         " Price=", price, " TP=", tp, " (", tpPips, " pips)",
         " SL=", sl, " (", slPips, " pips)");

   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevel * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(MathAbs(price - sl) < minStopDistance)
   {
      Print("Warning: SL distance below minimum, adjusting");
      if(orderType == ORDER_TYPE_BUY)
         sl = NormalizeToTick(price - minStopDistance - g_tickSize);
      else
         sl = NormalizeToTick(price + minStopDistance + g_tickSize);
   }

   if(MathAbs(price - tp) < minStopDistance)
   {
      Print("Warning: TP distance below minimum, adjusting");
      if(orderType == ORDER_TYPE_BUY)
         tp = NormalizeToTick(price + minStopDistance + g_tickSize);
      else
         tp = NormalizeToTick(price - minStopDistance - g_tickSize);
   }

   bool result = false;

   if(orderType == ORDER_TYPE_BUY)
      result = g_trade.Buy(LotSize, _Symbol, price, sl, tp, "");
   else
      result = g_trade.Sell(LotSize, _Symbol, price, sl, tp, "");

   if(!result)
   {
      Print("Trade failed: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
      return false;
   }

   uint retcode = g_trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Trade execution verification failed: ", retcode);
      return false;
   }

   return true;
}
//+------------------------------------------------------------------+
