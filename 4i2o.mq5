//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                        Version 1.1 |
//|                                     Chandelier Exit + RSI Filter   |
//+------------------------------------------------------------------+
#property copyright "4i2o"
#property link      ""
#property version   "1.1"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Chandelier Exit Settings ==="
input int      CE_ATR_Period       = 10;       // ATR Period
input double   CE_ATR_Multiplier   = 3.2;      // ATR Multiplier
input bool     CE_UseClosePrice    = true;     // Use Close Price for Extremums

input group "=== RSI Settings ==="
input int      RSI_Period          = 14;       // RSI Period
input double   RSI_Threshold       = 50.0;     // RSI Threshold

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
datetime g_lastBarTime = 0;
int      g_atrHandle   = INVALID_HANDLE;
int      g_rsiHandle   = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize ATR indicator handle
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, CE_ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR indicator handle");
      return(INIT_FAILED);
   }

   // Initialize RSI indicator handle
   g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("Error creating RSI indicator handle");
      return(INIT_FAILED);
   }

   // Initialize random seed
   MathSrand((int)TimeCurrent());

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
   // Check for new bar - execute logic only at the beginning of a new candle
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime)
      return;

   g_lastBarTime = currentBarTime;

   // Calculate Chandelier Exit direction for bars 1 and 2 (previous closed candles)
   int dir1 = 0, dir2 = 0;
   bool buySignal = false, sellSignal = false;

   if(!CalculateChandelierExit(dir1, dir2, buySignal, sellSignal))
      return;

   // Get RSI value from previous closed candle (bar index 1)
   double rsiValue = GetRSI(1);
   if(rsiValue < 0)
      return;

   // Check if we have an open position
   bool hasPosition = HasOpenPosition();

   // Handle opposite signal closing
   if(hasPosition && CloseOnOppositeSignal)
   {
      int positionType = GetPositionType();

      // Close BUY on SELL signal
      if(positionType == POSITION_TYPE_BUY && sellSignal)
      {
         CloseAllPositions();
         hasPosition = false;
      }
      // Close SELL on BUY signal
      else if(positionType == POSITION_TYPE_SELL && buySignal)
      {
         CloseAllPositions();
         hasPosition = false;
      }
   }

   // No new trades if we already have a position
   if(hasPosition)
      return;

   // Check entry conditions
   // BUY: CE buy signal confirmed + RSI > 50
   if(buySignal && rsiValue > RSI_Threshold)
   {
      OpenTrade(ORDER_TYPE_BUY);
   }
   // SELL: CE sell signal confirmed + RSI < 50
   else if(sellSignal && rsiValue < RSI_Threshold)
   {
      OpenTrade(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Calculate Chandelier Exit                                         |
//+------------------------------------------------------------------+
bool CalculateChandelierExit(int &dir1, int &dir2, bool &buySignal, bool &sellSignal)
{
   // We need enough bars for calculation
   int barsRequired = CE_ATR_Period + 5;
   if(Bars(_Symbol, PERIOD_CURRENT) < barsRequired)
      return false;

   // Get ATR values
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_atrHandle, 0, 0, barsRequired, atrBuffer) < barsRequired)
      return false;

   // Get price data
   double closeBuffer[], highBuffer[], lowBuffer[];
   ArraySetAsSeries(closeBuffer, true);
   ArraySetAsSeries(highBuffer, true);
   ArraySetAsSeries(lowBuffer, true);

   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsRequired, closeBuffer) < barsRequired)
      return false;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsRequired, highBuffer) < barsRequired)
      return false;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsRequired, lowBuffer) < barsRequired)
      return false;

   // Calculate Chandelier Exit for multiple bars to determine direction
   // We need to calculate direction for bars 1, 2, and 3 to get dir[1] and dir[2]

   double longStop[], shortStop[];
   int direction[];
   ArrayResize(longStop, barsRequired);
   ArrayResize(shortStop, barsRequired);
   ArrayResize(direction, barsRequired);

   // Initialize from oldest bar
   for(int i = barsRequired - 1; i >= 0; i--)
   {
      double atr = CE_ATR_Multiplier * atrBuffer[i];

      // Calculate highest high and lowest low over CE_ATR_Period
      double highestHigh = 0;
      double lowestLow = DBL_MAX;

      for(int j = i; j < i + CE_ATR_Period && j < barsRequired; j++)
      {
         if(CE_UseClosePrice)
         {
            if(closeBuffer[j] > highestHigh) highestHigh = closeBuffer[j];
            if(closeBuffer[j] < lowestLow) lowestLow = closeBuffer[j];
         }
         else
         {
            if(highBuffer[j] > highestHigh) highestHigh = highBuffer[j];
            if(lowBuffer[j] < lowestLow) lowestLow = lowBuffer[j];
         }
      }

      double currentLongStop = highestHigh - atr;
      double currentShortStop = lowestLow + atr;

      // Apply stop trailing logic
      if(i < barsRequired - 1)
      {
         double prevClose = closeBuffer[i + 1];
         double prevLongStop = longStop[i + 1];
         double prevShortStop = shortStop[i + 1];

         if(prevClose > prevLongStop)
            longStop[i] = MathMax(currentLongStop, prevLongStop);
         else
            longStop[i] = currentLongStop;

         if(prevClose < prevShortStop)
            shortStop[i] = MathMin(currentShortStop, prevShortStop);
         else
            shortStop[i] = currentShortStop;

         // Determine direction
         double close_current = closeBuffer[i];
         if(close_current > prevShortStop)
            direction[i] = 1;  // Long
         else if(close_current < prevLongStop)
            direction[i] = -1; // Short
         else
            direction[i] = direction[i + 1]; // Keep previous direction
      }
      else
      {
         longStop[i] = currentLongStop;
         shortStop[i] = currentShortStop;
         direction[i] = 1; // Default to long
      }
   }

   // Get direction values for bars 1 and 2 (previous closed candles)
   // Bar 0 is current (not closed), Bar 1 is last closed, Bar 2 is before that
   dir1 = direction[1]; // Direction at previous closed candle
   dir2 = direction[2]; // Direction at candle before that

   // Signal detection based on direction change at bar 1
   // BUY: dir[1] == 1 AND dir[2] == -1 (direction changed from -1 to 1)
   buySignal = (dir1 == 1 && dir2 == -1);

   // SELL: dir[1] == -1 AND dir[2] == 1 (direction changed from 1 to -1)
   sellSignal = (dir1 == -1 && dir2 == 1);

   return true;
}

