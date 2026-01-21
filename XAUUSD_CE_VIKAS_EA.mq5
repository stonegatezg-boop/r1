//+------------------------------------------------------------------+
//|                                           XAUUSD_CE_VIKAS_EA.mq5 |
//|                                        Copyright 2026, Partner   |
//|                              XAUUSD / XAGUSD / BTCUSD M5 Strategy |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Partner"
#property link      ""
#property version   "1.25"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== GENERAL ==="
input double InpLotSize = 0.2;
input int    InpMagicNumber = 123456;
input int    InpSlippage = 30;

input group "=== FILTERS (for testing) ==="
input bool   InpUseVIKAS = false;         // Use VIKAS filter? (FALSE = easier to trigger)
input bool   InpRequireCEflip = true;     // Require NEW CE flip? (FALSE = enter anytime)
input double InpSQZ_Threshold = 0.0;      // SQZMOM threshold (0 = any value)

input group "=== CHANDELIER EXIT ==="
input int    InpCE_Period = 10;
input double InpCE_Multiplier = 3.0;

input group "=== VIKAS SUPERTREND ==="
input int    InpVIKAS_Period = 18;
input double InpVIKAS_Multiplier = 2.8;

input group "=== SQZMOM ==="
input int    InpSQZ_Length = 10;

input group "=== RISK ==="
input int    InpSL_Buffer = 100;
input int    InpTP_Min = 191;
input int    InpTP_Max = 214;
input int    InpBreakEvenPips = 50;
input int    InpBreakEvenOffset = 5;
input int    InpDelayMin = 2;
input int    InpDelayMax = 8;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade trade;

int g_currentDir = 0;        // 0=none, 1=long, -1=short
int g_lastTradeCE = 0;       // CE direction of last trade
int g_prevCE = 0;            // Previous bar CE
datetime g_lastBarTime = 0;
bool g_breakEvenDone = false;

// Pending signal (anti-bot)
int g_pendingDir = 0;
datetime g_pendingTime = 0;
int g_delaySeconds = 0;
double g_pendingSL = 0;
int g_pendingTP = 0;

// Instrument
int g_pipMult = 10;

// ATR handles
int g_atrCE = INVALID_HANDLE;
int g_atrVIKAS = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   MathSrand((uint)TimeLocal());

   // Detect instrument
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
      g_pipMult = 10;
   else if(StringFind(_Symbol, "XAG") >= 0 || StringFind(_Symbol, "SILVER") >= 0)
      g_pipMult = 100;
   else if(StringFind(_Symbol, "BTC") >= 0)
      g_pipMult = 1;
   else
      g_pipMult = 10;

   // Trade setup
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // ATR handles
   g_atrCE = iATR(_Symbol, PERIOD_CURRENT, InpCE_Period);
   g_atrVIKAS = iATR(_Symbol, PERIOD_CURRENT, InpVIKAS_Period);

   if(g_atrCE == INVALID_HANDLE || g_atrVIKAS == INVALID_HANDLE)
   {
      Print("ERROR: ATR handle failed!");
      return INIT_FAILED;
   }

   // Check for existing position
   CheckPosition();

   Print("============================================");
   Print("=== CE VIKAS EA v1.25 DIAGNOSTIC ===");
   Print("Symbol: ", _Symbol, " | PipMult: ", g_pipMult);
   Print("UseVIKAS: ", InpUseVIKAS);
   Print("RequireCEflip: ", InpRequireCEflip);
   Print("SQZ Threshold: ", InpSQZ_Threshold);
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrCE != INVALID_HANDLE) IndicatorRelease(g_atrCE);
   if(g_atrVIKAS != INVALID_HANDLE) IndicatorRelease(g_atrVIKAS);
   Print("=== EA STOPPED ===");
}

//+------------------------------------------------------------------+
double GetATR(int handle, int shift)
{
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) == 1)
      return buf[0];
   return 0;
}

//+------------------------------------------------------------------+
double PipValue()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT) * g_pipMult;
}

//+------------------------------------------------------------------+
void CheckPosition()
{
   g_currentDir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      g_currentDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      Print(">>> Found position: ", g_currentDir == 1 ? "BUY" : "SELL");
      break;
   }
}

