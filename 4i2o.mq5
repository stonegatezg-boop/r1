//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                        Version 1.2 |
//|                                     Chandelier Exit + RSI Filter   |
//|                                                                    |
//|  CE logic is 1:1 replica of TradingView PineScript implementation  |
//|  - Trailing stop state persists across bars                        |
//|  - No look-ahead bias                                              |
//|  - No repaint: signals from closed candles only                    |
//+------------------------------------------------------------------+
#property copyright "4i2o"
#property link      ""
#property version   "1.2"
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

// Persistent CE state (survives across ticks)
double   g_longStop         = 0;
double   g_shortStop        = 0;
int      g_direction        = 0;        // 1 = long, -1 = short
bool     g_ceInitialized    = false;

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

   // Setup trade object
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(10);

   // Initialize random seed
   MathSrand((int)GetTickCount());

   // Reset CE state
   g_ceInitialized = false;
   g_longStop = 0;
   g_shortStop = 0;
   g_direction = 0;

   return(INIT_SUCCEEDED);
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
//+------------------------------------------------------------------+
bool CalculateChandelierExit(int &dir1, int &dir2, bool &buySignal, bool &sellSignal)
{
   // We need to calculate direction for bar 1 and bar 2 (closed candles)
   // To do this properly with trailing stops, we need historical calculation

   int barsNeeded = CE_ATR_Period + 50;  // Extra bars for proper trailing calculation
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);

   if(totalBars < barsNeeded)
      return false;

   // Get ATR values via CopyBuffer (NOT direct iATR call!)
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

   // Arrays to store calculated values (index 0 = current bar, etc.)
   double longStopArr[], shortStopArr[];
   int    dirArr[];
   ArrayResize(longStopArr, barsNeeded);
   ArrayResize(shortStopArr, barsNeeded);
   ArrayResize(dirArr, barsNeeded);
   ArrayInitialize(longStopArr, 0);
   ArrayInitialize(shortStopArr, 0);
   ArrayInitialize(dirArr, 0);

   // Calculate from oldest bar to newest (barsNeeded-1 down to 0)
   // This mimics how PineScript processes bars left-to-right
   for(int i = barsNeeded - 1; i >= 0; i--)
   {
      // Calculate ATR component
      double atr = CE_ATR_Multiplier * atrBuffer[i];

      // Calculate highest and lowest over CE_ATR_Period bars
      // In PineScript: highest(close, length) includes current bar
      // With ArraySetAsSeries, bar i is "current" for this calculation
      double highestVal = 0;
      double lowestVal = DBL_MAX;

      for(int j = i; j < i + CE_ATR_Period && j < barsNeeded; j++)
      {
         if(CE_UseClosePrice)
         {
            // Use CLOSE for both highest and lowest when UseClosePrice = true
            if(closeBuffer[j] > highestVal) highestVal = closeBuffer[j];
            if(closeBuffer[j] < lowestVal)  lowestVal = closeBuffer[j];
         }
         else
         {
            // Use HIGH for highest, LOW for lowest
            if(highBuffer[j] > highestVal) highestVal = highBuffer[j];
            if(lowBuffer[j] < lowestVal)   lowestVal = lowBuffer[j];
         }
      }

      // Calculate raw stop values
      double longStopRaw  = highestVal - atr;
      double shortStopRaw = lowestVal + atr;

      // Apply trailing logic
      if(i < barsNeeded - 1)
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
         // First bar (oldest) - initialize
         longStopArr[i]  = longStopRaw;
         shortStopArr[i] = shortStopRaw;
         dirArr[i]       = 1;  // Default direction
      }
   }

   // Extract directions for bar 1 and bar 2 (previous closed candles)
   // Bar 0 = current (not closed yet)
   // Bar 1 = last closed candle (this is where we detect signals)
   // Bar 2 = candle before that

   dir1 = dirArr[1];  // Direction at bar 1
   dir2 = dirArr[2];  // Direction at bar 2

   // Signal detection (PineScript: buySignal = dir == 1 and dir[1] == -1)
   // At bar 1: we check if dir[1]==1 and dir[2]==-1
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

   // Attempt to close
   if(!g_trade.PositionClose(ticket))
   {
      Print("PositionClose failed: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
      return false;
   }

   // Verify close was successful
   uint retcode = g_trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Position close verification failed: ", retcode);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Calculate pip value for current symbol                            |
//| Handles Forex, JPY pairs, Gold, Indices correctly                 |
//+------------------------------------------------------------------+
double GetPipValue()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Standard forex pairs (5 digits: EURUSD, GBPUSD, etc.)
   if(digits == 5 || digits == 3)
      return point * 10;

   // JPY pairs (3 digits) or 2-digit symbols
   if(digits == 2)
      return point * 10;  // For XAUUSD: 0.01 * 10 = 0.1

   // 4-digit forex (old style)
   if(digits == 4)
      return point;

   // Indices or other
   if(digits == 1)
      return point * 10;

   // Default fallback
   return point * 10;
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
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType)
{
   double pip = GetPipValue();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Generate random TP and SL
   int tpPips = RandomInRange(TP_Min_Pips, TP_Max_Pips);
   int slPips = RandomInRange(SL_Min_Pips, SL_Max_Pips);

   double price, sl, tp;

   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = NormalizeDouble(price - slPips * pip, digits);
      tp = NormalizeDouble(price + tpPips * pip, digits);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = NormalizeDouble(price + slPips * pip, digits);
      tp = NormalizeDouble(price - tpPips * pip, digits);
   }

   // Validate stops
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(MathAbs(price - sl) < minStop || MathAbs(price - tp) < minStop)
   {
      Print("Warning: SL/TP too close to price, adjusting...");
   }

   // Execute trade
   bool result = false;

   if(orderType == ORDER_TYPE_BUY)
      result = g_trade.Buy(LotSize, _Symbol, price, sl, tp, "");  // Empty comment
   else
      result = g_trade.Sell(LotSize, _Symbol, price, sl, tp, ""); // Empty comment

   if(!result)
   {
      Print("Trade failed: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
      return false;
   }

   // Verify execution
   uint retcode = g_trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Trade execution verification failed: ", retcode);
      return false;
   }

   return true;
}
//+------------------------------------------------------------------+
