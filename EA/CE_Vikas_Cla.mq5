//+------------------------------------------------------------------+
//|                                                  CE_Vikas_Cla.mq5 |
//|   *** CE Vikas Cla - Chandelier Exit + SuperTrend Dual Confirm ***|
//|                                                                  |
//|   DUAL CONFIRMATION SYSTEM:                                      |
//|   1. SuperTrend direction change (primary signal)                |
//|   2. Chandelier Exit same direction (confirmation)               |
//|   3. Squeeze Momentum confirmation                               |
//|   4. Bull/Bear candle confirmation                               |
//|                                                                  |
//|   + Full Stealth Execution                                       |
//|   + 3 Target Levels with Partial Closes                          |
//|   + TSL System + Human-Like Trailing                             |
//|                                                                  |
//|   Optimized for XAUUSD M5                                        |
//|   Version 1.0 - 2026-02-24                                       |
//+------------------------------------------------------------------+
#property copyright "CE Vikas Cla v1.0 (2026-02-24)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| TRADE DATA STRUCTURE                                              |
//+------------------------------------------------------------------+
struct TradeData
{
   ulong    ticket;
   double   entryPrice;
   double   intendedSL;
   double   stealthTP;
   double   target1;
   double   target2;
   double   target3;
   double   tsl1Level;
   double   tsl2Level;
   datetime openTime;
   int      slDelaySeconds;
   int      direction;        // 1=LONG, -1=SHORT
   bool     slPlaced;
   bool     target1Hit;
   bool     target2Hit;
   bool     target3Hit;
   int      trailLevel;
   int      randomBEPips;
   int      randomL2Pips;
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== SUPERTREND POSTAVKE ==="
input int      ST_ATR_Period      = 14;        // SuperTrend ATR Period
input double   ST_ATR_Multiplier  = 2.5;       // SuperTrend ATR Multiplier

input group "=== CHANDELIER EXIT POSTAVKE ==="
input int      CE_ATR_Period      = 14;        // Chandelier ATR Period
input double   CE_ATR_Multiplier  = 3.5;       // Chandelier ATR Multiplier
input bool     CE_UseClose        = true;      // Use Close for Extremums

input group "=== SQUEEZE MOMENTUM ==="
input bool     UseSQZM            = true;      // Use Squeeze Momentum
input int      SQZM_BB_Length     = 20;        // BB Period
input double   SQZM_BB_Mult       = 2.0;       // BB StdDev
input int      SQZM_KC_Length     = 20;        // Keltner Period
input double   SQZM_KC_Mult       = 1.5;       // KC Multiplier

input group "=== CANDLE CONFIRMATION ==="
input bool     RequireBullBear    = true;      // Require Bull/Bear Candle

input group "=== GAN TARGETS ==="
input double   Target1_Mult       = 1.7;       // Target 1 (x range)
input double   Target2_Mult       = 2.5;       // Target 2 (x range)
input double   Target3_Mult       = 3.5;       // Target 3 (x range)

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent        = 1.0;       // Risk % per trade
input int      MaxOpenTrades      = 3;         // Max open trades
input double   MaxDailyDD         = 3.0;       // Max daily DD %

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin         = 7;         // Min SL delay (seconds)
input int      SLDelayMax         = 13;        // Max SL delay (seconds)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR     = 3.0;       // Block if candle > X * ATR

input group "=== TRAILING STOP ==="
input int      Trail1_Pips        = 500;       // Level 1: Activate at X pips
input int      Trail1_BEMin       = 38;        // Level 1: BE + min pips
input int      Trail1_BEMax       = 43;        // Level 1: BE + max pips
input int      Trail2_Pips        = 800;       // Level 2: Activate at X pips
input int      Trail2_LockMin     = 150;       // Level 2: Lock min pips
input int      Trail2_LockMax     = 200;       // Level 2: Lock max pips

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter      = true;      // Use News Filter
input int      NewsImportance     = 2;         // Min importance (1-3)
input int      NewsMinsBefore     = 30;        // Minutes before news
input int      NewsMinsAfter      = 30;        // Minutes after news

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter    = true;      // Use Spread Filter
input int      MaxSpread          = 40;        // Max spread in points

input group "=== GENERAL ==="
input ulong    MagicNumber        = 556688;    // Magic Number
input int      Slippage           = 30;        // Slippage (points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
int            stAtrHandle, ceAtrHandle;
datetime       lastBarTime;
TradeData      trades[];
int            tradesCount = 0;

// SuperTrend arrays
double         stUp[], stDn[];
int            stDir[];

// Chandelier Exit arrays
double         ceLongStop[], ceShortStop[];
int            ceDir[];

// Statistics
int            statBuys = 0, statSells = 0;
int            statNewsBlocked = 0, statSpreadBlocked = 0;
int            statLargeCandleBlocked = 0;
int            statSQZMBlocked = 0, statCEBlocked = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Create ATR handles
   stAtrHandle = iATR(_Symbol, PERIOD_CURRENT, ST_ATR_Period);
   ceAtrHandle = iATR(_Symbol, PERIOD_CURRENT, CE_ATR_Period);

