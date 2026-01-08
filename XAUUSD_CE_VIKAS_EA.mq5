//+------------------------------------------------------------------+
//|                                           XAUUSD_CE_VIKAS_EA.mq5 |
//|                                        Copyright 2024, Partner   |
//|                                             XAUUSD M5 Strategy   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Trading Partner"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_TYPE
{
   SIGNAL_NONE = 0,    // No signal
   SIGNAL_STRONG = 1,  // CE + VIKAS arrow same candle
   SIGNAL_WEAK = 2     // CE + VIKAS arrow 1-2 candles apart
};

enum ENUM_CE_DIRECTION
{
   CE_NONE = 0,
   CE_BUY = 1,
   CE_SELL = -1
};

enum ENUM_TRADE_DIRECTION
{
   TRADE_NONE = 0,
   TRADE_LONG = 1,
   TRADE_SHORT = -1
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== GENERAL SETTINGS ==="
input double   InpLotSize = 0.1;              // Lot Size
input int      InpMagicNumber = 123456;       // Magic Number
input int      InpSlippage = 30;              // Slippage (points)

input group "=== CHANDELIER EXIT SETTINGS ==="
input int      InpCE_Period = 22;             // CE ATR Period
input double   InpCE_Multiplier = 3.0;        // CE ATR Multiplier
input bool     InpCE_UseClose = true;         // CE Use Close for Extremums

input group "=== VIKAS SUPERTREND SETTINGS ==="
input int      InpVIKAS_Period = 28;          // VIKAS ATR Period
input double   InpVIKAS_Multiplier = 5.0;     // VIKAS ATR Multiplier

input group "=== SQZMOM SETTINGS ==="
input int      InpSQZ_BBLength = 20;          // BB Length
input double   InpSQZ_BBMult = 2.0;           // BB MultFactor
input int      InpSQZ_KCLength = 20;          // KC Length
input double   InpSQZ_KCMult = 1.5;           // KC MultFactor

input group "=== RISK MANAGEMENT ==="
input int      InpSL_Buffer = 100;            // SL Buffer from CE line (pips)
input int      InpTP_Min = 188;               // Hard TP Min (pips) - for WEAK signals
input int      InpTP_Max = 212;               // Hard TP Max (pips) - for WEAK signals
input int      InpMaxArrowDistance = 2;       // Max candles between CE and VIKAS arrow

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
// Trade management
int g_ticket = 0;
ENUM_TRADE_DIRECTION g_currentTrade = TRADE_NONE;
ENUM_SIGNAL_TYPE g_signalType = SIGNAL_NONE;
double g_entryPrice = 0;
double g_currentSL = 0;
double g_currentTP = 0;
bool g_useTrailing = false;

// CE state tracking
ENUM_CE_DIRECTION g_lastCE_Direction = CE_NONE;
ENUM_CE_DIRECTION g_pendingCE_Direction = CE_NONE;
bool g_pendingConfirmation = false;
datetime g_pendingCE_Time = 0;
int g_pendingCE_CandleIndex = 0;

// VIKAS arrow tracking
int g_lastVikasArrowCandle = -999;
ENUM_TRADE_DIRECTION g_lastVikasArrowDirection = TRADE_NONE;

// Candle tracking
datetime g_lastBarTime = 0;

// Trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Include                                                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize CE direction
   g_lastCE_Direction = GetCE_Direction(1);

   Print("=== XAUUSD CE VIKAS EA Initialized ===");
   Print("Lot Size: ", InpLotSize);
   Print("SL Buffer: ", InpSL_Buffer, " pips");
   Print("TP Range: ", InpTP_Min, "-", InpTP_Max, " pips");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== XAUUSD CE VIKAS EA Stopped ===");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new candle
   if(!IsNewBar())
      return;

   // Get current bar index (1 = last closed candle)
   int shift = 1;

   //--- STEP 1: Check for opposite CE signal (CRITICAL - close immediately)
   if(g_currentTrade != TRADE_NONE)
   {
      ENUM_CE_DIRECTION currentCE = GetCE_Direction(shift);

      if((g_currentTrade == TRADE_LONG && currentCE == CE_SELL) ||
         (g_currentTrade == TRADE_SHORT && currentCE == CE_BUY))
      {
         Print(">>> OPPOSITE CE SIGNAL - Closing position immediately!");
         ClosePosition();

         // Store new CE as pending
         g_pendingCE_Direction = currentCE;
         g_pendingConfirmation = true;
         g_pendingCE_Time = iTime(_Symbol, PERIOD_CURRENT, shift);
         g_pendingCE_CandleIndex = 0;
         g_lastCE_Direction = currentCE;
         return;
      }
   }

