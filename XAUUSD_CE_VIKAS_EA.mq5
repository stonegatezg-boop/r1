//+------------------------------------------------------------------+
//|                                           XAUUSD_CE_VIKAS_EA.mq5 |
//|                                        Copyright 2026, Partner   |
//|                              XAUUSD / XAGUSD / BTCUSD M5 Strategy |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Partner"
#property link      ""
#property version   "1.24"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== GENERAL ==="
input double InpLotSize = 0.2;
input int    InpMagicNumber = 123456;
input int    InpSlippage = 30;

input group "=== CHANDELIER EXIT ==="
input int    InpCE_Period = 10;
input double InpCE_Multiplier = 3.0;

input group "=== VIKAS SUPERTREND ==="
input int    InpVIKAS_Period = 18;
input double InpVIKAS_Multiplier = 2.8;
input bool   InpUseVIKAS = true;          // Use VIKAS filter? (false = only CE+SQZMOM)

input group "=== SQZMOM ==="
input int    InpSQZ_Length = 10;
input double InpSQZ_MinThreshold = 0.0;   // Min threshold (0 = any positive/negative)

input group "=== RISK ==="
input int    InpSL_Buffer = 100;
input int    InpTP_Min = 191;
input int    InpTP_Max = 214;
input int    InpBreakEvenPips = 50;
input int    InpBreakEvenOffset = 5;
input int    InpDelayMin = 2;
input int    InpDelayMax = 8;

input group "=== TRADING HOURS ==="
input bool   InpUseTradingHours = false;
input int    InpStartHour = 0;
input int    InpEndHour = 23;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIR { DIR_NONE=0, DIR_LONG=1, DIR_SHORT=-1 };

ENUM_TRADE_DIR g_currentTrade = DIR_NONE;
ulong g_positionTicket = 0;
double g_entryPrice = 0, g_currentSL = 0, g_currentTP = 0;
bool g_breakEvenApplied = false;
int g_lastTradeCE = 0;
int g_prevCE = 0;
datetime g_lastBarTime = 0;
CTrade trade;

// Pending signal (anti-bot mechanism)
int g_pendingSignal = 0;
datetime g_pendingTime = 0;
int g_delaySeconds = 0;

// Instrument settings
int g_pipMultiplier = 10;
string g_instrumentName = "";

// ATR Handles for better performance
int g_atrHandleCE = INVALID_HANDLE;
int g_atrHandleVIKAS = INVALID_HANDLE;

// Indicator arrays
int g_historySize = 500;
int g_CE_Dir[];
double g_CE_LongStop[];
double g_CE_ShortStop[];
int g_VIKAS_Dir[];
double g_VIKAS_Line[];

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   MathSrand((uint)TimeLocal());
   DetectInstrument();

   // Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Create ATR handles
   g_atrHandleCE = iATR(_Symbol, PERIOD_CURRENT, InpCE_Period);
   g_atrHandleVIKAS = iATR(_Symbol, PERIOD_CURRENT, InpVIKAS_Period);

   if(g_atrHandleCE == INVALID_HANDLE || g_atrHandleVIKAS == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handles!");
      return INIT_FAILED;
   }

   // Allocate arrays
   ArrayResize(g_CE_Dir, g_historySize);
   ArrayResize(g_CE_LongStop, g_historySize);
   ArrayResize(g_CE_ShortStop, g_historySize);
   ArrayResize(g_VIKAS_Dir, g_historySize);
   ArrayResize(g_VIKAS_Line, g_historySize);

   ArrayInitialize(g_CE_Dir, 0);
   ArrayInitialize(g_CE_LongStop, 0);
   ArrayInitialize(g_CE_ShortStop, 0);
   ArrayInitialize(g_VIKAS_Dir, 0);
   ArrayInitialize(g_VIKAS_Line, 0);

   // Wait for enough bars
   if(iBars(_Symbol, PERIOD_CURRENT) < g_historySize)
   {
      Print("WARNING: Not enough bars. Need ", g_historySize, " bars.");
   }

   // Calculate initial indicators
   RecalculateAll();
   CheckExistingPosition();

   // Initialize prevCE from bar 1
   g_prevCE = g_CE_Dir[1];

   Print("========================================");
   Print("=== CE VIKAS EA v1.24 STARTED ===");
   Print("Instrument: ", g_instrumentName);
   Print("PipMultiplier: ", g_pipMultiplier);
   Print("UseVIKAS: ", InpUseVIKAS);
   Print("SQZMOM Threshold: ", InpSQZ_MinThreshold);
   Print("CE: Period=", InpCE_Period, " Mult=", InpCE_Multiplier);
   Print("VIKAS: Period=", InpVIKAS_Period, " Mult=", InpVIKAS_Multiplier);
   Print("========================================");

   return(INIT_SUCCEEDED);
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
      g_pipMultiplier = 10;
   }
   else if(StringFind(_Symbol, "XAG") >= 0 || StringFind(_Symbol, "SILVER") >= 0)
   {
      g_pipMultiplier = 100;
   }
   else if(StringFind(_Symbol, "BTC") >= 0)
   {
      if(point >= 1.0) g_pipMultiplier = 1;
      else if(point >= 0.1) g_pipMultiplier = 10;
      else if(point >= 0.01) g_pipMultiplier = 100;
      else g_pipMultiplier = 1000;
   }
   else
   {
      g_pipMultiplier = 10;
   }
}