   if(stAtrHandle == INVALID_HANDLE || ceAtrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handles");
      return INIT_FAILED;
   }

   // Initialize SuperTrend arrays
   ArrayResize(stUp, 3);
   ArrayResize(stDn, 3);
   ArrayResize(stDir, 3);
   ArrayInitialize(stUp, 0);
   ArrayInitialize(stDn, 0);
   ArrayInitialize(stDir, 1);

   // Initialize Chandelier Exit arrays
   ArrayResize(ceLongStop, 3);
   ArrayResize(ceShortStop, 3);
   ArrayResize(ceDir, 3);
   ArrayInitialize(ceLongStop, 0);
   ArrayInitialize(ceShortStop, 0);
   ArrayInitialize(ceDir, 1);

   ArrayResize(trades, 0);
   tradesCount = 0;
   lastBarTime = 0;

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   Print("╔═══════════════════════════════════════════════════════════════╗");
   Print("║      CE VIKAS CLA v1.0 - DUAL CONFIRMATION SYSTEM             ║");
   Print("╠═══════════════════════════════════════════════════════════════╣");
   Print("║ SuperTrend: ATR(", ST_ATR_Period, ") x ", ST_ATR_Multiplier);
   Print("║ Chandelier Exit: ATR(", CE_ATR_Period, ") x ", CE_ATR_Multiplier);
   Print("║ Squeeze Momentum: ", UseSQZM ? "ON" : "OFF");
   Print("║ Targets: ", Target1_Mult, "x / ", Target2_Mult, "x / ", Target3_Mult, "x range");
   Print("║ Stealth: SL delay ", SLDelayMin, "-", SLDelayMax, "s | TP hidden");
   Print("║ Trailing: L1=BE+", Trail1_BEMin, "-", Trail1_BEMax, " @ ", Trail1_Pips, "pips");
   Print("║           L2=+", Trail2_LockMin, "-", Trail2_LockMax, " @ ", Trail2_Pips, "pips");
   Print("║ Trading: Sunday 00:01 - Friday 11:30 (Server Time)");
   Print("╚═══════════════════════════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(stAtrHandle != INVALID_HANDLE) IndicatorRelease(stAtrHandle);
   if(ceAtrHandle != INVALID_HANDLE) IndicatorRelease(ceAtrHandle);

   Print("═══════════════════════════════════════════════════");
   Print("      CE VIKAS CLA - FINAL STATISTICS");
   Print("═══════════════════════════════════════════════════");
   Print("Total BUY: ", statBuys, " | Total SELL: ", statSells);
   Print("Blocked by NEWS: ", statNewsBlocked);
   Print("Blocked by SPREAD: ", statSpreadBlocked);
   Print("Blocked by LARGE CANDLE: ", statLargeCandleBlocked);
   Print("Blocked by SQZM: ", statSQZMBlocked);
   Print("Blocked by CE (no confirm): ", statCEBlocked);
   Print("═══════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
   if(minVal >= maxVal) return minVal;
   return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
double GetATR(int handle, int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0)
      return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

   if(dt.day_of_week == 5)
      return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));

