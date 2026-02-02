//+------------------------------------------------------------------+
//|                                              Vikas+Stoch_EA.mq5   |
//|                                  Vikas+Stoch Expert Advisor v1.0  |
//|                                         Created: 2026-02-02 14:30 |
//+------------------------------------------------------------------+
#property copyright "Vikas+Stoch"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input double   LotSize           = 0.01;     // Lot Size
input int      MinHumanDelay     = 1000;     // Min Human Delay (ms)
input int      MaxHumanDelay     = 3000;     // Max Human Delay (ms)
input int      MinPipTarget      = 490;      // Min Pip Target (if candle against)
input int      MaxPipTarget      = 550;      // Max Pip Target (if candle against)
input int      MagicNumber       = 123456;   // Magic Number

//--- Global Variables
CTrade         trade;
datetime       lastBarTime       = 0;
datetime       processedSignalTime = 0;
bool           waitingForEntry   = false;
int            pendingSignalType = 0;        // 1=BUY, -1=SELL
datetime       pendingEntryTime  = 0;
double         pendingEntryDelay = 0;

bool           waitingForExit    = false;
datetime       pendingExitTime   = 0;
double         pendingExitDelay  = 0;

double         internalPipTarget = 0;
bool           candleMatchedSignal = false;
datetime       entryBarTime      = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   MathSrand((uint)TimeCurrent());

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Get pip value for the symbol                                       |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   //--- Forex pairs
   if(digits == 5 || digits == 3)
      return _Point * 10;

   //--- Gold, Silver, Metals (2 digits)
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.1;

   if(StringFind(symbol, "XAG") >= 0 || StringFind(symbol, "SILVER") >= 0)
      return 0.01;

   //--- Crypto
   if(StringFind(symbol, "BTC") >= 0)
      return 1.0;

   //--- Default
   return _Point;
}

//+------------------------------------------------------------------+
//| Get random delay between min and max                               |
//+------------------------------------------------------------------+
int GetRandomDelay(int minMs, int maxMs)
{
   return minMs + (MathRand() % (maxMs - minMs + 1));
}

//+------------------------------------------------------------------+
//| Get random pip target                                              |
//+------------------------------------------------------------------+
double GetRandomPipTarget()
{
   int pips = MinPipTarget + (MathRand() % (MaxPipTarget - MinPipTarget + 1));
   return pips * GetPipValue();
}

//+------------------------------------------------------------------+
//| Check if we have an open position                                  |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE &posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions for this symbol                                |
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
            trade.PositionClose(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get current position profit in price                               |
//+------------------------------------------------------------------+
double GetPositionProfitPrice()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            if(posType == POSITION_TYPE_BUY)
               return currentPrice - openPrice;
            else
               return openPrice - currentPrice;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Vikas signal arrows on previous bar                         |
//+------------------------------------------------------------------+
int DetectSignal(datetime prevBarTime)
{
   //--- Arrow names from VIKAS indicator: VIKAS_BuyArrow_<time> / VIKAS_SellArrow_<time>
   string buyArrowName = "VIKAS_BuyArrow_" + IntegerToString((long)prevBarTime);
   string sellArrowName = "VIKAS_SellArrow_" + IntegerToString((long)prevBarTime);

   if(ObjectFind(0, buyArrowName) >= 0)
      return 1;  // BUY signal

   if(ObjectFind(0, sellArrowName) >= 0)
      return -1; // SELL signal

   return 0;     // No signal
}

//+------------------------------------------------------------------+
//| Check if candle matches signal direction                           |
//+------------------------------------------------------------------+
bool DoesCandleMatchSignal(int signalType, int barIndex)
{
   double open = iOpen(_Symbol, PERIOD_CURRENT, barIndex);
   double close = iClose(_Symbol, PERIOD_CURRENT, barIndex);

   if(signalType == 1)  // BUY signal - need green candle (close > open)
      return (close > open);
   else if(signalType == -1)  // SELL signal - need red candle (close < open)
      return (close < open);

   return false;
}

//+------------------------------------------------------------------+
//| Execute pending entry                                              |
//+------------------------------------------------------------------+
void ExecutePendingEntry()
{
   if(!waitingForEntry)
      return;

   if(GetTickCount64() < pendingEntryTime + (ulong)pendingEntryDelay)
      return;

   //--- Check if we already have a position
   ENUM_POSITION_TYPE posType;
   if(HasOpenPosition(posType))
   {
      waitingForEntry = false;
      return;
   }

   //--- Get SL price (open of previous candle)
   double slPrice = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double entryPrice;

   //--- Normalize prices
   slPrice = NormalizeDouble(slPrice, _Digits);

   if(pendingSignalType == 1)  // BUY
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Make sure SL is below entry
      if(slPrice >= entryPrice)
         slPrice = entryPrice - 100 * _Point;

      slPrice = NormalizeDouble(slPrice, _Digits);

      if(trade.Buy(LotSize, _Symbol, entryPrice, slPrice, 0, ""))
      {
         entryBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
         internalPipTarget = GetRandomPipTarget();
         candleMatchedSignal = false;
      }
   }
   else if(pendingSignalType == -1)  // SELL
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      //--- Make sure SL is above entry
      if(slPrice <= entryPrice)
         slPrice = entryPrice + 100 * _Point;

      slPrice = NormalizeDouble(slPrice, _Digits);

      if(trade.Sell(LotSize, _Symbol, entryPrice, slPrice, 0, ""))
      {
         entryBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
         internalPipTarget = GetRandomPipTarget();
         candleMatchedSignal = false;
      }
   }

   waitingForEntry = false;
   pendingSignalType = 0;
}

