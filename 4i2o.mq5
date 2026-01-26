//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                        Version 1.3 |
//|                                     Chandelier Exit + RSI Filter   |
//|                                                                    |
//|  v1.3 FIXES:                                                       |
//|  - CE window: EXACTLY CE_ATR_Period bars, no partial windows       |
//|  - Pip model: SYMBOL_TRADE_TICK_SIZE based, broker-safe            |
//+------------------------------------------------------------------+
#property copyright "4i2o"
#property link      ""
#property version   "1.3"
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
input int      TP_Min_Pips         = 95;       // Take Profit Min (pips)
input int      TP_Max_Pips         = 105;      // Take Profit Max (pips)
input int      SL_Min_Pips         = 1500;     // Stop Loss Min (pips)
input int      SL_Max_Pips         = 1600;     // Stop Loss Max (pips)
input bool     CloseOnOppositeSignal = true;   // Close on Opposite CE Signal
input ulong    MagicNumber         = 412024;   // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastBarTime      = 0;
datetime g_lastSignalBar    = 0;        // Duplicate signal protection
int      g_atrHandle        = INVALID_HANDLE;
int      g_rsiHandle        = INVALID_HANDLE;
CTrade   g_trade;

// Cached tick/pip values (initialized in OnInit)
double   g_tickSize         = 0;
double   g_pipSize          = 0;
int      g_digits           = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate inputs
   if(CE_ATR_Period <= 0 || RSI_Period <= 0)
   {
      Print("Error: Invalid period parameters");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Initialize ATR indicator handle
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, CE_ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR handle: ", GetLastError());
      return(INIT_FAILED);
   }

   // Initialize RSI indicator handle
   g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("Error creating RSI handle: ", GetLastError());
      return(INIT_FAILED);
   }

   // Wait for indicator data to be ready
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

   // Initialize tick/pip model (broker-safe)
   if(!InitializeTickModel())
   {
      Print("Error: Failed to initialize tick model");
      return(INIT_FAILED);
   }

   // Setup trade object
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(10);

   // Initialize random seed
   MathSrand((int)GetTickCount());

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Initialize tick/pip model using SYMBOL_TRADE_TICK_SIZE            |
//| This is broker-safe and works for Forex, XAUUSD, Indices          |
//+------------------------------------------------------------------+
bool InitializeTickModel()
{
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Validate tick size
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

   //+---------------------------------------------------------------+
   //| PIP SIZE DEFINITION (broker-safe using tick size)             |
   //|                                                                |
   //| Industry standard:                                             |
   //| - Sub-pip pricing (5/3 digits): pip = 10 * tick               |
   //| - Standard pricing (4/2 digits): pip = tick or 10 * tick      |
   //|                                                                |
   //| For XAUUSD (2 digits):                                         |
   //| - tick = 0.01 typically                                        |
   //| - pip = 0.1 (10 ticks) - industry convention                  |
   //|                                                                |
   //| This model ensures SL/TP are always valid tick multiples      |
   //+---------------------------------------------------------------+

   if(g_digits == 5 || g_digits == 3)
   {
      // Forex sub-pip pricing: EURUSD (5), USDJPY (3)
      // tick = 0.00001 or 0.001, pip = 10 * tick
      g_pipSize = g_tickSize * 10;
   }
   else if(g_digits == 2)
   {
      // Metals (XAUUSD): tick = 0.01, pip = 0.1
      g_pipSize = g_tickSize * 10;
   }
   else if(g_digits == 4)
   {
      // Old-style forex: tick = pip
      g_pipSize = g_tickSize;
   }
   else if(g_digits == 1)
   {
      // Some indices: tick = pip typically
      g_pipSize = g_tickSize;
   }
   else
   {
      // Default: 10 * tick
      g_pipSize = g_tickSize * 10;
   }

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
   // Execute logic ONLY at the beginning of a new candle
   if(!IsNewBar())
      return;

   // Calculate CE signals on closed candles
   int dir1 = 0, dir2 = 0;
   bool buySignal = false, sellSignal = false;

   if(!CalculateChandelierExit(dir1, dir2, buySignal, sellSignal))
      return;

   // Get RSI value from previous closed candle (bar index 1)
   double rsiValue = GetRSI(1);
   if(rsiValue < 0)
      return;

   // Check for existing position (filtered by Symbol AND MagicNumber)
   bool hasPosition = HasOpenPosition();

   // Handle opposite signal closing
   if(hasPosition && CloseOnOppositeSignal)
   {
      int posType = GetPositionType();

      if(posType == POSITION_TYPE_BUY && sellSignal)
      {
         if(ClosePosition())
            hasPosition = false;
      }
      else if(posType == POSITION_TYPE_SELL && buySignal)
      {
         if(ClosePosition())
            hasPosition = false;
      }
   }

   // No new trades if position exists
   if(hasPosition)
      return;

   // Duplicate signal protection: same bar cannot trigger multiple trades
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(g_lastSignalBar == currentBar)
      return;

   // Entry conditions
   // BUY: CE buy signal + RSI > 50
   if(buySignal && rsiValue > RSI_Threshold)
   {
      if(OpenTrade(ORDER_TYPE_BUY))
         g_lastSignalBar = currentBar;
   }
   // SELL: CE sell signal + RSI < 50
   else if(sellSignal && rsiValue < RSI_Threshold)
   {
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
//| Calculate Chandelier Exit - EXACT PineScript replication          |
//|                                                                    |
//| PineScript logic:                                                  |
//| longStop = (useClose ? highest(close,len) : highest(len)) - atr   |
//| longStopPrev = nz(longStop[1], longStop)                          |
//| longStop := close[1] > longStopPrev ? max(longStop, longStopPrev) : longStop |
//|                                                                    |
//| shortStop = (useClose ? lowest(close,len) : lowest(len)) + atr    |
//| shortStopPrev = nz(shortStop[1], shortStop)                       |
//| shortStop := close[1] < shortStopPrev ? min(shortStop, shortStopPrev) : shortStop |
//|                                                                    |
//| dir := close > shortStopPrev ? 1 : close < longStopPrev ? -1 : dir|
//|                                                                    |
//| buySignal = dir == 1 and dir[1] == -1                             |
//| sellSignal = dir == -1 and dir[1] == 1                            |
//|                                                                    |
//| v1.3 FIX: Window is EXACTLY CE_ATR_Period bars, no partial windows|
//+------------------------------------------------------------------+
bool CalculateChandelierExit(int &dir1, int &dir2, bool &buySignal, bool &sellSignal)
{
   //+---------------------------------------------------------------+
   //| WINDOW CALCULATION REQUIREMENT (PineScript equivalent)        |
   //|                                                                |
   //| highest(close, length) in PineScript:                         |
   //| - Uses EXACTLY `length` bars                                  |
   //| - Includes current bar (index 0 in Pine, index i in our loop) |
   //| - Window: [current, current-1, ..., current-(length-1)]       |
   //|                                                                |
   //| With ArraySetAsSeries(true):                                  |
   //| - Index 0 = newest bar (current)                              |
   //| - Index i = bar i periods ago                                 |
   //| - For bar i, window is [i, i+1, ..., i+length-1]              |
   //|                                                                |
   //| CRITICAL: If i + length - 1 >= barsNeeded, SKIP that bar      |
   //| This ensures NO partial windows and NO look-ahead             |
   //+---------------------------------------------------------------+

   // Calculate minimum bars required
   // We need: bar 0 (current), bar 1, bar 2 for signal detection
   // Plus enough history for CE_ATR_Period window at bar 2
   // Plus trailing calculation warmup
   int minBarsForSignal = 3;  // bars 0, 1, 2
   int windowRequirement = CE_ATR_Period;
   int trailingWarmup = 30;   // Extra bars for trailing to stabilize

   int barsNeeded = minBarsForSignal + windowRequirement + trailingWarmup;
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);

   if(totalBars < barsNeeded)
      return false;

   // Get ATR values via CopyBuffer
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_atrHandle, 0, 0, barsNeeded, atrBuffer) < barsNeeded)
      return false;

   // Get price data
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

   // Arrays to store calculated values
   double longStopArr[], shortStopArr[];
   int    dirArr[];
   ArrayResize(longStopArr, barsNeeded);
   ArrayResize(shortStopArr, barsNeeded);
   ArrayResize(dirArr, barsNeeded);
   ArrayInitialize(longStopArr, 0);
   ArrayInitialize(shortStopArr, 0);
   ArrayInitialize(dirArr, 0);

   // Calculate the first valid bar index (oldest bar with full window)
   // For bar i, we need indices i to i + CE_ATR_Period - 1
   // So: i + CE_ATR_Period - 1 < barsNeeded
   // Therefore: i < barsNeeded - CE_ATR_Period + 1
   int firstValidBar = barsNeeded - CE_ATR_Period;  // Last bar index with full window

   // Iterate from oldest valid bar to newest (firstValidBar down to 0)
   for(int i = firstValidBar; i >= 0; i--)
   {
      // Calculate ATR component
      double atr = CE_ATR_Multiplier * atrBuffer[i];

      //+------------------------------------------------------------+
      //| FIXED WINDOW: EXACTLY CE_ATR_Period bars                   |
      //| From index i to i + CE_ATR_Period - 1 (inclusive)          |
      //| This matches PineScript highest(close, length) exactly     |
      //+------------------------------------------------------------+

      double highestVal = -DBL_MAX;
      double lowestVal  = DBL_MAX;

      // Loop through EXACTLY CE_ATR_Period bars
      int windowEnd = i + CE_ATR_Period;  // Exclusive end

      for(int j = i; j < windowEnd; j++)
      {
         if(CE_UseClosePrice)
         {
            // PineScript: highest(close, length), lowest(close, length)
            if(closeBuffer[j] > highestVal) highestVal = closeBuffer[j];
            if(closeBuffer[j] < lowestVal)  lowestVal = closeBuffer[j];
         }
         else
         {
            // PineScript: highest(high, length), lowest(low, length)
            if(highBuffer[j] > highestVal) highestVal = highBuffer[j];
            if(lowBuffer[j] < lowestVal)   lowestVal = lowBuffer[j];
         }
      }

      // Calculate raw stop values
      double longStopRaw  = highestVal - atr;
      double shortStopRaw = lowestVal + atr;

      // Apply trailing logic
      if(i < firstValidBar)
      {
         // Get previous values (i+1 is the previous bar in our iteration)
         double longStopPrev  = longStopArr[i + 1];
         double shortStopPrev = shortStopArr[i + 1];
         double closePrev     = closeBuffer[i + 1];  // close[1] in Pine context
         double closeCurrent  = closeBuffer[i];      // close in Pine context
         int    dirPrev       = dirArr[i + 1];

         // PineScript: longStop := close[1] > longStopPrev ? max(longStop, longStopPrev) : longStop
         if(closePrev > longStopPrev)
            longStopArr[i] = MathMax(longStopRaw, longStopPrev);
         else
            longStopArr[i] = longStopRaw;

         // PineScript: shortStop := close[1] < shortStopPrev ? min(shortStop, shortStopPrev) : shortStop
         if(closePrev < shortStopPrev)
            shortStopArr[i] = MathMin(shortStopRaw, shortStopPrev);
         else
            shortStopArr[i] = shortStopRaw;

         // PineScript: dir := close > shortStopPrev ? 1 : close < longStopPrev ? -1 : dir
         if(closeCurrent > shortStopPrev)
            dirArr[i] = 1;
         else if(closeCurrent < longStopPrev)
            dirArr[i] = -1;
         else
            dirArr[i] = dirPrev;  // Persist previous direction
      }
      else
      {
         // First valid bar (oldest) - initialize
         longStopArr[i]  = longStopRaw;
         shortStopArr[i] = shortStopRaw;
         dirArr[i]       = 1;  // Default direction
      }
   }

   // Extract directions for bar 1 and bar 2 (previous closed candles)
   // Bar 0 = current (not closed yet)
   // Bar 1 = last closed candle
   // Bar 2 = candle before that

   dir1 = dirArr[1];
   dir2 = dirArr[2];

   // Signal detection
   // PineScript: buySignal = dir == 1 and dir[1] == -1
   // At bar 1: dir[1]=1 means dirArr[1]=1, dir[2]=-1 means dirArr[2]=-1
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
//| Open trade with random TP/SL                                      |
//| Uses tick-based pip model for broker safety                       |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType)
{
   // Generate random TP and SL in pips
   int tpPips = RandomInRange(TP_Min_Pips, TP_Max_Pips);
   int slPips = RandomInRange(SL_Min_Pips, SL_Max_Pips);

   // Convert pips to price distance using broker-safe pip size
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

   // Validate against minimum stop level
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

   // Execute trade
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