   return false;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsLargeCandle()
{
   double atr = GetATR(stAtrHandle, 1);
   if(atr <= 0) return false;

   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low = iLow(_Symbol, PERIOD_CURRENT, 1);

   return ((high - low) > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   if(!UseSpreadFilter) return true;
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
bool HasActiveNews()
{
   if(!UseNewsFilter) return false;

   string symbol = _Symbol;
   string cur1 = StringSubstr(symbol, 0, 3);
   string cur2 = StringSubstr(symbol, 3, 3);

   if(CheckCurrencyNews(cur1)) return true;
   if(CheckCurrencyNews(cur2)) return true;

   return false;
}

//+------------------------------------------------------------------+
bool CheckCurrencyNews(string currency)
{
   datetime now = TimeTradeServer();
   datetime from = now - NewsMinsBefore * 60;
   datetime to = now + NewsMinsAfter * 60;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, NULL, currency);

   if(count <= 0) return false;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;

      if(event.importance >= NewsImportance)
      {
         datetime eventTime = values[i].time;
         if(now >= eventTime - NewsMinsBefore * 60 && now <= eventTime + NewsMinsAfter * 60)
            return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
double CurrentDailyDD()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, TimeCurrent());

   double pnl = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol)
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   return (pnl / bal) * 100.0;
}

//+------------------------------------------------------------------+
//| SUPERTREND CALCULATION                                            |
//+------------------------------------------------------------------+
void CalculateSuperTrend(int &direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, high) <= 0) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, low) <= 0) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, close) <= 0) return;

   double atr = GetATR(stAtrHandle, 1);
   if(atr <= 0) return;

   double src = (high[1] + low[1]) / 2.0;
   double up = src - ST_ATR_Multiplier * atr;
   double dn = src + ST_ATR_Multiplier * atr;

   double up1 = stUp[1];
   double dn1 = stDn[1];
   int trend1 = stDir[1];

   if(close[2] > up1) up = MathMax(up, up1);
   if(close[2] < dn1) dn = MathMin(dn, dn1);

   int trend = trend1;
   if(trend1 == -1 && close[1] > dn1)
      trend = 1;
   else if(trend1 == 1 && close[1] < up1)
      trend = -1;

   // Shift arrays
   stUp[2] = stUp[1]; stUp[1] = stUp[0]; stUp[0] = up;
   stDn[2] = stDn[1]; stDn[1] = stDn[0]; stDn[0] = dn;
   stDir[2] = stDir[1]; stDir[1] = stDir[0]; stDir[0] = trend;

   direction = trend;
}

//+------------------------------------------------------------------+
//| CHANDELIER EXIT CALCULATION                                       |
//+------------------------------------------------------------------+
void CalculateChandelierExit(int &direction)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   int barsNeeded = CE_ATR_Period + 5;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, high) <= 0) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, low) <= 0) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, close) <= 0) return;

   double atr = GetATR(ceAtrHandle, 1);
   if(atr <= 0) return;

   // Calculate highest high and lowest low
   double highestHigh = high[1];
   double lowestLow = low[1];

   for(int i = 1; i <= CE_ATR_Period; i++)
   {
      if(CE_UseClose)
      {
         if(close[i] > highestHigh) highestHigh = close[i];
         if(close[i] < lowestLow) lowestLow = close[i];
      }
      else
      {
         if(high[i] > highestHigh) highestHigh = high[i];
         if(low[i] < lowestLow) lowestLow = low[i];
      }
   }

   // Calculate stops
   double longStop = highestHigh - CE_ATR_Multiplier * atr;
   double shortStop = lowestLow + CE_ATR_Multiplier * atr;

   // Apply trailing logic
   double longStopPrev = ceLongStop[1];
   double shortStopPrev = ceShortStop[1];

   if(longStopPrev > 0 && close[2] > longStopPrev)
      longStop = MathMax(longStop, longStopPrev);

   if(shortStopPrev > 0 && close[2] < shortStopPrev)
      shortStop = MathMin(shortStop, shortStopPrev);

   // Determine direction
   int dir = ceDir[1];
   if(close[1] > shortStopPrev && shortStopPrev > 0)
      dir = 1;
   else if(close[1] < longStopPrev && longStopPrev > 0)
      dir = -1;

   // Shift arrays
   ceLongStop[2] = ceLongStop[1]; ceLongStop[1] = ceLongStop[0]; ceLongStop[0] = longStop;
   ceShortStop[2] = ceShortStop[1]; ceShortStop[1] = ceShortStop[0]; ceShortStop[0] = shortStop;
   ceDir[2] = ceDir[1]; ceDir[1] = ceDir[0]; ceDir[0] = dir;

   direction = dir;
}

