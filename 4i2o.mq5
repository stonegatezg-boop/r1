//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                         v2.0      |
//|                     EA for Chandelier Exit indicator signals      |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double InpLotSize = 0.01;  // Lot Size

//--- Global variables
CTrade trade;
datetime lastSignalTime = 0;
datetime pendingSignalTime = 0;
int pendingSignalType = 0;  // 1 = buy, -1 = sell
datetime pendingExecuteTime = 0;
double currentTargetProfit = 0;
double currentStopLoss = 0;
int currentPositionType = 0;  // 1 = buy, -1 = sell, 0 = none

//+------------------------------------------------------------------+
//| Get pip value for the symbol                                     |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // Forex pairs (5 or 3 digits)
   if(digits == 5 || digits == 3)
      return _Point * 10;

   // Forex pairs (4 or 2 digits)
   if(digits == 4 || digits == 2)
      return _Point;

   // Gold, Silver, Metals (2 digits typically)
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.1;

   if(StringFind(symbol, "XAG") >= 0 || StringFind(symbol, "SILVER") >= 0)
      return 0.01;

   if(StringFind(symbol, "XPD") >= 0 || StringFind(symbol, "XPT") >= 0)
      return 0.1;

   // Crypto
   if(StringFind(symbol, "BTC") >= 0)
      return 1.0;

   if(StringFind(symbol, "ETH") >= 0)
      return 0.1;

   // Default
   if(digits == 1)
      return _Point;

   return _Point * 10;
}

//+------------------------------------------------------------------+
//| Generate random integer in range [min, max]                      |
//+------------------------------------------------------------------+
int RandomRange(int min, int max)
{
   return min + (MathRand() % (max - min + 1));
}

//+------------------------------------------------------------------+
//| Generate random double in range [min, max]                       |
//+------------------------------------------------------------------+
double RandomRangeDouble(double min, double max)
{
   return min + (max - min) * MathRand() / 32767.0;
}

//+------------------------------------------------------------------+
//| Check if position exists for symbol                              |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get current position type                                        |
//+------------------------------------------------------------------+
int GetPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            return (type == POSITION_TYPE_BUY) ? 1 : -1;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get current position profit in pips                              |
//+------------------------------------------------------------------+
double GetPositionProfitPips()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double pipValue = GetPipValue();

            if(type == POSITION_TYPE_BUY)
               return (currentPrice - openPrice) / pipValue;
            else
               return (openPrice - currentPrice) / pipValue;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Close all positions for symbol                                   |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   bool result = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         ulong ticket = PositionGetTicket(i);
         if(!trade.PositionClose(ticket))
            result = false;
      }
   }
   if(result)
   {
      currentPositionType = 0;
      currentTargetProfit = 0;
   }
   return result;
}

//+------------------------------------------------------------------+
//| Check for CE arrow on specific candle                            |
//+------------------------------------------------------------------+
int CheckCESignal(datetime candleTime)
{
   string buyArrowName = "CE_BuyArrow_" + IntegerToString(candleTime);
   string sellArrowName = "CE_SellArrow_" + IntegerToString(candleTime);

   if(ObjectFind(0, buyArrowName) >= 0)
      return 1;

   if(ObjectFind(0, sellArrowName) >= 0)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double pipValue = GetPipValue();
   double slPips = RandomRange(1400, 1500);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - slPips * pipValue, _Digits);

   currentTargetProfit = RandomRange(96, 107);
   currentStopLoss = sl;

   trade.SetExpertMagicNumber(0);

   if(trade.Buy(InpLotSize, _Symbol, ask, sl, 0, ""))
   {
      currentPositionType = 1;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open sell position                                               |
//+------------------------------------------------------------------+
bool OpenSell()
{
   double pipValue = GetPipValue();
   double slPips = RandomRange(1400, 1500);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + slPips * pipValue, _Digits);

   currentTargetProfit = RandomRange(96, 107);
   currentStopLoss = sl;

   trade.SetExpertMagicNumber(0);

   if(trade.Sell(InpLotSize, _Symbol, bid, sl, 0, ""))
   {
      currentPositionType = -1;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   MathSrand((uint)TimeCurrent());
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize position tracking
   currentPositionType = GetPositionType();
   if(currentPositionType != 0)
   {
      currentTargetProfit = RandomRange(96, 107);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Get previous closed candle time
   datetime prevCandleTime = iTime(_Symbol, PERIOD_M5, 1);

   // Check if we have a pending signal to execute
   if(pendingSignalType != 0 && pendingExecuteTime > 0)
   {
      if(TimeCurrent() >= pendingExecuteTime)
      {
         // Verify signal still exists
         int verifySignal = CheckCESignal(pendingSignalTime);

         if(verifySignal == pendingSignalType && !HasOpenPosition())
         {
            if(pendingSignalType == 1)
               OpenBuy();
            else if(pendingSignalType == -1)
               OpenSell();
         }

         // Reset pending
         pendingSignalType = 0;
         pendingSignalTime = 0;
         pendingExecuteTime = 0;
      }
      return;
   }

   // Check for profit target exit
   if(HasOpenPosition())
   {
      double profitPips = GetPositionProfitPips();

      if(currentTargetProfit > 0 && profitPips >= currentTargetProfit)
      {
         CloseAllPositions();
         return;
      }

      // Check for opposite signal
      int signal = CheckCESignal(prevCandleTime);

      if(signal != 0 && signal != currentPositionType && prevCandleTime > lastSignalTime)
      {
         CloseAllPositions();
         lastSignalTime = prevCandleTime;

         // Set up pending signal for opposite direction
         pendingSignalType = signal;
         pendingSignalTime = prevCandleTime;
         pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
         return;
      }
   }

   // Check for new signal on previous closed candle
   if(prevCandleTime > lastSignalTime && !HasOpenPosition() && pendingSignalType == 0)
   {
      int signal = CheckCESignal(prevCandleTime);

      if(signal != 0)
      {
         lastSignalTime = prevCandleTime;
         pendingSignalType = signal;
         pendingSignalTime = prevCandleTime;
         pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
      }
   }
}
//+------------------------------------------------------------------+
