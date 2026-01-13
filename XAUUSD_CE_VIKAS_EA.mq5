//+------------------------------------------------------------------+
//|                                           XAUUSD_CE_VIKAS_EA.mq5 |
//|                                        Copyright 2026, Partner   |
//|                              XAUUSD / XAGUSD / BTCUSD M5 Strategy |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Partner"
#property link      ""
#property version   "1.19"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_TYPE { SIGNAL_NONE=0, SIGNAL_STRONG=1, SIGNAL_WEAK=2 };
enum ENUM_TRADE_DIRECTION { TRADE_NONE=0, TRADE_LONG=1, TRADE_SHORT=-1 };
enum ENUM_INSTRUMENT_TYPE { INSTRUMENT_UNKNOWN=0, INSTRUMENT_XAUUSD=1, INSTRUMENT_XAGUSD=2, INSTRUMENT_BTCUSD=3 };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS - MATCHED TO TRADINGVIEW                        |
//+------------------------------------------------------------------+
input group "=== GENERAL ==="
input double InpLotSize = 0.1;
input int    InpMagicNumber = 123456;
input int    InpSlippage = 30;

input group "=== CHANDELIER EXIT (TV: 10, 3) ==="
input int    InpCE_Period = 10;           // CE Period (TV default: 10)
input double InpCE_Multiplier = 3.0;      // CE Multiplier (TV default: 3)
input bool   InpCE_UseClose = true;       // Use Close for extremums

input group "=== VIKAS SUPERTREND (TV: 18, 2.8) ==="
input int    InpVIKAS_Period = 18;        // VIKAS Period (TV default: 18)
input double InpVIKAS_Multiplier = 2.8;   // VIKAS Multiplier (TV default: 2.8)

input group "=== SQZMOM (TV: KC=10) ==="
input int    InpSQZ_KCLength = 10;        // KC Length (TV default: 10)
input double InpSQZ_MinThreshold = 0.5;   // Min SQZMOM (0.5 for XAU, 50 for BTC)

input group "=== RISK ==="
input int    InpSL_Buffer = 100;
input int    InpTP_Min = 188;
input int    InpTP_Max = 212;
input int    InpMaxArrowDistance = 2;
input int    InpBreakEvenPips = 50;        // Pips profit to move SL to BE (0=off)
input int    InpBreakEvenOffset = 5;       // Pips above/below entry for BE

input group "=== TRADING HOURS ==="
input int    InpStartDay = 0;
input int    InpStartHour = 0;
input int    InpStartMinute = 5;
input int    InpEndDay = 5;
input int    InpEndHour = 12;
input int    InpEndMinute = 0;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
ENUM_TRADE_DIRECTION g_currentTrade = TRADE_NONE;
ENUM_SIGNAL_TYPE g_signalType = SIGNAL_NONE;
double g_entryPrice = 0, g_currentSL = 0, g_currentTP = 0;
bool g_useTrailing = false;
bool g_breakEvenApplied = false;
int g_lastTradeCE = 0;  // CE direction of last trade (prevents re-entry without new CE)
datetime g_lastBarTime = 0;
CTrade trade;

ENUM_INSTRUMENT_TYPE g_instrumentType = INSTRUMENT_UNKNOWN;
int g_pipMultiplier = 10;
string g_instrumentName = "";

// INDICATOR ARRAYS
int g_historySize = 300;
int g_CE_Dir[];
double g_CE_LongStop[];
double g_CE_ShortStop[];
int g_VIKAS_Trend[];
double g_VIKAS_Up[];
double g_VIKAS_Dn[];