//+------------------------------------------------------------------+
//| Get ATR Value using handle                                       |
//+------------------------------------------------------------------+
double GetATR(int handle, int shift)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, shift, 1, atr) != 1)
      return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Recalculate All Indicators                                       |
//+------------------------------------------------------------------+
void RecalculateAll()
{
   int bars = MathMin(iBars(_Symbol, PERIOD_CURRENT), g_historySize - 1);
   if(bars < 50)
   {
      Print("WARNING: Not enough bars for calculation (", bars, ")");
      return;
   }

   // Initialize oldest bar
   int start = bars - 1;
   g_CE_Dir[start] = 1;
   g_CE_LongStop[start] = 0;
   g_CE_ShortStop[start] = 0;
   g_VIKAS_Dir[start] = 1;
   g_VIKAS_Line[start] = 0;

   // Calculate from oldest to newest
   for(int i = start - 1; i >= 0; i--)
   {
      CalcCE(i);
      CalcVIKAS(i);
   }
}

//+------------------------------------------------------------------+
//| Calculate Chandelier Exit (TradingView exact)                    |
//+------------------------------------------------------------------+
void CalcCE(int shift)
{
   if(shift < 0 || shift >= g_historySize - 1) return;

   double atr = GetATR(g_atrHandleCE, shift) * InpCE_Multiplier;
   if(atr <= 0) return;

   // Find highest/lowest close in period (UseClose=true)
   double highest = iClose(_Symbol, PERIOD_CURRENT, shift);
   double lowest = iClose(_Symbol, PERIOD_CURRENT, shift);
   for(int i = 1; i < InpCE_Period; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      if(c > highest) highest = c;
      if(c < lowest) lowest = c;
   }

   double longStop = highest - atr;
   double shortStop = lowest + atr;

   // Previous values
   double prevLongStop = g_CE_LongStop[shift + 1];
   double prevShortStop = g_CE_ShortStop[shift + 1];
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);
   int prevDir = g_CE_Dir[shift + 1];

   // Ratchet logic (stop can only move in favorable direction)
   if(prevLongStop > 0 && prevClose > prevLongStop)
      longStop = MathMax(longStop, prevLongStop);

   if(prevShortStop > 0 && prevClose < prevShortStop)
      shortStop = MathMin(shortStop, prevShortStop);

   // Direction based on close vs previous stops (TradingView logic)
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);
   int dir;

   if(close > prevShortStop && prevShortStop > 0)
      dir = 1;   // Bullish
   else if(close < prevLongStop && prevLongStop > 0)
      dir = -1;  // Bearish
   else
      dir = prevDir;  // No change

   g_CE_LongStop[shift] = longStop;
   g_CE_ShortStop[shift] = shortStop;
   g_CE_Dir[shift] = dir;
}