//+------------------------------------------------------------------+
// SIMPLE CE CALCULATION - bar by bar
//+------------------------------------------------------------------+
int CalcCE(int shift, double &stopLine)
{
   double atr = GetATR(g_atrCE, shift);
   if(atr <= 0) { stopLine = 0; return 0; }

   atr *= InpCE_Multiplier;

   // Highest/lowest close in period
   double highest = 0, lowest = 999999;
   for(int i = 0; i < InpCE_Period; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);
      if(c > highest) highest = c;
      if(c < lowest) lowest = c;
   }

   double longStop = highest - atr;
   double shortStop = lowest + atr;
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Simple direction based on price vs stops
   int dir;
   if(close > shortStop)
      dir = 1;  // Bullish
   else if(close < longStop)
      dir = -1; // Bearish
   else
      dir = (close > (highest + lowest) / 2) ? 1 : -1;

   stopLine = (dir == 1) ? longStop : shortStop;
   return dir;
}

//+------------------------------------------------------------------+
// SIMPLE VIKAS - SuperTrend style
//+------------------------------------------------------------------+
int CalcVIKAS(int shift)
{
   double atr = GetATR(g_atrVIKAS, shift);
   if(atr <= 0) return 0;

   atr *= InpVIKAS_Multiplier;

   double low = iLow(_Symbol, PERIOD_CURRENT, shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   double upper = low + atr;
   double lower = low - atr;

   // Simple: close above upper = bull, close below lower = bear
   if(close > upper) return 1;
   if(close < lower) return -1;

   // Use HL2 based check as fallback
   double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double hl2 = (high + low) / 2;
   return (close > hl2) ? 1 : -1;
}

//+------------------------------------------------------------------+
// SQZMOM - simple momentum
//+------------------------------------------------------------------+
double CalcSQZMOM(int shift)
{
   int len = InpSQZ_Length;

   double highest = 0, lowest = 999999;
   double sum = 0;

   for(int i = 0; i < len; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, shift + i);
      double l = iLow(_Symbol, PERIOD_CURRENT, shift + i);
      double c = iClose(_Symbol, PERIOD_CURRENT, shift + i);

      if(h > highest) highest = h;
      if(l < lowest) lowest = l;
      sum += c;
   }

   double sma = sum / len;
   double mid = ((highest + lowest) / 2 + sma) / 2;
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   return close - mid;
}

//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(g_breakEvenDone || InpBreakEvenPips <= 0) return;
   if(g_currentDir == 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;

      double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profit = dir * (price - open);
      double threshold = InpBreakEvenPips * PipValue();

      if(profit >= threshold)
      {
         double newSL = open + dir * InpBreakEvenOffset * PipValue();
         newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

         if((dir == 1 && newSL > sl) || (dir == -1 && newSL < sl))
         {
            if(trade.PositionModify(ticket, newSL, tp))
            {
               g_breakEvenDone = true;
               Print(">>> BREAK EVEN SET: ", newSL);
            }
         }
      }
      break;
   }
}

//+------------------------------------------------------------------+
void ClosePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      trade.PositionClose(ticket);
      Print(">>> POSITION CLOSED");
      g_currentDir = 0;
      g_breakEvenDone = false;
      break;
   }
}