// Arrow tracking
int g_vikasArrowShift[10];
int g_vikasArrowDir[10];

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   DetectInstrument();

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   ArrayResize(g_CE_Dir, g_historySize);
   ArrayResize(g_CE_LongStop, g_historySize);
   ArrayResize(g_CE_ShortStop, g_historySize);
   ArrayResize(g_VIKAS_Trend, g_historySize);
   ArrayResize(g_VIKAS_Up, g_historySize);
   ArrayResize(g_VIKAS_Dn, g_historySize);

   ArrayInitialize(g_vikasArrowShift, -999);
   ArrayInitialize(g_vikasArrowDir, 0);

   RecalculateIndicators();
   CheckExistingPosition();

   Print("=== CE VIKAS EA v1.19 ===");
   Print("Instrument: ", g_instrumentName, " PipMult: ", g_pipMultiplier);
   Print("CE Period: ", InpCE_Period, " Mult: ", InpCE_Multiplier);
   Print("VIKAS Period: ", InpVIKAS_Period, " Mult: ", InpVIKAS_Multiplier);
   Print("SQZMOM KC: ", InpSQZ_KCLength);
   Print("CE[1]=", g_CE_Dir[1], " CE[2]=", g_CE_Dir[2]);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| RECALCULATE ALL INDICATORS                                       |
//+------------------------------------------------------------------+
void RecalculateIndicators()
{
   int bars = MathMin(iBars(_Symbol, PERIOD_CURRENT), g_historySize);

   int startBar = bars - 1;
   g_CE_Dir[startBar] = 1;
   g_CE_LongStop[startBar] = 0;
   g_CE_ShortStop[startBar] = 0;
   g_VIKAS_Trend[startBar] = 1;
   g_VIKAS_Up[startBar] = 0;
   g_VIKAS_Dn[startBar] = 0;

   for(int shift = startBar - 1; shift >= 0; shift--)
   {
      CalcCE_AtBar(shift);
      CalcVIKAS_AtBar(shift);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE CE AT SPECIFIC BAR                                     |
//+------------------------------------------------------------------+
void CalcCE_AtBar(int shift)
{
   if(shift < 0 || shift >= g_historySize - 1) return;

   double atr = 0;
   for(int i = 0; i < InpCE_Period; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      double l = iLow(_Symbol, PERIOD_CURRENT, shift + i);
      double pc = iClose(_Symbol, PERIOD_CURRENT, shift + i + 1);
      atr += MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
   }
   atr /= InpCE_Period;
   double atrMult = InpCE_Multiplier * atr;

   double highest = -DBL_MAX, lowest = DBL_MAX;
   for(int i = 0; i < InpCE_Period; i++)
   {
      double val = InpCE_UseClose ? iClose(_Symbol, PERIOD_CURRENT, shift + i)
                                  : iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      if(val > highest) highest = val;

      val = InpCE_UseClose ? iClose(_Symbol, PERIOD_CURRENT, shift + i)
                           : iLow(_Symbol, PERIOD_CURRENT, shift + i);
      if(val < lowest) lowest = val;
   }

   double longStop = highest - atrMult;
   double shortStop = lowest + atrMult;

   double prevLongStop = g_CE_LongStop[shift + 1];
   double prevShortStop = g_CE_ShortStop[shift + 1];
   int prevDir = g_CE_Dir[shift + 1];
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);

   if(prevLongStop > 0 && prevClose > prevLongStop)
      longStop = MathMax(longStop, prevLongStop);

   if(prevShortStop > 0 && prevClose < prevShortStop)
      shortStop = MathMin(shortStop, prevShortStop);

   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Direction change - MUST match TradingView's ternary logic exactly:
   // dir := close > shortStopPrev ? 1 : close < longStopPrev ? -1 : dir
   int dir;
   if(close > prevShortStop)
      dir = 1;   // Bullish - this check comes FIRST (like TradingView)
   else if(close < prevLongStop)
      dir = -1;  // Bearish - only if not already bullish
   else
      dir = prevDir;  // No change

   g_CE_LongStop[shift] = longStop;
   g_CE_ShortStop[shift] = shortStop;
   g_CE_Dir[shift] = dir;
}

//+------------------------------------------------------------------+
//| CALCULATE VIKAS AT SPECIFIC BAR                                  |
//+------------------------------------------------------------------+
void CalcVIKAS_AtBar(int shift)
{
   if(shift < 0 || shift >= g_historySize - 1) return;

   double atr = 0;
   for(int i = 0; i < InpVIKAS_Period; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      double l = iLow(_Symbol, PERIOD_CURRENT, shift + i);
      double pc = iClose(_Symbol, PERIOD_CURRENT, shift + i + 1);
      atr += MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
   }
   atr /= InpVIKAS_Period;

   // VIKAS uses LOW as source (not HL2!) - matching TradingView settings
   double src = iLow(_Symbol, PERIOD_CURRENT, shift);
   double up = src - InpVIKAS_Multiplier * atr;
   double dn = src + InpVIKAS_Multiplier * atr;

   double prevUp = g_VIKAS_Up[shift + 1];
   double prevDn = g_VIKAS_Dn[shift + 1];
   int prevTrend = g_VIKAS_Trend[shift + 1];
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);

   if(prevUp > 0 && prevClose > prevUp)
      up = MathMax(up, prevUp);

   if(prevDn > 0 && prevClose < prevDn)
      dn = MathMin(dn, prevDn);

   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   int trend = prevTrend;
   if(prevTrend == 1)
   {
      if(close < prevUp)
         trend = -1;
   }
   else
   {
      if(close > prevDn)
         trend = 1;
   }

   g_VIKAS_Up[shift] = up;
   g_VIKAS_Dn[shift] = dn;
   g_VIKAS_Trend[shift] = trend;
}