//+------------------------------------------------------------------+
//| Get RSI value at specified bar                                    |
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
//| Check if there is an open position                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get position type                                                 |
//+------------------------------------------------------------------+
int GetPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            return (int)PositionGetInteger(POSITION_TYPE);
         }
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};

            request.action = TRADE_ACTION_DEAL;
            request.position = ticket;
            request.symbol = _Symbol;
            request.volume = PositionGetDouble(POSITION_VOLUME);
            request.deviation = 10;
            request.magic = MagicNumber;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               request.type = ORDER_TYPE_SELL;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            }
            else
            {
               request.type = ORDER_TYPE_BUY;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            }

            OrderSend(request, result);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Generate random value in range                                    |
//+------------------------------------------------------------------+
int RandomInRange(int minVal, int maxVal)
{
   return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
//| Open a trade                                                      |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Calculate random TP and SL in pips
   int tpPips = RandomInRange(TP_Min_Pips, TP_Max_Pips);
   int slPips = RandomInRange(SL_Min_Pips, SL_Max_Pips);

   // Convert pips to price - for 5-digit brokers, 1 pip = 10 points
   double pipValue = point * 10;
   if(digits == 3 || digits == 2) // JPY pairs or metals
      pipValue = point * 1;

   double price, sl, tp;

   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = NormalizeDouble(price - slPips * pipValue, digits);
      tp = NormalizeDouble(price + tpPips * pipValue, digits);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = NormalizeDouble(price + slPips * pipValue, digits);
      tp = NormalizeDouble(price - tpPips * pipValue, digits);
   }

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = orderType;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = ""; // Empty comment as requested
   request.type_filling = ORDER_FILLING_IOC;

   // Try ORDER_FILLING_FOK if IOC is not supported
   if(!OrderSend(request, result))
   {
      request.type_filling = ORDER_FILLING_FOK;
      if(!OrderSend(request, result))
      {
         request.type_filling = ORDER_FILLING_RETURN;
         OrderSend(request, result);
      }
   }
}

//+------------------------------------------------------------------+
