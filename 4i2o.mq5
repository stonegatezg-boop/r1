//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                         v3.0      |
//|          EA for CE signals filtered by VIKAS SuperTrend          |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double InpLotSize = 0.01;  // Lot Size

//--- Global variables
CTrade trade;
datetime lastSignalTime = 0;
datetime lastBarTime = 0;
datetime pendingSignalTime = 0;
int pendingSignalType = 0;  // 1 = buy, -1 = sell
datetime pendingExecuteTime = 0;
double currentTargetProfit = 0;
double currentStopLoss = 0;
int currentPositionType = 0;  // 1 = buy, -1 = sell, 0 = none

//+------------------------------------------------------------------+
//| Check if within trading hours (Sunday 00:01 - Friday 10:00)      |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   // Sunday = 0, Monday = 1, ..., Friday = 5, Saturday = 6

   // Saturday - no trading
   if(dt.day_of_week == 6)
      return false;

   // Sunday - after 00:01
   if(dt.day_of_week == 0)
      return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

   // Monday to Thursday - all day
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

   // Friday - before 10:00
   if(dt.day_of_week == 5)
      return (dt.hour < 10);

   return false;
}

//+------------------------------------------------------------------+
//| Get pip value for the symbol                                     |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(digits == 5 || digits == 3)
      return _Point * 10;

   if(digits == 4 || digits == 2)
      return _Point;

   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.1;

   if(StringFind(symbol, "XAG") >= 0 || StringFind(symbol, "SILVER") >= 0)
      return 0.01;

   if(StringFind(symbol, "XPD") >= 0 || StringFind(symbol, "XPT") >= 0)
      return 0.1;

   if(StringFind(symbol, "BTC") >= 0)
      return 1.0;

   if(StringFind(symbol, "ETH") >= 0)
      return 0.1;

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
//| Check VIKAS trend (1 = green/up, -1 = red/down)                  |
//+------------------------------------------------------------------+
int CheckVIKASTrend(datetime candleTime)
{
   // Check for VIKAS up trend line (green) at this candle time
   // VIKAS indicator plots UpTrendBuffer when trend == 1, DownTrendBuffer when trend == -1

   // We need to find objects or check buffer values
   // Since VIKAS draws lines, we check which line has a value at this time

   string upTrendName = "VIKAS_BuyArrow_" + IntegerToString(candleTime);
   string dnTrendName = "VIKAS_SellArrow_" + IntegerToString(candleTime);

   // If there's a recent buy arrow from VIKAS, trend is up
   if(ObjectFind(0, upTrendName) >= 0)
      return 1;

   // If there's a recent sell arrow from VIKAS, trend is down
   if(ObjectFind(0, dnTrendName) >= 0)
      return -1;

   // Check the line values directly by finding the plot objects
   // We need to read the indicator buffers instead
   // Let's check which line is visible (has non-empty value) at current bar

   int barIndex = iBarShift(_Symbol, PERIOD_M5, candleTime);
   if(barIndex < 0) barIndex = 0;

   // Find the VIKAS indicator on the chart and read its buffers
   // Buffer 0 = Up Trend (green), Buffer 1 = Down Trend (red)

   // Search for indicator by name
   int total = ChartIndicatorsTotal(0, 0);
   for(int i = 0; i < total; i++)
   {
      string name = ChartIndicatorName(0, 0, i);
      if(StringFind(name, "VIKAS") >= 0)
      {
         int handle = ChartIndicatorGet(0, 0, name);
         if(handle != INVALID_HANDLE)
         {
            double upValue[1], dnValue[1];

            if(CopyBuffer(handle, 0, barIndex, 1, upValue) > 0 &&
               CopyBuffer(handle, 1, barIndex, 1, dnValue) > 0)
            {
               // If up trend has value and down doesn't, trend is up (green)
               if(upValue[0] != EMPTY_VALUE && upValue[0] != 0 &&
                  (dnValue[0] == EMPTY_VALUE || dnValue[0] == 0))
                  return 1;

               // If down trend has value and up doesn't, trend is down (red)
               if(dnValue[0] != EMPTY_VALUE && dnValue[0] != 0 &&
                  (upValue[0] == EMPTY_VALUE || upValue[0] == 0))
                  return -1;
            }
         }
         break;
      }
   }

   // Default: no filter (allow trade)
   return 0;
}

//+------------------------------------------------------------------+
//| Check if new bar has formed                                      |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
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

   currentPositionType = GetPositionType();
   if(currentPositionType != 0)
   {
      currentTargetProfit = RandomRange(96, 107);
   }

   lastBarTime = iTime(_Symbol, PERIOD_M5, 0);

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
   // Check for profit target exit (can check every tick, anytime)
   if(HasOpenPosition())
   {
      double profitPips = GetPositionProfitPips();
      if(currentTargetProfit > 0 && profitPips >= currentTargetProfit)
      {
         CloseAllPositions();
         return;
      }
   }

   // Check if we have a pending signal to execute (after delay)
   if(pendingSignalType != 0 && pendingExecuteTime > 0)
   {
      if(TimeCurrent() >= pendingExecuteTime)
      {
         // Check trading hours before opening
         if(IsWithinTradingHours())
         {
            // Verify CE signal still exists
            int verifySignal = CheckCESignal(pendingSignalTime);

            // Verify VIKAS trend alignment
            int vikasTrend = CheckVIKASTrend(pendingSignalTime);

            if(verifySignal == pendingSignalType && !HasOpenPosition())
            {
               // Apply VIKAS filter
               bool canTrade = false;

               if(pendingSignalType == 1 && vikasTrend == 1)  // CE BUY + VIKAS GREEN
                  canTrade = true;
               else if(pendingSignalType == -1 && vikasTrend == -1)  // CE SELL + VIKAS RED
                  canTrade = true;
               else if(vikasTrend == 0)  // VIKAS not found, allow trade
                  canTrade = true;

               if(canTrade)
               {
                  if(pendingSignalType == 1)
                     OpenBuy();
                  else if(pendingSignalType == -1)
                     OpenSell();
               }
            }
         }

         // Reset pending
         pendingSignalType = 0;
         pendingSignalTime = 0;
         pendingExecuteTime = 0;
      }
      return;
   }

   // Only check for signals on NEW BAR
   if(!IsNewBar())
      return;

   // Get previous closed candle time
   datetime prevCandleTime = iTime(_Symbol, PERIOD_M5, 1);

   // Skip if already processed
   if(prevCandleTime <= lastSignalTime)
      return;

   int signal = CheckCESignal(prevCandleTime);

   if(signal == 0)
      return;

   lastSignalTime = prevCandleTime;

   // If we have an open position, check for opposite signal (can close anytime)
   if(HasOpenPosition())
   {
      if(signal != currentPositionType)
      {
         // Opposite signal - close position
         CloseAllPositions();

         // Only set up new trade if within trading hours
         if(IsWithinTradingHours())
         {
            pendingSignalType = signal;
            pendingSignalTime = prevCandleTime;
            pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
         }
      }
      return;
   }

   // No position - check trading hours before setting up entry
   if(!IsWithinTradingHours())
      return;

   // Set up pending entry with human delay
   pendingSignalType = signal;
   pendingSignalTime = prevCandleTime;
   pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
}
//+------------------------------------------------------------------+