   //--- STEP 2: Detect new CE event
   ENUM_CE_DIRECTION currentCE = GetCE_Direction(shift);

   if(currentCE != g_lastCE_Direction && currentCE != CE_NONE)
   {
      Print(">>> CE Direction Change Detected: ", EnumToString(currentCE));

      g_pendingCE_Direction = currentCE;
      g_pendingConfirmation = true;
      g_pendingCE_Time = iTime(_Symbol, PERIOD_CURRENT, shift);
      g_pendingCE_CandleIndex = 0;
      g_lastCE_Direction = currentCE;

      // Track VIKAS arrow
      CheckVikasArrow(shift);
   }

   //--- STEP 3: Check for N+1 confirmation
   if(g_pendingConfirmation && g_currentTrade == TRADE_NONE)
   {
      g_pendingCE_CandleIndex++;

      if(g_pendingCE_CandleIndex == 1)  // This is N+1 candle
      {
         // Check confirmation conditions
         bool vikasConfirmed = CheckVikasColor(shift, g_pendingCE_Direction);
         bool sqzmomConfirmed = CheckSQZMOM(shift, g_pendingCE_Direction);

         Print("N+1 Confirmation Check - VIKAS: ", vikasConfirmed, " SQZMOM: ", sqzmomConfirmed);

         if(vikasConfirmed && sqzmomConfirmed)
         {
            // Determine signal strength
            g_signalType = DetermineSignalType(shift);

            Print("Signal Type: ", EnumToString(g_signalType));

            if(g_signalType != SIGNAL_NONE)
            {
               OpenTrade(g_pendingCE_Direction, g_signalType);
            }
         }
         else
         {
            Print("Confirmation FAILED - Discarding CE event");
         }

         g_pendingConfirmation = false;
      }
   }

   //--- STEP 4: Manage open position (trailing for STRONG signals)
   if(g_currentTrade != TRADE_NONE && g_useTrailing)
   {
      ManageTrailingStop();
   }

   // Update VIKAS arrow tracking
   CheckVikasArrow(shift);
}

//+------------------------------------------------------------------+
//| Check if new bar formed                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| CHANDELIER EXIT CALCULATION                                      |
//+------------------------------------------------------------------+
ENUM_CE_DIRECTION GetCE_Direction(int shift)
{
   double atr = CalculateATR(InpCE_Period, shift);
   double atrValue = InpCE_Multiplier * atr;

   // Calculate Long Stop
   double highestHigh = InpCE_UseClose ?
                        GetHighest(PRICE_CLOSE, InpCE_Period, shift) :
                        GetHighest(PRICE_HIGH, InpCE_Period, shift);
   double longStop = highestHigh - atrValue;

   // Calculate Short Stop
   double lowestLow = InpCE_UseClose ?
                      GetLowest(PRICE_CLOSE, InpCE_Period, shift) :
                      GetLowest(PRICE_LOW, InpCE_Period, shift);
   double shortStop = lowestLow + atrValue;

   // Get previous values for comparison
   double prevLongStop = longStop;
   double prevShortStop = shortStop;

   if(shift + 1 < iBars(_Symbol, PERIOD_CURRENT))
   {
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);
      double prevHighestHigh = InpCE_UseClose ?
                               GetHighest(PRICE_CLOSE, InpCE_Period, shift + 1) :
                               GetHighest(PRICE_HIGH, InpCE_Period, shift + 1);
      double prevLowestLow = InpCE_UseClose ?
                             GetLowest(PRICE_CLOSE, InpCE_Period, shift + 1) :
                             GetLowest(PRICE_LOW, InpCE_Period, shift + 1);

      double prevATR = CalculateATR(InpCE_Period, shift + 1);
      double prevATRValue = InpCE_Multiplier * prevATR;

      prevLongStop = prevHighestHigh - prevATRValue;
      prevShortStop = prevLowestLow + prevATRValue;

      // Adjust stops based on previous close
      if(prevClose > prevLongStop)
         longStop = MathMax(longStop, prevLongStop);
      if(prevClose < prevShortStop)
         shortStop = MathMin(shortStop, prevShortStop);
   }

   // Determine direction
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Store CE line value for SL calculation
   static int lastDir = 1;

   if(close > shortStop)
      lastDir = 1;
   else if(close < longStop)
      lastDir = -1;

   return (lastDir == 1) ? CE_BUY : CE_SELL;
}