//+------------------------------------------------------------------+
//| SQZMOM CALCULATION                                               |
//+------------------------------------------------------------------+
double GetSQZMOM(int shift)
{
   int len = InpSQZ_KCLength;
   double source[];
   ArrayResize(source, len);

   for(int i = 0; i < len; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);

      double hh = -DBL_MAX, ll = DBL_MAX;
      for(int j = 0; j < len; j++)
      {
         double h = iHigh(_Symbol, PERIOD_CURRENT, shift + i + j);
         double l = iLow(_Symbol, PERIOD_CURRENT, shift + i + j);
         if(h > hh) hh = h;
         if(l < ll) ll = l;
      }

      double sma = 0;
      for(int j = 0; j < len; j++)
         sma += iClose(_Symbol, PERIOD_CURRENT, shift + i + j);
      sma /= len;

      source[i] = c - ((hh + ll) / 2.0 + sma) / 2.0;
   }

   double sumX=0, sumY=0, sumXY=0, sumX2=0;
   for(int i = 0; i < len; i++)
   {
      double x = (double)(len - 1 - i);
      sumX += x;
      sumY += source[i];
      sumXY += x * source[i];
      sumX2 += x * x;
   }

   double denom = len * sumX2 - sumX * sumX;
   if(MathAbs(denom) < 0.0000001) return sumY / len;

   double slope = (len * sumXY - sumX * sumY) / denom;
   double intercept = (sumY - slope * sumX) / len;

   return intercept + slope * (len - 1);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // BREAK EVEN & TRAILING - check on EVERY TICK!
   if(g_currentTrade != TRADE_NONE)
   {
      CheckBreakEven();  // Check break-even first

      if(g_useTrailing)
      {
         RecalculateIndicators();  // Need fresh CE values
         ManageTrailing();
      }
   }

   // Signal checking - only on new bar
   if(!IsNewBar()) return;
   if(!IsTradingTime()) return;

   RecalculateIndicators();

   int shift = 1;

   int currCE = g_CE_Dir[shift];
   int prevCE = g_CE_Dir[shift + 1];
   int currVIKAS = g_VIKAS_Trend[shift];
   int prevVIKAS = g_VIKAS_Trend[shift + 1];
   double sqz = GetSQZMOM(shift);

   // Close on opposite CE
   if(g_currentTrade != TRADE_NONE)
   {
      if((g_currentTrade == TRADE_LONG && currCE == -1) ||
         (g_currentTrade == TRADE_SHORT && currCE == 1))
      {
         Print(">>> OPPOSITE CE - Closing position");
         ClosePosition();
      }
   }

   // When CE flips, reset lastTradeCE to allow new entry
   if(currCE != prevCE)
   {
      Print(">>> CE FLIP: ", prevCE, " -> ", currCE, " (resetting lastTradeCE)");
      g_lastTradeCE = 0;  // Allow trading on this new CE direction
   }

   // Track VIKAS arrows for STRONG/WEAK signal detection
   if(currVIKAS != prevVIKAS)
   {
      for(int i = 9; i > 0; i--)
      {
         g_vikasArrowShift[i] = g_vikasArrowShift[i-1];
         g_vikasArrowDir[i] = g_vikasArrowDir[i-1];
      }
      g_vikasArrowShift[0] = shift;
      g_vikasArrowDir[0] = currVIKAS;
      Print("VIKAS Arrow at shift ", shift, " dir: ", currVIKAS);
   }

   // DEBUG: Log values every bar
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, shift);
   Print("BAR: CE=", currCE, " VIKAS=", currVIKAS, " SQZMOM=", DoubleToString(sqz, 2), " Close=", closePrice);

   // === LOGIC: Open trade when ALL indicators align AND new CE direction ===
   if(g_currentTrade == TRADE_NONE)
   {
      // Must be NEW CE direction (different from last trade)
      bool newCE = (currCE != g_lastTradeCE);

      // ALL GREEN = LONG
      bool allLong = (currCE == 1) && (currVIKAS == 1) && (sqz > InpSQZ_MinThreshold);

      // ALL RED = SHORT
      bool allShort = (currCE == -1) && (currVIKAS == -1) && (sqz < -InpSQZ_MinThreshold);

      if(allLong && newCE)
      {
         Print("========================================");
         Print(">>> ALL GREEN + NEW CE - Opening LONG");
         Print("    CE=", currCE, " VIKAS=", currVIKAS, " SQZMOM=", DoubleToString(sqz, 2));
         ENUM_SIGNAL_TYPE sigType = GetSignalType(shift, 1);
         Print("    Signal: ", EnumToString(sigType));
         OpenTrade(1, sigType);
         g_lastTradeCE = 1;  // Remember we traded on this CE
         Print("========================================");
      }
      else if(allShort && newCE)
      {
         Print("========================================");
         Print(">>> ALL RED + NEW CE - Opening SHORT");
         Print("    CE=", currCE, " VIKAS=", currVIKAS, " SQZMOM=", DoubleToString(sqz, 2));
         ENUM_SIGNAL_TYPE sigType = GetSignalType(shift, -1);
         Print("    Signal: ", EnumToString(sigType));
         OpenTrade(-1, sigType);
         g_lastTradeCE = -1;  // Remember we traded on this CE
         Print("========================================");
      }
      else if((allLong || allShort) && !newCE)
      {
         Print("SKIP: All aligned but waiting for new CE (lastCE=", g_lastTradeCE, ")");
      }
   }
   // Trailing is now handled at the start of OnTick() on every tick
}