//+------------------------------------------------------------------+
void ExecutePending()
{
   if(g_pendingDir == 0) return;

   double price, sl, tp;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = PipValue();

   if(g_pendingDir == 1)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = g_pendingSL - InpSL_Buffer * pipVal;
      tp = price + g_pendingTP * pipVal;
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = g_pendingSL + InpSL_Buffer * pipVal;
      tp = price - g_pendingTP * pipVal;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   Print(">>> EXECUTING: ", g_pendingDir == 1 ? "BUY" : "SELL");
   Print("    Price=", price, " SL=", sl, " TP=", tp);

   bool success;
   if(g_pendingDir == 1)
      success = trade.Buy(InpLotSize, _Symbol, price, sl, tp, "CE-VIKAS");
   else
      success = trade.Sell(InpLotSize, _Symbol, price, sl, tp, "CE-VIKAS");

   if(success)
   {
      g_currentDir = g_pendingDir;
      g_lastTradeCE = g_pendingDir;
      g_breakEvenDone = false;
      Print(">>> SUCCESS!");
   }
   else
   {
      Print(">>> FAILED: ", GetLastError(), " - ", trade.ResultRetcodeDescription());
   }

   g_pendingDir = 0;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Check if position closed
   if(g_currentDir != 0)
   {
      bool found = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         found = true;
         break;
      }
      if(!found)
      {
         Print(">>> POSITION CLOSED (SL/TP)");
         g_currentDir = 0;
         g_breakEvenDone = false;
         g_pendingDir = 0;
      }
   }

   // Break even
   if(g_currentDir != 0)
      ManageBreakEven();

   // Execute pending after delay
   if(g_pendingDir != 0 && g_currentDir == 0)
   {
      if(TimeCurrent() >= g_pendingTime)
      {
         ExecutePending();
      }
   }

   // Only process on new bar
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   // Calculate indicators on bar 1 (closed bar)
   double ceStop = 0;
   int ce = CalcCE(1, ceStop);
   int vikas = CalcVIKAS(1);
   double sqz = CalcSQZMOM(1);

   // Detect CE flip
   bool ceFlipped = (ce != 0 && g_prevCE != 0 && ce != g_prevCE);

   // Debug output
   Print("========== NEW BAR ==========");
   Print("Time: ", TimeToString(iTime(_Symbol, PERIOD_CURRENT, 1)));
   Print("Close: ", iClose(_Symbol, PERIOD_CURRENT, 1));
   Print("CE: ", ce, " (prev=", g_prevCE, ") flipped=", ceFlipped);
   Print("VIKAS: ", vikas);
   Print("SQZMOM: ", DoubleToString(sqz, 2));
   Print("Position: ", g_currentDir, " | lastTradeCE: ", g_lastTradeCE);

   // Close on opposite CE
   if(g_currentDir != 0 && ce != 0 && ce == -g_currentDir)
   {
      Print(">>> CE OPPOSITE - CLOSING");
      ClosePosition();
   }

   // Update prevCE
   int oldPrevCE = g_prevCE;
   g_prevCE = ce;

   // Reset lastTradeCE on flip
   if(ceFlipped)
   {
      Print(">>> CE FLIP! Resetting lastTradeCE");
      g_lastTradeCE = 0;
   }

   // Entry logic
   if(g_currentDir == 0 && g_pendingDir == 0)
   {
      // Check conditions
      bool ceLong = (ce == 1);
      bool ceShort = (ce == -1);

      bool vikasLong = !InpUseVIKAS || (vikas == 1);
      bool vikasShort = !InpUseVIKAS || (vikas == -1);

      bool sqzLong = (sqz > InpSQZ_Threshold);
      bool sqzShort = (sqz < -InpSQZ_Threshold);

      bool newCE = !InpRequireCEflip || (ce != g_lastTradeCE);

      Print("--- Entry Check ---");
      Print("LONG: ce=", ceLong, " vikas=", vikasLong, " sqz=", sqzLong, " newCE=", newCE);
      Print("SHORT: ce=", ceShort, " vikas=", vikasShort, " sqz=", sqzShort, " newCE=", newCE);

      bool goLong = ceLong && vikasLong && sqzLong && newCE;
      bool goShort = ceShort && vikasShort && sqzShort && newCE;

      if(goLong)
      {
         Print(">>> SIGNAL: GO LONG!");
         g_pendingDir = 1;
         g_pendingTime = TimeCurrent() + InpDelayMin + MathRand() % (InpDelayMax - InpDelayMin + 1);
         g_pendingSL = ceStop;
         g_pendingTP = InpTP_Min + MathRand() % (InpTP_Max - InpTP_Min + 1);
         Print(">>> Pending in ", (int)(g_pendingTime - TimeCurrent()), " sec, SL=", g_pendingSL, " TP=", g_pendingTP);
      }
      else if(goShort)
      {
         Print(">>> SIGNAL: GO SHORT!");
         g_pendingDir = -1;
         g_pendingTime = TimeCurrent() + InpDelayMin + MathRand() % (InpDelayMax - InpDelayMin + 1);
         g_pendingSL = ceStop;
         g_pendingTP = InpTP_Min + MathRand() % (InpDelayMax - InpDelayMin + 1);
         Print(">>> Pending in ", (int)(g_pendingTime - TimeCurrent()), " sec, SL=", g_pendingSL, " TP=", g_pendingTP);
      }
      else
      {
         Print(">>> NO ENTRY - conditions not met");
      }
   }

   Print("==============================");
}
//+------------------------------------------------------------------+