//+------------------------------------------------------------------+
//| SQUEEZE MOMENTUM                                                  |
//+------------------------------------------------------------------+
double CalculateSQZM(int &momentumDir)
{
   if(!UseSQZM) { momentumDir = 0; return 0; }

   double close[], high[], low[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   int barsNeeded = MathMax(SQZM_BB_Length, SQZM_KC_Length) + 5;

   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, close) <= 0) return 0;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, high) <= 0) return 0;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, low) <= 0) return 0;

   // Calculate momentum
   double vals[2];
   for(int idx = 0; idx < 2; idx++)
   {
      double hh = high[idx+1], ll = low[idx+1];
      for(int j = idx+1; j <= idx + SQZM_KC_Length && j < barsNeeded; j++)
      {
         if(high[j] > hh) hh = high[j];
         if(low[j] < ll) ll = low[j];
      }
      double avgHL = (hh + ll) / 2.0;

      double sumClose = 0;
      int count = 0;
      for(int j = idx+1; j <= idx + SQZM_KC_Length && j < barsNeeded; j++)
      {
         sumClose += close[j];
         count++;
      }
      double sma = (count > 0) ? sumClose / count : close[idx+1];
      double avgAll = (avgHL + sma) / 2.0;
      vals[idx] = close[idx+1] - avgAll;
   }

   if(vals[0] > vals[1])
      momentumDir = 1;
   else
      momentumDir = -1;

   return vals[0];
}

//+------------------------------------------------------------------+
//| CHECK CANDLE TYPE                                                 |
//+------------------------------------------------------------------+
bool IsBullishCandle(int shift = 1)
{
   return iClose(_Symbol, PERIOD_CURRENT, shift) > iOpen(_Symbol, PERIOD_CURRENT, shift);
}

bool IsBearishCandle(int shift = 1)
{
   return iClose(_Symbol, PERIOD_CURRENT, shift) < iOpen(_Symbol, PERIOD_CURRENT, shift);
}

//+------------------------------------------------------------------+
//| GET SIGNALS - DUAL CONFIRMATION                                   |
//+------------------------------------------------------------------+
void GetSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   // 1. Calculate SuperTrend
   int stDirection;
   CalculateSuperTrend(stDirection);

   // Check for SuperTrend direction change
   bool stBuySignal = (stDir[0] == 1 && stDir[1] == -1);
   bool stSellSignal = (stDir[0] == -1 && stDir[1] == 1);

   if(!stBuySignal && !stSellSignal) return;

   // 2. Calculate Chandelier Exit
   int ceDirection;
   CalculateChandelierExit(ceDirection);

   // DUAL CONFIRMATION: CE must agree with SuperTrend
   if(stBuySignal && ceDir[0] != 1)
   {
      statCEBlocked++;
      Print("BUY blocked: CE direction = ", ceDir[0], " (need 1)");
      return;
   }
   if(stSellSignal && ceDir[0] != -1)
   {
      statCEBlocked++;
      Print("SELL blocked: CE direction = ", ceDir[0], " (need -1)");
      return;
   }

   // 3. Squeeze Momentum confirmation
   if(UseSQZM)
   {
      int sqzmDir;
      double sqzmVal = CalculateSQZM(sqzmDir);

      if(stBuySignal)
      {
         if(sqzmVal <= 0 || sqzmDir != 1)
         {
            statSQZMBlocked++;
            Print("BUY blocked: SQZM val=", DoubleToString(sqzmVal, 2), " dir=", sqzmDir);
            return;
         }
      }
      else if(stSellSignal)
      {
         if(sqzmVal >= 0 || sqzmDir != -1)
         {
            statSQZMBlocked++;
            Print("SELL blocked: SQZM val=", DoubleToString(sqzmVal, 2), " dir=", sqzmDir);
            return;
         }
      }
   }

   // 4. Candle confirmation
   if(RequireBullBear)
   {
      if(stBuySignal && !IsBullishCandle(1))
      {
         Print("BUY blocked: Not a bullish candle");
         return;
      }
      if(stSellSignal && !IsBearishCandle(1))
      {
         Print("SELL blocked: Not a bearish candle");
         return;
      }
   }

   // ALL CONFIRMATIONS PASSED
   buySignal = stBuySignal;
   sellSignal = stSellSignal;
}