//+------------------------------------------------------------------+
//| Calculate VIKAS SuperTrend (Source=Low)                          |
//+------------------------------------------------------------------+
void CalcVIKAS(int shift)
{
   if(shift < 0 || shift >= g_historySize - 1) return;

   double atr = GetATR(g_atrHandleVIKAS, shift) * InpVIKAS_Multiplier;
   if(atr <= 0) return;

   // Source = Low (as per user TradingView settings)
   double src = iLow(_Symbol, PERIOD_CURRENT, shift);
   double upperBand = src + atr;
   double lowerBand = src - atr;

   int prevDir = g_VIKAS_Dir[shift + 1];
   double prevLine = g_VIKAS_Line[shift + 1];

   // First calculation - default uptrend
   if(prevDir == 0) prevDir = 1;
   if(prevLine <= 0) prevLine = lowerBand;

   double close = iClose(_Symbol, PERIOD_CURRENT, shift);
   int dir;
   double line;

   if(prevDir == 1)
   {
      // Was in uptrend - use lower band
      lowerBand = MathMax(lowerBand, prevLine);

      if(close < lowerBand)
      {
         dir = -1;       // Switch to downtrend
         line = upperBand;
      }
      else
      {
         dir = 1;        // Stay in uptrend
         line = lowerBand;
      }
   }
   else
   {
      // Was in downtrend - use upper band
      upperBand = MathMin(upperBand, prevLine);

      if(close > upperBand)
      {
         dir = 1;        // Switch to uptrend
         line = lowerBand;
      }
      else
      {
         dir = -1;       // Stay in downtrend
         line = upperBand;
      }
   }

   g_VIKAS_Dir[shift] = dir;
   g_VIKAS_Line[shift] = line;
}

//+------------------------------------------------------------------+
//| Calculate SQZMOM - Returns linreg VALUE (not slope!)             |
//+------------------------------------------------------------------+
double CalcSQZMOM(int shift)
{
   int len = InpSQZ_Length;

   // Find highest high / lowest low
   double highest = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double lowest = iLow(_Symbol, PERIOD_CURRENT, shift);
   for(int i = 1; i < len; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      double l = iLow(_Symbol, PERIOD_CURRENT, shift + i);
      if(h > highest) highest = h;
      if(l < lowest) lowest = l;
   }

   // SMA of close
   double sma = 0;
   for(int i = 0; i < len; i++)
      sma += iClose(_Symbol, PERIOD_CURRENT, shift + i);
   sma /= len;

   // Midline = avg(avg(highest,lowest), sma)
   double mid = ((highest + lowest) / 2.0 + sma) / 2.0;

   // Source = close - mid
   double source[];
   ArrayResize(source, len);
   for(int i = 0; i < len; i++)
      source[i] = iClose(_Symbol, PERIOD_CURRENT, shift + i) - mid;

   // Linear regression to get VALUE at current bar (not slope!)
   // x = 0 is newest, x = len-1 is oldest
   double sumX=0, sumY=0, sumXY=0, sumX2=0;
   for(int i = 0; i < len; i++)
   {
      double x = (double)(len - 1 - i);  // Oldest = len-1, Newest = 0
      sumX += x;
      sumY += source[i];
      sumXY += x * source[i];
      sumX2 += x * x;
   }

   double denom = len * sumX2 - sumX * sumX;
   if(MathAbs(denom) < 0.0000001)
      return sumY / len;  // Fallback to average

   double slope = (len * sumXY - sumX * sumY) / denom;
   double intercept = (sumY - slope * sumX) / len;

   // Value at x=0 (newest bar) = intercept
   // But TradingView linreg returns value at end of regression (x=len-1)
   return intercept + slope * (len - 1);
}