//+------------------------------------------------------------------+
//| Get CE Line Value (for SL calculation)                           |
//+------------------------------------------------------------------+
double GetCE_LineValue(int shift, ENUM_CE_DIRECTION direction)
{
   double atr = CalculateATR(InpCE_Period, shift);
   double atrValue = InpCE_Multiplier * atr;

   if(direction == CE_BUY)
   {
      double highestHigh = InpCE_UseClose ?
                           GetHighest(PRICE_CLOSE, InpCE_Period, shift) :
                           GetHighest(PRICE_HIGH, InpCE_Period, shift);
      return highestHigh - atrValue;
   }
   else
   {
      double lowestLow = InpCE_UseClose ?
                         GetLowest(PRICE_CLOSE, InpCE_Period, shift) :
                         GetLowest(PRICE_LOW, InpCE_Period, shift);
      return lowestLow + atrValue;
   }
}

//+------------------------------------------------------------------+
//| VIKAS SUPERTREND CALCULATION                                     |
//+------------------------------------------------------------------+
int GetVIKAS_Trend(int shift)
{
   double atr = CalculateATR(InpVIKAS_Period, shift);
   double src = (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift)) / 2.0;

   double up = src - InpVIKAS_Multiplier * atr;
   double dn = src + InpVIKAS_Multiplier * atr;

   // Get previous values
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);
   double prevUp = up;
   double prevDn = dn;

   if(shift + 1 < iBars(_Symbol, PERIOD_CURRENT))
   {
      double prevATR = CalculateATR(InpVIKAS_Period, shift + 1);
      double prevSrc = (iHigh(_Symbol, PERIOD_CURRENT, shift + 1) + iLow(_Symbol, PERIOD_CURRENT, shift + 1)) / 2.0;
      prevUp = prevSrc - InpVIKAS_Multiplier * prevATR;
      prevDn = prevSrc + InpVIKAS_Multiplier * prevATR;
   }

   // Adjust bands
   if(prevClose > prevUp)
      up = MathMax(up, prevUp);
   if(prevClose < prevDn)
      dn = MathMin(dn, prevDn);

   // Determine trend
   static int trend = 1;
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(trend == -1 && close > prevDn)
      trend = 1;
   else if(trend == 1 && close < prevUp)
      trend = -1;

   return trend;
}

