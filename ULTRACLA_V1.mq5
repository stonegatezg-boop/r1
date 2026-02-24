//+------------------------------------------------------------------+
//|                                                  ULTRACLA_V1.mq5 |
//|   *** ULTIMATE CLA - Best of All EAs Combined ***                |
//|                                                                  |
//|   SIGNALS:                                                       |
//|   - SuperTrend direction change (primary)                        |
//|   - Squeeze Momentum confirmation                                |
//|   - EMA Trend Filter (H1)                                        |
//|   - RSI Oscillator Filter                                        |
//|   - Volume Filter                                                |
//|                                                                  |
//|   POSITION MANAGEMENT:                                           |
//|   - 3 Target Levels with Partial Closes                          |
//|   - TSL System after each target                                 |
//|   - 2-Level Human-Like Trailing                                  |
//|   - Stealth TP/SL Execution                                      |
//|                                                                  |
//|   RISK MANAGEMENT:                                               |
//|   - ATR-based SL (dynamic)                                       |
//|   - News Filter                                                  |
//|   - Spread Filter                                                |
//|   - Volatility Filter (universal points)                         |
//|   - Large Candle Filter                                          |
//|   - Daily Drawdown Limit                                         |
//|                                                                  |
//|   Version 1.0 - 2026-02-24                                       |
//+------------------------------------------------------------------+
#property copyright "ULTRACLA v1.0 (2026-02-24)"
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
   int      trailLevel;       // 0=none, 1=BE, 2=Lock
   int      randomBEPips;
   int      randomL2Pips;
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== SUPERTREND ==="
input int      ST_ATR_Period      = 14;        // SuperTrend ATR Period
input double   ST_ATR_Multiplier  = 2.5;       // SuperTrend ATR Multiplier

input group "=== SQUEEZE MOMENTUM ==="
input bool     UseSQZM            = true;      // Use Squeeze Momentum Filter
input int      SQZM_BB_Length     = 20;        // BB Period
input double   SQZM_BB_Mult       = 2.0;       // BB StdDev Multiplier
input int      SQZM_KC_Length     = 20;        // Keltner Channel Period
input double   SQZM_KC_Mult       = 1.5;       // KC Multiplier

input group "=== EMA TREND FILTER ==="
input bool     UseEMAFilter       = true;      // Use EMA Trend Filter
input int      EMA_Fast           = 20;        // Fast EMA Period
input int      EMA_Slow           = 50;        // Slow EMA Period
input ENUM_TIMEFRAMES EMA_TF      = PERIOD_H1; // EMA Timeframe

input group "=== RSI FILTER ==="
input bool     UseRSIFilter       = true;      // Use RSI Filter
input int      RSI_Period         = 14;        // RSI Period
input int      RSI_BuyLevel       = 50;        // RSI above this for BUY
input int      RSI_SellLevel      = 50;        // RSI below this for SELL

input group "=== VOLUME FILTER ==="
input bool     UseVolumeFilter    = true;      // Use Volume Filter
input int      VolumePeriod       = 20;        // Volume MA Period
input double   VolumeMultiplier   = 1.2;       // Volume must be > MA * this

input group "=== TARGETS ==="
input double   Target1_Mult       = 1.5;       // Target 1 (x ATR)
input double   Target2_Mult       = 2.5;       // Target 2 (x ATR)
input double   Target3_Mult       = 4.0;       // Target 3 (x ATR)
input double   Partial1_Percent   = 33.0;      // Close % at Target 1
input double   Partial2_Percent   = 50.0;      // Close % at Target 2

input group "=== STOP LOSS ==="
input double   SL_ATR_Mult        = 2.0;       // SL = ATR * this
input double   MinSL_Points       = 100;       // Minimum SL in points

input group "=== RISK MANAGEMENT ==="
input double   RiskPercent        = 1.0;       // Risk % per trade
input int      MaxOpenTrades      = 2;         // Max open trades
input double   MaxDailyDD         = 3.0;       // Max daily DD %
input int      CooldownBars       = 3;         // Bars between trades

input group "=== VOLATILITY FILTER (POINTS) ==="
input double   MinATR_Points      = 50;        // Min ATR in points
input double   MaxATR_Points      = 2000;      // Max ATR in points