//+------------------------------------------------------------------+
//| Get Signal Type                                                  |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE GetSignalType(int ceShift, int ceDir)
{
   for(int i = 0; i < 10; i++)
   {
      if(g_vikasArrowShift[i] < 0) continue;
      if(g_vikasArrowDir[i] != ceDir) continue;

      int dist = MathAbs(ceShift - g_vikasArrowShift[i]);
      if(dist == 0) return SIGNAL_STRONG;
      if(dist <= InpMaxArrowDistance) return SIGNAL_WEAK;
   }
   return SIGNAL_WEAK;
}

//+------------------------------------------------------------------+
//| Open Trade                                                       |
//+------------------------------------------------------------------+
void OpenTrade(int direction, ENUM_SIGNAL_TYPE sigType)
{
   if(g_currentTrade != TRADE_NONE) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = point * g_pipMultiplier;
   double slBuf = InpSL_Buffer * pipVal;

   double ceStop = (direction == 1) ? g_CE_LongStop[1] : g_CE_ShortStop[1];
   double price, sl, tp;

   if(direction == 1)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = ceStop - slBuf;

      if(sigType == SIGNAL_STRONG)
      {
         tp = 0;
         g_useTrailing = true;
      }
      else
      {
         int rtp = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);
         tp = price + rtp * pipVal;
         g_useTrailing = false;
      }

      sl = NormalizeDouble(sl, digits);
      tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0;

      Print(">>> LONG: Price=", price, " SL=", sl, " TP=", tp);

      if(trade.Buy(InpLotSize, _Symbol, price, sl, tp, ""))
      {
         g_currentTrade = TRADE_LONG;
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_signalType = sigType;
         g_breakEvenApplied = false;
         Print(">>> LONG OPENED!");
      }
      else
         Print(">>> FAILED: ", GetLastError());
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = ceStop + slBuf;

      if(sigType == SIGNAL_STRONG)
      {
         tp = 0;
         g_useTrailing = true;
      }
      else
      {
         int rtp = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);
         tp = price - rtp * pipVal;
         g_useTrailing = false;
      }

      sl = NormalizeDouble(sl, digits);
      tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0;

      Print(">>> SHORT: Price=", price, " SL=", sl, " TP=", tp);

      if(trade.Sell(InpLotSize, _Symbol, price, sl, tp, ""))
      {
         g_currentTrade = TRADE_SHORT;
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_signalType = sigType;
         g_breakEvenApplied = false;
         Print(">>> SHORT OPENED!");
      }
      else
         Print(">>> FAILED: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing                                                  |
//+------------------------------------------------------------------+
datetime g_lastTrailLog = 0;  // Rate limit logging

void ManageTrailing()
{
   if(!g_useTrailing || g_currentTrade == TRADE_NONE) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = point * g_pipMultiplier;
   double slBuf = InpSL_Buffer * pipVal;

   double ceStop = (g_currentTrade == TRADE_LONG) ? g_CE_LongStop[1] : g_CE_ShortStop[1];
   double newSL;

   // Log every 30 seconds max
   bool shouldLog = (TimeCurrent() - g_lastTrailLog >= 30);

   if(g_currentTrade == TRADE_LONG)
   {
      newSL = NormalizeDouble(ceStop - slBuf, digits);
      if(shouldLog)
      {
         Print("TRAIL LONG: CE=", ceStop, " newSL=", newSL, " currSL=", g_currentSL);
         g_lastTrailLog = TimeCurrent();
      }
      if(newSL > g_currentSL)
      {
         Print(">>> TRAILING SL UP: ", g_currentSL, " -> ", newSL);
         if(ModifySL(newSL))
            g_currentSL = newSL;
      }
   }
   else
   {
      newSL = NormalizeDouble(ceStop + slBuf, digits);
      if(shouldLog)
      {
         Print("TRAIL SHORT: CE=", ceStop, " newSL=", newSL, " currSL=", g_currentSL);
         g_lastTrailLog = TimeCurrent();
      }
      if(newSL < g_currentSL)
      {
         Print(">>> TRAILING SL DOWN: ", g_currentSL, " -> ", newSL);
         if(ModifySL(newSL))
            g_currentSL = newSL;
      }
   }
}

//+------------------------------------------------------------------+
//| Check Break Even                                                 |
//+------------------------------------------------------------------+
void CheckBreakEven()
{
   if(g_breakEvenApplied || g_currentTrade == TRADE_NONE) return;
   if(InpBreakEvenPips <= 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipVal = point * g_pipMultiplier;
   double beThreshold = InpBreakEvenPips * pipVal;
   double beOffset = InpBreakEvenOffset * pipVal;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double currentPrice;
   double profit;

   if(g_currentTrade == TRADE_LONG)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      profit = currentPrice - g_entryPrice;

      if(profit >= beThreshold)
      {
         double newSL = NormalizeDouble(g_entryPrice + beOffset, digits);
         if(newSL > g_currentSL)
         {
            Print(">>> BREAK EVEN LONG: Entry=", g_entryPrice, " newSL=", newSL);
            if(ModifySL(newSL))
            {
               g_currentSL = newSL;
               g_breakEvenApplied = true;
            }
         }
      }
   }
   else if(g_currentTrade == TRADE_SHORT)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      profit = g_entryPrice - currentPrice;

      if(profit >= beThreshold)
      {
         double newSL = NormalizeDouble(g_entryPrice - beOffset, digits);
         if(newSL < g_currentSL)
         {
            Print(">>> BREAK EVEN SHORT: Entry=", g_entryPrice, " newSL=", newSL);
            if(ModifySL(newSL))
            {
               g_currentSL = newSL;
               g_breakEvenApplied = true;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify SL                                                        |
//+------------------------------------------------------------------+
bool ModifySL(double newSL)
{
   if(!PositionSelect(_Symbol)) return false;
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   double tp = PositionGetDouble(POSITION_TP);
   return trade.PositionModify(ticket, newSL, tp);
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
         Print(">>> Position Closed");
         g_currentTrade = TRADE_NONE;
         g_useTrailing = false;
      }
   }
   else
   {
      g_currentTrade = TRADE_NONE;
      g_useTrailing = false;
   }
}

//+------------------------------------------------------------------+
//| Detect Instrument                                                |
//+------------------------------------------------------------------+
void DetectInstrument()
{
   g_instrumentName = _Symbol;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      g_instrumentType = INSTRUMENT_XAUUSD;
      g_pipMultiplier = 10;  // XAUUSD: 1 pip = $0.10
   }
   else if(StringFind(_Symbol, "XAG") >= 0 || StringFind(_Symbol, "SILVER") >= 0)
   {
      g_instrumentType = INSTRUMENT_XAGUSD;
      g_pipMultiplier = 100;  // XAGUSD: typically 3 decimals, 1 pip = $0.001
   }
   else if(StringFind(_Symbol, "BTC") >= 0)
   {
      g_instrumentType = INSTRUMENT_BTCUSD;
      if(point >= 1.0) g_pipMultiplier = 1;
      else if(point >= 0.1) g_pipMultiplier = 10;
      else if(point >= 0.01) g_pipMultiplier = 100;
      else g_pipMultiplier = 1000;
   }
   else
   {
      g_instrumentType = INSTRUMENT_UNKNOWN;
      g_pipMultiplier = 10;
      Print("WARNING: Unknown instrument! EA optimized for XAU, XAG, BTC only.");
   }
}

//+------------------------------------------------------------------+
//| Check Trading Time                                               |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int day = dt.day_of_week;
   int mins = dt.hour * 60 + dt.min;

   if(day == 6) return false;
   if(day == InpStartDay && mins < InpStartHour * 60 + InpStartMinute) return false;
   if(day == InpEndDay && mins >= InpEndHour * 60 + InpEndMinute) return false;
   if(day > InpEndDay) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Check New Bar                                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check Existing Position                                          |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         g_currentTrade = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                          ? TRADE_LONG : TRADE_SHORT;
         g_currentSL = PositionGetDouble(POSITION_SL);
         g_currentTP = PositionGetDouble(POSITION_TP);
      }
   }
}

void OnDeinit(const int reason) { Print("=== EA Stopped ==="); }
//+------------------------------------------------------------------+