//+------------------------------------------------------------------+
//| Check VIKAS Color (GREEN = bullish, RED = bearish)               |
//+------------------------------------------------------------------+
bool CheckVikasColor(int shift, ENUM_CE_DIRECTION ceDirection)
{
   int vikasTrend = GetVIKAS_Trend(shift);

   if(ceDirection == CE_BUY && vikasTrend == 1)
      return true;
   if(ceDirection == CE_SELL && vikasTrend == -1)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Check for VIKAS Arrow (trend change)                             |
//+------------------------------------------------------------------+
void CheckVikasArrow(int shift)
{
   int currentTrend = GetVIKAS_Trend(shift);
   int prevTrend = GetVIKAS_Trend(shift + 1);

   if(currentTrend != prevTrend)
   {
      g_lastVikasArrowCandle = shift;
      g_lastVikasArrowDirection = (currentTrend == 1) ? TRADE_LONG : TRADE_SHORT;
      Print("VIKAS Arrow detected at candle ", shift, " Direction: ", EnumToString(g_lastVikasArrowDirection));
   }
}

//+------------------------------------------------------------------+
//| SQZMOM CALCULATION                                               |
//+------------------------------------------------------------------+
double GetSQZMOM_Value(int shift)
{
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Calculate linear regression of (close - avg(avg(highest, lowest), sma))
   double highestHigh = GetHighest(PRICE_HIGH, InpSQZ_KCLength, shift);
   double lowestLow = GetLowest(PRICE_LOW, InpSQZ_KCLength, shift);
   double smaClose = CalculateSMA(InpSQZ_KCLength, shift);

   double avg1 = (highestHigh + lowestLow) / 2.0;
   double avg2 = (avg1 + smaClose) / 2.0;
   double val = close - avg2;

   // Simple approximation of linreg
   double sum = 0;
   for(int i = 0; i < InpSQZ_KCLength; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      double hh = GetHighest(PRICE_HIGH, InpSQZ_KCLength, shift + i);
      double ll = GetLowest(PRICE_LOW, InpSQZ_KCLength, shift + i);
      double sma = CalculateSMA(InpSQZ_KCLength, shift + i);
      double a1 = (hh + ll) / 2.0;
      double a2 = (a1 + sma) / 2.0;
      sum += (c - a2);
   }

   return sum / InpSQZ_KCLength;
}

//+------------------------------------------------------------------+
//| Check SQZMOM Confirmation                                        |
//+------------------------------------------------------------------+
bool CheckSQZMOM(int shift, ENUM_CE_DIRECTION ceDirection)
{
   double sqzValue = GetSQZMOM_Value(shift);

   if(ceDirection == CE_BUY && sqzValue > 0)
      return true;
   if(ceDirection == CE_SELL && sqzValue < 0)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Determine Signal Type (STRONG or WEAK)                           |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE DetermineSignalType(int shift)
{
   // Check distance between CE signal and VIKAS arrow
   int distance = MathAbs(shift - g_lastVikasArrowCandle);

   // Check if directions match
   bool directionsMatch = false;
   if(g_pendingCE_Direction == CE_BUY && g_lastVikasArrowDirection == TRADE_LONG)
      directionsMatch = true;
   if(g_pendingCE_Direction == CE_SELL && g_lastVikasArrowDirection == TRADE_SHORT)
      directionsMatch = true;

   if(!directionsMatch)
   {
      Print("Directions don't match - CE: ", EnumToString(g_pendingCE_Direction),
            " VIKAS: ", EnumToString(g_lastVikasArrowDirection));
      return SIGNAL_WEAK;  // Default to weak if no arrow match
   }

   if(distance == 0)
   {
      Print("STRONG SIGNAL - CE and VIKAS arrow on same candle");
      return SIGNAL_STRONG;
   }
   else if(distance <= InpMaxArrowDistance)
   {
      Print("WEAK SIGNAL - CE and VIKAS arrow ", distance, " candles apart");
      return SIGNAL_WEAK;
   }
   else
   {
      Print("Signal too weak - ", distance, " candles apart, max allowed: ", InpMaxArrowDistance);
      return SIGNAL_NONE;
   }
}

//+------------------------------------------------------------------+
//| Open Trade                                                       |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_CE_DIRECTION direction, ENUM_SIGNAL_TYPE signalType)
{
   if(g_currentTrade != TRADE_NONE)
   {
      Print("Already in a trade, skipping");
      return;
   }

   double price, sl, tp;
   double ceLineValue = GetCE_LineValue(1, direction);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Calculate SL buffer in price
   double slBuffer = InpSL_Buffer * point * 10;  // Convert pips to price

   if(direction == CE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = ceLineValue - slBuffer;  // CE line - 100 pips

      if(signalType == SIGNAL_STRONG)
      {
         tp = 0;  // No hard TP for strong signals
         g_useTrailing = true;
      }
      else
      {
         // Randomized TP for weak signals
         int randomTP = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);
         tp = price + randomTP * point * 10;
         g_useTrailing = false;
      }

      sl = NormalizeDouble(sl, digits);
      tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0;

      Print("Opening LONG - Price: ", price, " SL: ", sl, " TP: ", tp, " Trailing: ", g_useTrailing);

      if(trade.Buy(InpLotSize, _Symbol, price, sl, tp, "CE_VIKAS_LONG"))
      {
         g_currentTrade = TRADE_LONG;
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_signalType = signalType;
         Print(">>> LONG Position Opened Successfully!");
      }
      else
      {
         Print("Failed to open LONG: ", GetLastError());
      }
   }
   else if(direction == CE_SELL)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = ceLineValue + slBuffer;  // CE line + 100 pips

      if(signalType == SIGNAL_STRONG)
      {
         tp = 0;  // No hard TP for strong signals
         g_useTrailing = true;
      }
      else
      {
         // Randomized TP for weak signals
         int randomTP = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);
         tp = price - randomTP * point * 10;
         g_useTrailing = false;
      }

      sl = NormalizeDouble(sl, digits);
      tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0;

      Print("Opening SHORT - Price: ", price, " SL: ", sl, " TP: ", tp, " Trailing: ", g_useTrailing);

      if(trade.Sell(InpLotSize, _Symbol, price, sl, tp, "CE_VIKAS_SHORT"))
      {
         g_currentTrade = TRADE_SHORT;
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_signalType = signalType;
         Print(">>> SHORT Position Opened Successfully!");
      }
      else
      {
         Print("Failed to open SHORT: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!g_useTrailing || g_currentTrade == TRADE_NONE)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double slBuffer = InpSL_Buffer * point * 10;

   // Get current CE line value
   ENUM_CE_DIRECTION ceDir = (g_currentTrade == TRADE_LONG) ? CE_BUY : CE_SELL;
   double ceLineValue = GetCE_LineValue(1, ceDir);

   double newSL;

   if(g_currentTrade == TRADE_LONG)
   {
      newSL = ceLineValue - slBuffer;
      newSL = NormalizeDouble(newSL, digits);

      // SL only moves UP for LONG
      if(newSL > g_currentSL)
      {
         if(ModifyStopLoss(newSL))
         {
            Print("Trailing SL moved UP to: ", newSL);
            g_currentSL = newSL;
         }
      }
   }
   else if(g_currentTrade == TRADE_SHORT)
   {
      newSL = ceLineValue + slBuffer;
      newSL = NormalizeDouble(newSL, digits);

      // SL only moves DOWN for SHORT
      if(newSL < g_currentSL)
      {
         if(ModifyStopLoss(newSL))
         {
            Print("Trailing SL moved DOWN to: ", newSL);
            g_currentSL = newSL;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify Stop Loss                                                 |
//+------------------------------------------------------------------+
bool ModifyStopLoss(double newSL)
{
   if(!PositionSelect(_Symbol))
      return false;

   double currentTP = PositionGetDouble(POSITION_TP);
   ulong ticket = PositionGetInteger(POSITION_TICKET);

   return trade.PositionModify(ticket, newSL, currentTP);
}

//+------------------------------------------------------------------+
//| Close Position                                                   |
//+------------------------------------------------------------------+
void ClosePosition()
{
   if(PositionSelect(_Symbol))
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);

      if(trade.PositionClose(ticket))
      {
         Print(">>> Position Closed Successfully");
         ResetTradeState();
      }
      else
      {
         Print("Failed to close position: ", GetLastError());
      }
   }
   else
   {
      ResetTradeState();
   }
}

//+------------------------------------------------------------------+
//| Reset Trade State                                                |
//+------------------------------------------------------------------+
void ResetTradeState()
{
   g_currentTrade = TRADE_NONE;
   g_signalType = SIGNAL_NONE;
   g_entryPrice = 0;
   g_currentSL = 0;
   g_currentTP = 0;
   g_useTrailing = false;
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Calculate ATR                                                    |
//+------------------------------------------------------------------+
double CalculateATR(int period, int shift)
{
   double atr = 0;

   for(int i = 0; i < period; i++)
   {
      double high = iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      double low = iLow(_Symbol, PERIOD_CURRENT, shift + i);
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + i + 1);

      double tr = MathMax(high - low, MathMax(MathAbs(high - prevClose), MathAbs(low - prevClose)));
      atr += tr;
   }

   return atr / period;
}

//+------------------------------------------------------------------+
//| Calculate SMA                                                    |
//+------------------------------------------------------------------+
double CalculateSMA(int period, int shift)
{
   double sum = 0;

   for(int i = 0; i < period; i++)
   {
      sum += iClose(_Symbol, PERIOD_CURRENT, shift + i);
   }

   return sum / period;
}

//+------------------------------------------------------------------+
//| Get Highest Value                                                |
//+------------------------------------------------------------------+
double GetHighest(ENUM_APPLIED_PRICE priceType, int period, int shift)
{
   double highest = -DBL_MAX;

   for(int i = 0; i < period; i++)
   {
      double value;
      if(priceType == PRICE_CLOSE)
         value = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      else
         value = iHigh(_Symbol, PERIOD_CURRENT, shift + i);

      if(value > highest)
         highest = value;
   }

   return highest;
}

//+------------------------------------------------------------------+
//| Get Lowest Value                                                 |
//+------------------------------------------------------------------+
double GetLowest(ENUM_APPLIED_PRICE priceType, int period, int shift)
{
   double lowest = DBL_MAX;

   for(int i = 0; i < period; i++)
   {
      double value;
      if(priceType == PRICE_CLOSE)
         value = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      else
         value = iLow(_Symbol, PERIOD_CURRENT, shift + i);

      if(value < lowest)
         lowest = value;
   }

   return lowest;
}

//+------------------------------------------------------------------+
//| Check if position exists                                         |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(PositionSelect(_Symbol))
   {
      long posType = PositionGetInteger(POSITION_TYPE);
      long magic = PositionGetInteger(POSITION_MAGIC);

      if(magic == InpMagicNumber)
      {
         if(posType == POSITION_TYPE_BUY)
            g_currentTrade = TRADE_LONG;
         else
            g_currentTrade = TRADE_SHORT;

         g_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_currentSL = PositionGetDouble(POSITION_SL);
         g_currentTP = PositionGetDouble(POSITION_TP);
      }
   }
}
//+------------------------------------------------------------------+
