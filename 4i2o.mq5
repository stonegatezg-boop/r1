//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                         v3.1      |
//|          EA for CE signals filtered by VIKAS SuperTrend          |
//|          FIXED: Added MagicNumber filter (2026-02-17 Zagreb)     |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "3.10"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double InpLotSize = 0.01;        // Lot Size
input ulong  InpMagicNumber = 412000;  // Magic Number (NOVO!)

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

   if(dt.day_of_week == 6)
      return false;

   if(dt.day_of_week == 0)
      return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

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
//| Check if OUR position exists for symbol (FIXED - MagicNumber!)   |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)  // FIXED!
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get OUR position type (FIXED - MagicNumber!)                     |
//+------------------------------------------------------------------+
int GetPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)  // FIXED!
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            return (type == POSITION_TYPE_BUY) ? 1 : -1;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get OUR position profit in pips (FIXED - MagicNumber!)           |
//+------------------------------------------------------------------+
double GetPositionProfitPips()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)  // FIXED!
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
//| Close only OUR positions (FIXED - MagicNumber!)                  |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   bool result = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)  // FIXED!
         {
            if(!trade.PositionClose(ticket))
               result = false;
         }
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
   string upTrendName = "VIKAS_BuyArrow_" + IntegerToString(candleTime);
   string dnTrendName = "VIKAS_SellArrow_" + IntegerToString(candleTime);

   if(ObjectFind(0, upTrendName) >= 0)
      return 1;

   if(ObjectFind(0, dnTrendName) >= 0)
      return -1;

   int barIndex = iBarShift(_Symbol, PERIOD_M5, candleTime);
   if(barIndex < 0) barIndex = 0;

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
               if(upValue[0] != EMPTY_VALUE && upValue[0] != 0 &&
                  (dnValue[0] == EMPTY_VALUE || dnValue[0] == 0))
                  return 1;

               if(dnValue[0] != EMPTY_VALUE && dnValue[0] != 0 &&
                  (upValue[0] == EMPTY_VALUE || upValue[0] == 0))
                  return -1;
            }
         }
         break;
      }
   }

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

   trade.SetExpertMagicNumber(InpMagicNumber);  // FIXED!

   if(trade.Buy(InpLotSize, _Symbol, ask, sl, 0, "4i2o BUY"))
   {
      currentPositionType = 1;
      Print("4i2o v3.1 BUY: ", InpLotSize, " @ ", ask, " SL=", sl, " Target=", currentTargetProfit, " pips");
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

   trade.SetExpertMagicNumber(InpMagicNumber);  // FIXED!

   if(trade.Sell(InpLotSize, _Symbol, bid, sl, 0, "4i2o SELL"))
   {
      currentPositionType = -1;
      Print("4i2o v3.1 SELL: ", InpLotSize, " @ ", bid, " SL=", sl, " Target=", currentTargetProfit, " pips");
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
   trade.SetExpertMagicNumber(InpMagicNumber);  // FIXED!

   currentPositionType = GetPositionType();
   if(currentPositionType != 0)
   {
      currentTargetProfit = RandomRange(96, 107);
   }

   lastBarTime = iTime(_Symbol, PERIOD_M5, 0);

   Print("=== 4i2o v3.1 inicijaliziran (2026-02-17 Zagreb) ===");
   Print("MagicNumber: ", InpMagicNumber, " - SAMO svoje pozicije!");

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
         Print("4i2o v3.1: Target reached (", profitPips, " pips) - closing");
         CloseAllPositions();
         return;
      }
   }

   // Check if we have a pending signal to execute (after delay)
   if(pendingSignalType != 0 && pendingExecuteTime > 0)
   {
      if(TimeCurrent() >= pendingExecuteTime)
      {
         if(IsWithinTradingHours())
         {
            int verifySignal = CheckCESignal(pendingSignalTime);
            int vikasTrend = CheckVIKASTrend(pendingSignalTime);

            if(verifySignal == pendingSignalType && !HasOpenPosition())
            {
               bool canTrade = false;

               if(pendingSignalType == 1 && vikasTrend == 1)
                  canTrade = true;
               else if(pendingSignalType == -1 && vikasTrend == -1)
                  canTrade = true;
               else if(vikasTrend == 0)
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

         pendingSignalType = 0;
         pendingSignalTime = 0;
         pendingExecuteTime = 0;
      }
      return;
   }

   if(!IsNewBar())
      return;

   datetime prevCandleTime = iTime(_Symbol, PERIOD_M5, 1);

   if(prevCandleTime <= lastSignalTime)
      return;

   int signal = CheckCESignal(prevCandleTime);

   if(signal == 0)
      return;

   lastSignalTime = prevCandleTime;

   if(HasOpenPosition())
   {
      if(signal != currentPositionType)
      {
         Print("4i2o v3.1: Opposite signal - closing position");
         CloseAllPositions();

         if(IsWithinTradingHours())
         {
            pendingSignalType = signal;
            pendingSignalTime = prevCandleTime;
            pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
         }
      }
      return;
   }

   if(!IsWithinTradingHours())
      return;

   pendingSignalType = signal;
   pendingSignalTime = prevCandleTime;
   pendingExecuteTime = TimeCurrent() + RandomRange(1, 3);
}
//+------------------------------------------------------------------+
