//+------------------------------------------------------------------+
//|                                           XAUUSD_CE_VIKAS_EA.mq5 |
//|                                        Copyright 2026, Partner   |
//|                                             XAUUSD M5 Strategy   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Partner"
#property link      ""
#property version   "1.05"
#property strict

//+------------------------------------------------------------------+
//| Include FIRST - before any CTrade usage                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

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
input int      InpSQZ_KCLength = 10;          // KC Length (IMPORTANT: 10!)
input double   InpSQZ_KCMult = 1.5;           // KC MultFactor

input group "=== RISK MANAGEMENT ==="
input int      InpSL_Buffer = 100;            // SL Buffer from CE line (pips)
input int      InpTP_Min = 188;               // Hard TP Min (pips) - for WEAK signals
input int      InpTP_Max = 212;               // Hard TP Max (pips) - for WEAK signals
input int      InpMaxArrowDistance = 2;       // Max candles between CE and VIKAS arrow

input group "=== TRADING HOURS ==="
input int      InpStartDay = 0;               // Start Day (0=Sunday)
input int      InpStartHour = 0;              // Start Hour
input int      InpStartMinute = 5;            // Start Minute
input int      InpEndDay = 5;                 // End Day (5=Friday)
input int      InpEndHour = 12;               // End Hour
input int      InpEndMinute = 0;              // End Minute

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

// VIKAS arrow tracking (stores candle index where arrow appeared)
int g_vikasArrowHistory[10];  // Last 10 arrows
ENUM_TRADE_DIRECTION g_vikasArrowDirHistory[10];
datetime g_vikasArrowTimeHistory[10];

// Candle tracking
datetime g_lastBarTime = 0;

// Trade object
CTrade trade;

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

   // Initialize VIKAS arrow history
   ArrayInitialize(g_vikasArrowHistory, -999);
   ArrayInitialize(g_vikasArrowDirHistory, TRADE_NONE);
   ArrayInitialize(g_vikasArrowTimeHistory, 0);

   // Check for existing position on init
   CheckExistingPosition();

   Print("=== XAUUSD CE VIKAS EA v1.05 Initialized ===");
   Print("Lot Size: ", InpLotSize);
   Print("SL Buffer: ", InpSL_Buffer, " pips");
   Print("TP Range: ", InpTP_Min, "-", InpTP_Max, " pips");
   Print("SQZMOM KC Length: ", InpSQZ_KCLength);
   Print("Trading Hours: ", DayToString(InpStartDay), " ", InpStartHour, ":", InpStartMinute,
         " - ", DayToString(InpEndDay), " ", InpEndHour, ":", InpEndMinute);

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

   // Check trading hours
   if(!IsTradingTime())
   {
      return;
   }

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
         g_lastCE_Direction = currentCE;
         // Continue to check for new trade
      }
   }

   // Update VIKAS arrow tracking FIRST
   UpdateVikasArrowHistory(shift);

   //--- STEP 2: Detect CE event and check confirmations on SAME candle
   ENUM_CE_DIRECTION currentCE = GetCE_Direction(shift);

   if(currentCE != g_lastCE_Direction && currentCE != CE_NONE)
   {
      Print(">>> CE Direction Change Detected: ", EnumToString(currentCE), " at candle ", shift);

      // CE is the BOSS - now check servants (VIKAS color and SQZMOM) on SAME candle
      int vikasTrend = GetVIKAS_Trend(shift);
      double sqzValue = GetSQZMOM_Value(shift);

      bool vikasConfirmed = false;
      bool sqzmomConfirmed = false;

      // Check VIKAS color
      if(currentCE == CE_BUY && vikasTrend == 1)
         vikasConfirmed = true;
      if(currentCE == CE_SELL && vikasTrend == -1)
         vikasConfirmed = true;

      // Check SQZMOM sign
      if(currentCE == CE_BUY && sqzValue > 0)
         sqzmomConfirmed = true;
      if(currentCE == CE_SELL && sqzValue < 0)
         sqzmomConfirmed = true;

      Print("SAME CANDLE Check - VIKAS Trend: ", vikasTrend, " (need ", (currentCE == CE_BUY ? "1" : "-1"), ") = ", vikasConfirmed);
      Print("SAME CANDLE Check - SQZMOM: ", sqzValue, " (need ", (currentCE == CE_BUY ? ">0" : "<0"), ") = ", sqzmomConfirmed);

      if(vikasConfirmed && sqzmomConfirmed && g_currentTrade == TRADE_NONE)
      {
         // Determine signal strength
         ENUM_SIGNAL_TYPE sigType = DetermineSignalType(shift, currentCE);

         Print("Signal Type: ", EnumToString(sigType));

         if(sigType != SIGNAL_NONE)
         {
            OpenTrade(currentCE, sigType);
         }
      }
      else if(!vikasConfirmed || !sqzmomConfirmed)
      {
         Print("Confirmation FAILED on same candle - VIKAS: ", vikasConfirmed, " SQZMOM: ", sqzmomConfirmed);
      }

      g_lastCE_Direction = currentCE;
   }

   //--- STEP 3: Manage open position (trailing for STRONG signals)
   if(g_currentTrade != TRADE_NONE && g_useTrailing)
   {
      ManageTrailingStop();
   }
}