//+------------------------------------------------------------------+
double CalculateLotSize(double slDist)
{
   if(slDist <= 0) return 0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickVal <= 0 || tickSize <= 0 || point <= 0) return 0;

   double slPts = slDist / point;
   double lots = riskAmt / (slPts * tickVal / tickSize);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void SyncTradesArray()
{
   for(int i = tradesCount - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(trades[i].ticket))
      {
         for(int j = i; j < tradesCount - 1; j++)
            trades[j] = trades[j + 1];
         tradesCount--;
         ArrayResize(trades, tradesCount);
      }
   }
}

//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double sl, double tp,
              double t1, double t2, double t3, int dir, int slDelay, int bePips, int l2Pips)
{
   ArrayResize(trades, tradesCount + 1);
   trades[tradesCount].ticket = ticket;
   trades[tradesCount].entryPrice = entry;
   trades[tradesCount].intendedSL = sl;
   trades[tradesCount].stealthTP = tp;
   trades[tradesCount].target1 = t1;
   trades[tradesCount].target2 = t2;
   trades[tradesCount].target3 = t3;
   trades[tradesCount].tsl1Level = 0;
   trades[tradesCount].tsl2Level = 0;
   trades[tradesCount].openTime = TimeCurrent();
   trades[tradesCount].slDelaySeconds = slDelay;
   trades[tradesCount].direction = dir;
   trades[tradesCount].slPlaced = false;
   trades[tradesCount].target1Hit = false;
   trades[tradesCount].target2Hit = false;
   trades[tradesCount].target3Hit = false;
   trades[tradesCount].trailLevel = 0;
   trades[tradesCount].randomBEPips = bePips;
   trades[tradesCount].randomL2Pips = l2Pips;
   tradesCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
   if(trade.PositionClose(ticket))
      Print("CE_VIKAS CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
void PartialClose(ulong ticket, double portion, string reason)
{
   if(!PositionSelectByTicket(ticket)) return;

   double volume = PositionGetDouble(POSITION_VOLUME);
   double closeVol = NormalizeDouble(volume * portion, 2);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(closeVol < minLot) closeVol = minLot;

   if(closeVol >= volume)
   {
      ClosePosition(ticket, reason);
      return;
   }

   if(trade.PositionClosePartial(ticket, closeVol))
      Print("CE_VIKAS PARTIAL [", ticket, "]: ", reason, " (", closeVol, " lots)");
}

//+------------------------------------------------------------------+
//| MANAGE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void ManageAllPositions()
{
   SyncTradesArray();

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = tradesCount - 1; i >= 0; i--)
   {
      ulong ticket = trades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice;

      if(trades[i].direction == 1)
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      else
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
      double low = iLow(_Symbol, PERIOD_CURRENT, 0);

      //=== 1. DELAYED SL PLACEMENT ===
      if(!trades[i].slPlaced && trades[i].intendedSL != 0)
      {
         if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
         {
            double sl = NormalizeDouble(trades[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
            {
               trades[i].slPlaced = true;
               Print("CE_VIKAS STEALTH [", ticket, "]: SL @ ", sl, " (delay ", trades[i].slDelaySeconds, "s)");
            }
         }
      }

      //=== 2. STEALTH TP CHECK ===
      if(trades[i].stealthTP > 0)
      {
         bool tpHit = false;
         if(trades[i].direction == 1 && currentPrice >= trades[i].stealthTP)
            tpHit = true;
         else if(trades[i].direction == -1 && currentPrice <= trades[i].stealthTP)
            tpHit = true;

         if(tpHit)
         {
            ClosePosition(ticket, "STEALTH TP @ " + DoubleToString(currentPrice, digits));
            continue;
         }
      }

      //=== 3. TRAILING LEVEL 2 ===
      if(trades[i].slPlaced && trades[i].trailLevel < 2)
      {
         double profitPips = (trades[i].direction == 1)
            ? (currentPrice - trades[i].entryPrice) / point
            : (trades[i].entryPrice - currentPrice) / point;

         if(profitPips >= Trail2_Pips)
         {
            double newSL;
            if(trades[i].direction == 1)
               newSL = trades[i].entryPrice + trades[i].randomL2Pips * point;
            else
               newSL = trades[i].entryPrice - trades[i].randomL2Pips * point;

            newSL = NormalizeDouble(newSL, digits);
            bool shouldMod = (trades[i].direction == 1 && newSL > currentSL) ||
                             (trades[i].direction == -1 && newSL < currentSL);

            if(shouldMod && trade.PositionModify(ticket, newSL, 0))
            {
               trades[i].trailLevel = 2;
               Print("CE_VIKAS TRAIL L2 [", ticket, "]: Lock +", trades[i].randomL2Pips);
            }
         }
      }

      //=== 4. TRAILING LEVEL 1 ===
      if(trades[i].slPlaced && trades[i].trailLevel < 1)
      {
         double profitPips = (trades[i].direction == 1)
            ? (currentPrice - trades[i].entryPrice) / point
            : (trades[i].entryPrice - currentPrice) / point;

         if(profitPips >= Trail1_Pips)
         {
            double newSL;
            if(trades[i].direction == 1)
               newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
            else
               newSL = trades[i].entryPrice - trades[i].randomBEPips * point;

            newSL = NormalizeDouble(newSL, digits);
            bool shouldMod = (trades[i].direction == 1 && newSL > currentSL) ||
                             (trades[i].direction == -1 && newSL < currentSL);

            if(shouldMod && trade.PositionModify(ticket, newSL, 0))
            {
               trades[i].trailLevel = 1;
               Print("CE_VIKAS TRAIL L1 [", ticket, "]: BE+", trades[i].randomBEPips);
            }
         }
      }

      //=== 5. TARGET 1 ===
      if(!trades[i].target1Hit)
      {
         bool t1Hit = false;
         if(trades[i].direction == 1 && high >= trades[i].target1)
            t1Hit = true;
         else if(trades[i].direction == -1 && low <= trades[i].target1)
            t1Hit = true;

         if(t1Hit)
         {
            trades[i].target1Hit = true;
            trades[i].tsl1Level = (trades[i].entryPrice + trades[i].target1) / 2.0;
            PartialClose(ticket, 0.33, "TARGET1 @ " + DoubleToString(trades[i].target1, digits));
         }
      }

      //=== 6. TARGET 2 ===
      if(trades[i].target1Hit && !trades[i].target2Hit)
      {
         bool t2Hit = false;
         if(trades[i].direction == 1 && high >= trades[i].target2)
            t2Hit = true;
         else if(trades[i].direction == -1 && low <= trades[i].target2)
            t2Hit = true;

         if(t2Hit)
         {
            trades[i].target2Hit = true;
            trades[i].tsl2Level = (trades[i].tsl1Level + trades[i].target2) / 2.0;
            PartialClose(ticket, 0.5, "TARGET2 @ " + DoubleToString(trades[i].target2, digits));
         }
      }

      //=== 7. TARGET 3 ===
      if(trades[i].target2Hit && !trades[i].target3Hit)
      {
         bool t3Hit = false;
         if(trades[i].direction == 1 && high >= trades[i].target3)
            t3Hit = true;
         else if(trades[i].direction == -1 && low <= trades[i].target3)
            t3Hit = true;

         if(t3Hit)
         {
            trades[i].target3Hit = true;
            ClosePosition(ticket, "TARGET3 FULL @ " + DoubleToString(trades[i].target3, digits));
            continue;
         }
      }

      //=== 8. TSL CHECKS ===
      if(trades[i].target2Hit && trades[i].tsl2Level > 0)
      {
         bool tslHit = false;
         if(trades[i].direction == 1 && low <= trades[i].tsl2Level)
            tslHit = true;
         else if(trades[i].direction == -1 && high >= trades[i].tsl2Level)
            tslHit = true;

         if(tslHit)
         {
            ClosePosition(ticket, "TSL2 @ " + DoubleToString(trades[i].tsl2Level, digits));
            continue;
         }
      }
      else if(trades[i].target1Hit && !trades[i].target2Hit && trades[i].tsl1Level > 0)
      {
         bool tslHit = false;
         if(trades[i].direction == 1 && low <= trades[i].tsl1Level)
            tslHit = true;
         else if(trades[i].direction == -1 && high >= trades[i].tsl1Level)
            tslHit = true;

         if(tslHit)
         {
            ClosePosition(ticket, "TSL1 @ " + DoubleToString(trades[i].tsl1Level, digits));
            continue;
         }
      }

      //=== 9. STEALTH SL CHECK ===
      if(!trades[i].target1Hit && !trades[i].slPlaced)
      {
         bool slHit = false;
         if(trades[i].direction == 1 && low <= trades[i].intendedSL)
            slHit = true;
         else if(trades[i].direction == -1 && high >= trades[i].intendedSL)
            slHit = true;

         if(slHit)
         {
            ClosePosition(ticket, "STEALTH SL @ " + DoubleToString(trades[i].intendedSL, digits));
            continue;
         }
      }
   }
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = stUp[0];  // SuperTrend UP line as SL
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(sl <= 0 || sl >= price)
   {
      Print("BUY cancelled: Invalid SL (", sl, ")");
      return;
   }

   double range = MathAbs(price - sl);

   // Calculate targets
   double t1 = price + range * Target1_Mult;
   double t2 = price + range * Target2_Mult;
   double t3 = price + range * Target3_Mult;

   double lots = CalculateLotSize(range);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int slDelay = RandomRange(SLDelayMin, SLDelayMax);
   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);

   // Open without SL/TP (stealth)
   if(trade.Buy(lots, _Symbol, price, 0, 0, "CE_VIKAS BUY"))
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, 1, slDelay, bePips, l2Pips);
      statBuys++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ CE_VIKAS BUY #", ticket);
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (delay ", slDelay, "s)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
      Print("║ Trail: L1=BE+", bePips, " | L2=+", l2Pips);
      Print("║ Confirmations: ST + CE + SQZM + Candle");
      Print("╚════════════════════════════════════════════════╝");
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = stDn[0];  // SuperTrend DOWN line as SL
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(sl <= 0 || sl <= price)
   {
      Print("SELL cancelled: Invalid SL (", sl, ")");
      return;
   }

   double range = MathAbs(sl - price);

   // Calculate targets
   double t1 = price - range * Target1_Mult;
   double t2 = price - range * Target2_Mult;
   double t3 = price - range * Target3_Mult;

   double lots = CalculateLotSize(range);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int slDelay = RandomRange(SLDelayMin, SLDelayMax);
   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);

   // Open without SL/TP (stealth)
   if(trade.Sell(lots, _Symbol, price, 0, 0, "CE_VIKAS SELL"))
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, -1, slDelay, bePips, l2Pips);
      statSells++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ CE_VIKAS SELL #", ticket);
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (delay ", slDelay, "s)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
      Print("║ Trail: L1=BE+", bePips, " | L2=+", l2Pips);
      Print("║ Confirmations: ST + CE + SQZM + Candle");
      Print("╚════════════════════════════════════════════════╝");
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Always manage positions
   ManageAllPositions();

   if(!IsNewBar()) return;

   // Check trading window
   if(!IsTradingWindow()) return;

   // Check max positions
   if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;

   // Check daily DD
   if(CurrentDailyDD() <= -MaxDailyDD) return;

   // FILTERS
   if(IsLargeCandle()) { statLargeCandleBlocked++; return; }
   if(!IsSpreadOK()) { statSpreadBlocked++; return; }
   if(HasActiveNews()) { statNewsBlocked++; return; }

   // GET SIGNALS (with dual confirmation)
   bool buySignal, sellSignal;
   GetSignals(buySignal, sellSignal);

   if(buySignal)
   {
      Print("═══ CE_VIKAS BUY SIGNAL (4-layer confirmed) ═══");
      OpenBuy();
   }
   else if(sellSignal)
   {
      Print("═══ CE_VIKAS SELL SIGNAL (4-layer confirmed) ═══");
      OpenSell();
   }
}

//+------------------------------------------------------------------+
double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades_total = TesterStatistics(STAT_TRADES);
   double winRate = trades_total > 0 ? TesterStatistics(STAT_PROFIT_TRADES) / trades_total * 100 : 0;

   if(trades_total < 30) return 0;
   return pf * MathSqrt(trades_total) * (winRate / 50);
}
//+------------------------------------------------------------------+