//+------------------------------------------------------------------+
//| Check Trading Hours                                              |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   if(!InpUseTradingHours) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.hour < InpStartHour || dt.hour > InpEndHour) return false;

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
   g_currentTrade = DIR_NONE;
   g_positionTicket = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         g_positionTicket = ticket;
         g_currentTrade = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                          ? DIR_LONG : DIR_SHORT;
         g_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_currentSL = PositionGetDouble(POSITION_SL);
         g_currentTP = PositionGetDouble(POSITION_TP);

         Print(">>> Found existing position: ", g_currentTrade == DIR_LONG ? "BUY" : "SELL",
               " Entry=", g_entryPrice, " SL=", g_currentSL, " TP=", g_currentTP);
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if position closed externally (SL/TP hit)
   if(g_currentTrade != DIR_NONE)
   {
      bool found = false;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            found = true;
            break;
         }
      }
      if(!found)
      {
         Print(">>> POSITION CLOSED (SL/TP hit or manual close)");
         g_currentTrade = DIR_NONE;
         g_positionTicket = 0;
         g_breakEvenApplied = false;
         g_pendingSignal = 0;
      }
   }

   // Manage break even on every tick
   if(g_currentTrade != DIR_NONE)
      ManageBreakEven();

   // Execute pending signal after delay (anti-bot)
   if(g_pendingSignal != 0 && g_currentTrade == DIR_NONE)
   {
      if(TimeCurrent() >= g_pendingTime + g_delaySeconds)
      {
         Print(">>> Delay completed. Executing trade...");
         ExecuteTrade(g_pendingSignal);
         g_lastTradeCE = g_pendingSignal;
         g_pendingSignal = 0;
      }
   }

   // Process signals only on new bar
   if(!IsNewBar()) return;
   if(!IsTradingTime()) return;

   // Recalculate all indicators
   RecalculateAll();

   int shift = 1;  // Use completed bar
   int currCE = g_CE_Dir[shift];
   int currVIKAS = g_VIKAS_Dir[shift];
   double sqz = CalcSQZMOM(shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Debug output
   Print("----------------------------------------");
   Print("BAR: ", TimeToString(iTime(_Symbol, PERIOD_CURRENT, shift)));
   Print("Close: ", DoubleToString(close, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("CE: ", currCE, " (1=BUY/-1=SELL) | Line: ",
         currCE == 1 ? DoubleToString(g_CE_LongStop[shift], 2) : DoubleToString(g_CE_ShortStop[shift], 2));
   Print("VIKAS: ", currVIKAS, " (1=BUY/-1=SELL) | Line: ", DoubleToString(g_VIKAS_Line[shift], 2));
   Print("SQZMOM: ", DoubleToString(sqz, 2), " (>0=BUY/<0=SELL)");
   Print("State: Trade=", g_currentTrade, " lastCE=", g_lastTradeCE, " prevCE=", g_prevCE);

   // Close position if CE flips opposite
   if(g_currentTrade != DIR_NONE)
   {
      if((g_currentTrade == DIR_LONG && currCE == -1) ||
         (g_currentTrade == DIR_SHORT && currCE == 1))
      {
         Print(">>> CE FLIPPED OPPOSITE - CLOSING POSITION");
         ClosePosition();
      }
   }

   // Reset lastTradeCE on any CE flip (to allow new trade in new direction)
   if(currCE != g_prevCE)
   {
      Print(">>> CE FLIP DETECTED: ", g_prevCE, " -> ", currCE);
      g_lastTradeCE = 0;
   }
   g_prevCE = currCE;

   // Entry logic
   if(g_currentTrade == DIR_NONE && g_pendingSignal == 0)
   {
      bool newCE = (currCE != g_lastTradeCE);

      // Check individual conditions
      bool ceLong = (currCE == 1);
      bool ceShort = (currCE == -1);

      bool vikasLong = !InpUseVIKAS || (currVIKAS == 1);
      bool vikasShort = !InpUseVIKAS || (currVIKAS == -1);

      bool sqzLong = (sqz > InpSQZ_MinThreshold);
      bool sqzShort = (sqz < -InpSQZ_MinThreshold);

      // ALL conditions must align
      bool allLong = ceLong && vikasLong && sqzLong;
      bool allShort = ceShort && vikasShort && sqzShort;

      Print("LONG check: CE=", ceLong, " VIKAS=", vikasLong, " SQZ=", sqzLong, " newCE=", newCE, " => ALL=", allLong);
      Print("SHORT check: CE=", ceShort, " VIKAS=", vikasShort, " SQZ=", sqzShort, " newCE=", newCE, " => ALL=", allShort);

      if(allLong && newCE)
      {
         Print(">>> ALL GREEN + NEW CE => QUEUE LONG");
         g_pendingSignal = 1;
         g_pendingTime = TimeCurrent();
         g_delaySeconds = InpDelayMin + MathRand() % (InpDelayMax - InpDelayMin + 1);
         Print(">>> Anti-bot delay: ", g_delaySeconds, " seconds");
      }
      else if(allShort && newCE)
      {
         Print(">>> ALL RED + NEW CE => QUEUE SHORT");
         g_pendingSignal = -1;
         g_pendingTime = TimeCurrent();
         g_delaySeconds = InpDelayMin + MathRand() % (InpDelayMax - InpDelayMin + 1);
         Print(">>> Anti-bot delay: ", g_delaySeconds, " seconds");
      }
      else
      {
         if(allLong && !newCE)
            Print(">>> BLOCKED: All green but waiting for CE flip (lastTradeCE=", g_lastTradeCE, ")");
         else if(allShort && !newCE)
            Print(">>> BLOCKED: All red but waiting for CE flip (lastTradeCE=", g_lastTradeCE, ")");
         else
            Print(">>> NO SIGNAL: Not all conditions aligned");
      }
   }

   Print("----------------------------------------");
}

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(int direction)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = point * g_pipMultiplier;
   double slBuf = InpSL_Buffer * pipVal;

   // CE stop line for SL calculation
   double ceStop = (direction == 1) ? g_CE_LongStop[1] : g_CE_ShortStop[1];

   // Random TP between min and max
   int rtp = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);

   double price, sl, tp;

   Print(">>> EXECUTING TRADE: dir=", direction, " pipVal=", pipVal, " TP_pips=", rtp);

   if(direction == 1)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = ceStop - slBuf;
      tp = price + rtp * pipVal;

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      Print(">>> BUY: Price=", price, " SL=", sl, " TP=", tp, " (CE_Line=", ceStop, ")");

      if(trade.Buy(InpLotSize, _Symbol, price, sl, tp, "CE-VIKAS-v1.24"))
      {
         g_currentTrade = DIR_LONG;
         g_positionTicket = trade.ResultOrder();
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_breakEvenApplied = false;
         Print(">>> BUY SUCCESS! Ticket=", g_positionTicket);
      }
      else
      {
         Print(">>> BUY FAILED: Error ", GetLastError(), " - ", trade.ResultRetcodeDescription());
      }
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = ceStop + slBuf;
      tp = price - rtp * pipVal;

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      Print(">>> SELL: Price=", price, " SL=", sl, " TP=", tp, " (CE_Line=", ceStop, ")");

      if(trade.Sell(InpLotSize, _Symbol, price, sl, tp, "CE-VIKAS-v1.24"))
      {
         g_currentTrade = DIR_SHORT;
         g_positionTicket = trade.ResultOrder();
         g_entryPrice = price;
         g_currentSL = sl;
         g_currentTP = tp;
         g_breakEvenApplied = false;
         Print(">>> SELL SUCCESS! Ticket=", g_positionTicket);
      }
      else
      {
         Print(">>> SELL FAILED: Error ", GetLastError(), " - ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Close Position                                                   |
//+------------------------------------------------------------------+
void ClosePosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         if(trade.PositionClose(ticket))
         {
            Print(">>> Position closed successfully");
            g_currentTrade = DIR_NONE;
            g_positionTicket = 0;
            g_breakEvenApplied = false;
         }
         else
         {
            Print(">>> Failed to close position: ", GetLastError());
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Break Even Management                                            |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(g_breakEvenApplied || InpBreakEvenPips <= 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipVal = point * g_pipMultiplier;
   double beThreshold = InpBreakEvenPips * pipVal;
   double beOffset = InpBreakEvenOffset * pipVal;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;

         double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                   : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         double profit = dir * (price - open);

         if(profit >= beThreshold)
         {
            double newSL = NormalizeDouble(open + dir * beOffset, digits);

            // Only modify if new SL is better
            if((dir == 1 && newSL > sl) || (dir == -1 && newSL < sl))
            {
               if(trade.PositionModify(ticket, newSL, tp))
               {
                  g_currentSL = newSL;
                  g_breakEvenApplied = true;
                  Print(">>> BREAK EVEN APPLIED: New SL=", newSL);
               }
               else
               {
                  Print(">>> Break even failed: ", GetLastError());
               }
            }
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release ATR handles
   if(g_atrHandleCE != INVALID_HANDLE)
      IndicatorRelease(g_atrHandleCE);
   if(g_atrHandleVIKAS != INVALID_HANDLE)
      IndicatorRelease(g_atrHandleVIKAS);

   Print("=== CE VIKAS EA v1.24 STOPPED ===");
   Print("Reason: ", reason);
}
//+------------------------------------------------------------------+