//+------------------------------------------------------------------+
//| Check if within trading hours                                    |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int currentDay = dt.day_of_week;
   int currentMinutes = dt.hour * 60 + dt.min;

   int startMinutes = InpStartHour * 60 + InpStartMinute;
   int endMinutes = InpEndHour * 60 + InpEndMinute;

   // Saturday - no trading
   if(currentDay == 6)
      return false;

   // Sunday before start time
   if(currentDay == InpStartDay && currentMinutes < startMinutes)
      return false;

   // Friday after end time
   if(currentDay == InpEndDay && currentMinutes >= endMinutes)
      return false;

   // After Friday (Saturday handled above)
   if(currentDay > InpEndDay)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Convert day number to string                                     |
//+------------------------------------------------------------------+
string DayToString(int day)
{
   switch(day)
   {
      case 0: return "Sunday";
      case 1: return "Monday";
      case 2: return "Tuesday";
      case 3: return "Wednesday";
      case 4: return "Thursday";
      case 5: return "Friday";
      case 6: return "Saturday";
   }
   return "Unknown";
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
//| Update VIKAS Arrow History                                       |
//+------------------------------------------------------------------+
void UpdateVikasArrowHistory(int shift)
{
   int currentTrend = GetVIKAS_Trend(shift);
   int prevTrend = GetVIKAS_Trend(shift + 1);

   if(currentTrend != prevTrend)
   {
      // Shift history
      for(int i = 9; i > 0; i--)
      {
         g_vikasArrowHistory[i] = g_vikasArrowHistory[i-1];
         g_vikasArrowDirHistory[i] = g_vikasArrowDirHistory[i-1];
         g_vikasArrowTimeHistory[i] = g_vikasArrowTimeHistory[i-1];
      }

      // Store new arrow
      g_vikasArrowHistory[0] = shift;
      g_vikasArrowDirHistory[0] = (currentTrend == 1) ? TRADE_LONG : TRADE_SHORT;
      g_vikasArrowTimeHistory[0] = iTime(_Symbol, PERIOD_CURRENT, shift);

      Print("VIKAS Arrow detected at candle ", shift, " Direction: ", EnumToString(g_vikasArrowDirHistory[0]),
            " Time: ", TimeToString(g_vikasArrowTimeHistory[0]));
   }
}

//+------------------------------------------------------------------+
//| SQZMOM CALCULATION - LINEAR REGRESSION VERSION                   |
//+------------------------------------------------------------------+
double GetSQZMOM_Value(int shift)
{
   int len = InpSQZ_KCLength;  // KC Length = 10

   // Build array of source values for linear regression
   double source[];
   ArrayResize(source, len);

   for(int i = 0; i < len; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      double hh = GetHighest(PRICE_HIGH, len, shift + i);
      double ll = GetLowest(PRICE_LOW, len, shift + i);
      double sma = CalculateSMA(len, shift + i);

      double avg1 = (hh + ll) / 2.0;
      double avg2 = (avg1 + sma) / 2.0;

      source[i] = c - avg2;
   }

   // Calculate Linear Regression with offset 0
   double linregValue = CalculateLinReg(source, len, 0);

   return linregValue;
}

//+------------------------------------------------------------------+
//| Calculate Linear Regression                                      |
//+------------------------------------------------------------------+
double CalculateLinReg(double &source[], int length, int offset)
{
   // Linear regression formula: y = mx + b
   // We calculate the value at position 'offset' from the start

   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   int n = length;

   for(int i = 0; i < n; i++)
   {
      double x = i;
      double y = source[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
   }

   double slope = 0;
   double intercept = 0;

   double denom = n * sumX2 - sumX * sumX;
   if(MathAbs(denom) > 0.0000001)
   {
      slope = (n * sumXY - sumX * sumY) / denom;
      intercept = (sumY - slope * sumX) / n;
   }
   else
   {
      intercept = sumY / n;
   }

   // Return value at offset position (offset 0 = most recent)
   return intercept + slope * offset;
}

//+------------------------------------------------------------------+
//| Determine Signal Type (STRONG or WEAK)                           |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE DetermineSignalType(int ceShift, ENUM_CE_DIRECTION ceDirection)
{
   // Find nearest VIKAS arrow in the same direction
   datetime ceTime = iTime(_Symbol, PERIOD_CURRENT, ceShift);

   for(int i = 0; i < 10; i++)
   {
      if(g_vikasArrowHistory[i] < 0)
         continue;

      // Check direction match
      bool dirMatch = false;
      if(ceDirection == CE_BUY && g_vikasArrowDirHistory[i] == TRADE_LONG)
         dirMatch = true;
      if(ceDirection == CE_SELL && g_vikasArrowDirHistory[i] == TRADE_SHORT)
         dirMatch = true;

      if(!dirMatch)
         continue;

      // Calculate distance in candles
      int distance = MathAbs(ceShift - g_vikasArrowHistory[i]);

      Print("Found VIKAS arrow at distance ", distance, " candles, Direction: ", EnumToString(g_vikasArrowDirHistory[i]));

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
   }

   // No arrow found within range - default to WEAK
   Print("No matching VIKAS arrow within ", InpMaxArrowDistance, " candles - defaulting to WEAK");
   return SIGNAL_WEAK;
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

         Print("Existing position found: ", EnumToString(g_currentTrade));
      }
   }
}
//+------------------------------------------------------------------+