//+------------------------------------------------------------------+
//| Execute pending exit                                               |
//+------------------------------------------------------------------+
void ExecutePendingExit()
{
   if(!waitingForExit)
      return;

   if(GetTickCount64() < pendingExitTime + (ulong)pendingExitDelay)
      return;

   CloseAllPositions();
   waitingForExit = false;
   candleMatchedSignal = false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Execute pending entry if waiting
   ExecutePendingEntry();

   //--- Execute pending exit if waiting
   ExecutePendingExit();

   //--- Get current bar time
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   //--- Check if new bar formed
   bool isNewBar = (currentBarTime != lastBarTime);

   if(isNewBar)
   {
      lastBarTime = currentBarTime;

      //--- Get previous bar time (the just closed bar)
      datetime prevBarTime = iTime(_Symbol, PERIOD_CURRENT, 1);

      //--- Check for signal on the closed bar
      int signal = DetectSignal(prevBarTime);

      //--- Check if we have an open position
      ENUM_POSITION_TYPE posType;
      bool hasPosition = HasOpenPosition(posType);

      //--- ENTRY LOGIC
      if(signal != 0 && prevBarTime != processedSignalTime)
      {
         processedSignalTime = prevBarTime;

         //--- If we have an opposite position, close it immediately
         if(hasPosition)
         {
            if((signal == 1 && posType == POSITION_TYPE_SELL) ||
               (signal == -1 && posType == POSITION_TYPE_BUY))
            {
               CloseAllPositions();
               hasPosition = false;
            }
         }

         //--- Set up pending entry with human delay
         if(!hasPosition && !waitingForEntry)
         {
            waitingForEntry = true;
            pendingSignalType = signal;
            pendingEntryTime = GetTickCount64();
            pendingEntryDelay = GetRandomDelay(MinHumanDelay, MaxHumanDelay);
         }
      }

      //--- EXIT LOGIC - Check if candle matches signal direction
      if(hasPosition && !waitingForExit)
      {
         int posSignal = (posType == POSITION_TYPE_BUY) ? 1 : -1;

         //--- Check the just closed candle (bar 1)
         if(DoesCandleMatchSignal(posSignal, 1))
         {
            //--- Candle matched signal direction - set up delayed exit
            waitingForExit = true;
            pendingExitTime = GetTickCount64();
            pendingExitDelay = GetRandomDelay(MinHumanDelay, MaxHumanDelay);
            candleMatchedSignal = true;
         }
      }
   }

   //--- CONTINUOUS EXIT MONITORING (pip target)
   ENUM_POSITION_TYPE posType;
   if(HasOpenPosition(posType) && !waitingForExit && !candleMatchedSignal)
   {
      double profitPrice = GetPositionProfitPrice();

      //--- Check if profit reached the internal pip target
      if(profitPrice >= internalPipTarget && internalPipTarget > 0)
      {
         CloseAllPositions();
      }
   }
}
//+------------------------------------------------------------------+