input group "=== STEALTH EXECUTION ==="
input bool     UseStealthMode     = true;      // Use Stealth Mode
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
input int      MaxSpread          = 40;        // Max spread in points

input group "=== GENERAL ==="
input ulong    MagicNumber        = 999999;    // Magic Number
input int      Slippage           = 30;        // Slippage (points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
int            atrHandle, rsiHandle, emaFastHandle, emaSlowHandle;
datetime       lastBarTime;
datetime       lastTradeTime;
TradeData      trades[];
int            tradesCount = 0;

// SuperTrend arrays
double         stUp[], stDn[];
int            stDir[];

// Statistics
int            statBuys = 0, statSells = 0;
int            statNewsBlocked = 0, statSpreadBlocked = 0;
int            statVolBlocked = 0, statLargeCandleBlocked = 0;
int            statTrendBlocked = 0, statSQZMBlocked = 0;
int            statRSIBlocked = 0, statVolumeBlocked = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Create indicator handles
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ST_ATR_Period);
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   emaFastHandle = iMA(_Symbol, EMA_TF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, EMA_TF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initialize arrays
   ArrayResize(stUp, 3);
   ArrayResize(stDn, 3);
   ArrayResize(stDir, 3);
   ArrayInitialize(stUp, 0);
   ArrayInitialize(stDn, 0);
   ArrayInitialize(stDir, 1);

   ArrayResize(trades, 0);
   tradesCount = 0;
   lastBarTime = 0;
   lastTradeTime = 0;

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   Print("╔═══════════════════════════════════════════════════════════════╗");
   Print("║         ULTRACLA v1.0 - ULTIMATE TRADING SYSTEM               ║");
   Print("╠═══════════════════════════════════════════════════════════════╣");
   Print("║ SuperTrend: ATR(", ST_ATR_Period, ") x ", ST_ATR_Multiplier);
   Print("║ SQZM Filter: ", UseSQZM ? "ON" : "OFF");
   Print("║ EMA Filter: ", UseEMAFilter ? "ON" : "OFF", " (", EMA_Fast, "/", EMA_Slow, " on ", EnumToString(EMA_TF), ")");
   Print("║ RSI Filter: ", UseRSIFilter ? "ON" : "OFF", " (Period ", RSI_Period, ")");
   Print("║ Volume Filter: ", UseVolumeFilter ? "ON" : "OFF");
   Print("║ Targets: ", Target1_Mult, "x / ", Target2_Mult, "x / ", Target3_Mult, "x ATR");
   Print("║ SL: ", SL_ATR_Mult, "x ATR (min ", MinSL_Points, " pts)");
   Print("║ Stealth: ", UseStealthMode ? "ON" : "OFF", " | News: ", UseNewsFilter ? "ON" : "OFF");
   Print("║ Trading: Sunday 00:01 - Friday 11:30 (Server Time)");
   Print("╚═══════════════════════════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);

   Print("═══════════════════════════════════════════════════");
   Print("         ULTRACLA - FINAL STATISTICS");
   Print("═══════════════════════════════════════════════════");
   Print("Total BUY: ", statBuys, " | Total SELL: ", statSells);
   Print("Blocked by NEWS: ", statNewsBlocked);
   Print("Blocked by SPREAD: ", statSpreadBlocked);
   Print("Blocked by VOLATILITY: ", statVolBlocked);
   Print("Blocked by LARGE CANDLE: ", statLargeCandleBlocked);
   Print("Blocked by TREND: ", statTrendBlocked);
   Print("Blocked by SQZM: ", statSQZMBlocked);
   Print("Blocked by RSI: ", statRSIBlocked);
   Print("Blocked by VOLUME: ", statVolumeBlocked);
   Print("═══════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
   if(minVal >= maxVal) return minVal;
   return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
double GetATR(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double GetATRPoints(int shift = 1)
{
   double atr = GetATR(shift);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0;
   return atr / point;
}

//+------------------------------------------------------------------+
double GetRSI(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(rsiHandle, 0, shift, 1, buf) <= 0) return 50;
   return buf[0];
}

//+------------------------------------------------------------------+
bool GetEMATrend(int &trend)
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(emaFastHandle, 0, 0, 2, fast) < 2) return false;
   if(CopyBuffer(emaSlowHandle, 0, 0, 2, slow) < 2) return false;

   if(fast[0] > slow[0] && fast[1] > slow[1])
      trend = 1;   // Bullish
   else if(fast[0] < slow[0] && fast[1] < slow[1])
      trend = -1;  // Bearish
   else
      trend = 0;   // Neutral

   return true;
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
   double atr = GetATR(1);
   if(atr <= 0) return false;

   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low = iLow(_Symbol, PERIOD_CURRENT, 1);

   return ((high - low) > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   double atrPts = GetATRPoints(1);
   return (atrPts >= MinATR_Points && atrPts <= MaxATR_Points);
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
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
bool IsVolumeAboveAverage()
{
   if(!UseVolumeFilter) return true;

   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, VolumePeriod + 2, vol) <= 0) return true;

   double sum = 0;
   for(int i = 2; i < VolumePeriod + 2; i++)
      sum += (double)vol[i];

   double avg = sum / VolumePeriod;
   return ((double)vol[1] > avg * VolumeMultiplier);
}

//+------------------------------------------------------------------+
//| SUPERTREND CALCULATION                                            |
//+------------------------------------------------------------------+
void CalculateSuperTrend(int &direction, double &upLine, double &dnLine)
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, high) <= 0) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, low) <= 0) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, ST_ATR_Period + 5, close) <= 0) return;

   double atr = GetATR(1);
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
   upLine = up;
   dnLine = dn;
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
//| GET SIGNALS WITH ALL FILTERS                                      |
//+------------------------------------------------------------------+
void GetSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   // 1. Calculate SuperTrend
   int stDirection;
   double upLine, dnLine;
   CalculateSuperTrend(stDirection, upLine, dnLine);

   // Check for trend change
   bool trendChangeUp = (stDir[0] == 1 && stDir[1] == -1);
   bool trendChangeDn = (stDir[0] == -1 && stDir[1] == 1);

   if(!trendChangeUp && !trendChangeDn) return;

   // 2. EMA Trend Filter
   if(UseEMAFilter)
   {
      int emaTrend;
      if(!GetEMATrend(emaTrend)) return;

      if(trendChangeUp && emaTrend == -1)
      {
         statTrendBlocked++;
         return;
      }
      if(trendChangeDn && emaTrend == 1)
      {
         statTrendBlocked++;
         return;
      }
   }

   // 3. Squeeze Momentum Filter
   if(UseSQZM)
   {
      int sqzmDir;
      double sqzmVal = CalculateSQZM(sqzmDir);

      if(trendChangeUp)
      {
         if(sqzmVal <= 0 || sqzmDir != 1)
         {
            statSQZMBlocked++;
            return;
         }
      }
      else if(trendChangeDn)
      {
         if(sqzmVal >= 0 || sqzmDir != -1)
         {
            statSQZMBlocked++;
            return;
         }
      }
   }

   // 4. RSI Filter
   if(UseRSIFilter)
   {
      double rsi = GetRSI(1);

      if(trendChangeUp && rsi < RSI_BuyLevel)
      {
         statRSIBlocked++;
         return;
      }
      if(trendChangeDn && rsi > RSI_SellLevel)
      {
         statRSIBlocked++;
         return;
      }
   }

   // 5. Volume Filter
   if(UseVolumeFilter && !IsVolumeAboveAverage())
   {
      statVolumeBlocked++;
      return;
   }

   // 6. Candle confirmation
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(trendChangeUp && close1 <= open1) return;  // Need bullish candle
   if(trendChangeDn && close1 >= open1) return;  // Need bearish candle

   buySignal = trendChangeUp;
   sellSignal = trendChangeDn;
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
      Print("ULTRACLA CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
void PartialClose(ulong ticket, double percent, string reason)
{
   if(!PositionSelectByTicket(ticket)) return;

   double volume = PositionGetDouble(POSITION_VOLUME);
   double closeVol = NormalizeDouble(volume * percent / 100.0, 2);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(closeVol < minLot) closeVol = minLot;

   if(closeVol >= volume)
   {
      ClosePosition(ticket, reason);
      return;
   }

   if(trade.PositionClosePartial(ticket, closeVol))
      Print("ULTRACLA PARTIAL [", ticket, "]: ", reason, " (", closeVol, " lots)");
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
               Print("ULTRACLA STEALTH [", ticket, "]: SL set @ ", sl);
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

      //=== 3. TRAILING LEVEL 2 (800 pips -> Lock 150-200) ===
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
               Print("ULTRACLA TRAIL L2 [", ticket, "]: Lock +", trades[i].randomL2Pips);
            }
         }
      }

      //=== 4. TRAILING LEVEL 1 (500 pips -> BE + 38-43) ===
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
               Print("ULTRACLA TRAIL L1 [", ticket, "]: BE+", trades[i].randomBEPips);
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
            PartialClose(ticket, Partial1_Percent, "TARGET1 @ " + DoubleToString(trades[i].target1, digits));
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
            PartialClose(ticket, Partial2_Percent, "TARGET2 @ " + DoubleToString(trades[i].target2, digits));
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
            ClosePosition(ticket, "TARGET3 FULL PROFIT @ " + DoubleToString(trades[i].target3, digits));
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

      //=== 9. STEALTH SL CHECK (before broker SL placed) ===
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
   double atr = GetATR(1);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Calculate SL
   double slDist = atr * SL_ATR_Mult;
   double minSL = MinSL_Points * point;
   if(slDist < minSL) slDist = minSL;

   double sl = price - slDist;

   // Calculate targets
   double t1 = price + atr * Target1_Mult;
   double t2 = price + atr * Target2_Mult;
   double t3 = price + atr * Target3_Mult;

   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int slDelay = RandomRange(SLDelayMin, SLDelayMax);
   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);

   bool ok;
   if(UseStealthMode)
      ok = trade.Buy(lots, _Symbol, price, 0, 0, "ULTRACLA BUY");
   else
      ok = trade.Buy(lots, _Symbol, price, sl, t3, "ULTRACLA BUY");

   if(ok)
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, 1, slDelay, bePips, l2Pips);
      lastTradeTime = TimeCurrent();
      statBuys++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ ULTRACLA BUY #", ticket);
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (delay ", slDelay, "s)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
      Print("║ Trail: L1=BE+", bePips, " @ ", Trail1_Pips, "pips | L2=+", l2Pips, " @ ", Trail2_Pips, "pips");
      Print("╚════════════════════════════════════════════════╝");
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATR(1);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Calculate SL
   double slDist = atr * SL_ATR_Mult;
   double minSL = MinSL_Points * point;
   if(slDist < minSL) slDist = minSL;

   double sl = price + slDist;

   // Calculate targets
   double t1 = price - atr * Target1_Mult;
   double t2 = price - atr * Target2_Mult;
   double t3 = price - atr * Target3_Mult;

   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int slDelay = RandomRange(SLDelayMin, SLDelayMax);
   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);

   bool ok;
   if(UseStealthMode)
      ok = trade.Sell(lots, _Symbol, price, 0, 0, "ULTRACLA SELL");
   else
      ok = trade.Sell(lots, _Symbol, price, sl, t3, "ULTRACLA SELL");

   if(ok)
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, -1, slDelay, bePips, l2Pips);
      lastTradeTime = TimeCurrent();
      statSells++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ ULTRACLA SELL #", ticket);
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (delay ", slDelay, "s)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
      Print("║ Trail: L1=BE+", bePips, " @ ", Trail1_Pips, "pips | L2=+", l2Pips, " @ ", Trail2_Pips, "pips");
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

   // Check cooldown
   if(lastTradeTime > 0)
   {
      int cooldownSec = CooldownBars * PeriodSeconds(PERIOD_CURRENT);
      if(TimeCurrent() - lastTradeTime < cooldownSec) return;
   }

   // FILTERS
   if(IsLargeCandle()) { statLargeCandleBlocked++; return; }
   if(!IsVolatilityOK()) { statVolBlocked++; return; }
   if(!IsSpreadOK()) { statSpreadBlocked++; return; }
   if(HasActiveNews()) { statNewsBlocked++; return; }

   // GET SIGNALS
   bool buySignal, sellSignal;
   GetSignals(buySignal, sellSignal);

   if(buySignal)
   {
      Print("═══ ULTRACLA BUY SIGNAL ═══");
      OpenBuy();
   }
   else if(sellSignal)
   {
      Print("═══ ULTRACLA SELL SIGNAL ═══");
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
