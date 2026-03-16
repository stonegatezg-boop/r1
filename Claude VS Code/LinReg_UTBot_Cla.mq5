//+------------------------------------------------------------------+
//|                                            LinReg_UTBot_Cla.mq5  |
//|   *** LinReg Candles + UT Bot Alerts Strategy v2.2 ***           |
//|   Fixed: 05.03.2026 (Zagreb) - SL ODMAH + 3-level trail + MFE   |
//|                                                                  |
//|   Based on TradingView strategy:                                 |
//|   - Linear Regression Candles (smoothed price action)            |
//|   - UT Bot Alerts (ATR trailing stop signals)                    |
//|                                                                  |
//|   ENTRY RULES:                                                   |
//|   LONG:  LinReg candles ABOVE signal + UT Bot BUY + Green candle |
//|   SHORT: LinReg candles BELOW signal + UT Bot SELL + Red candle  |
//|                                                                  |
//|   + Full Stealth Execution                                       |
//|   + 3 Target Levels with Partial Closes                          |
//|   + TSL System + Human-Like Trailing                             |
//|                                                                  |
//|   Optimized for XAUUSD M5                                        |
//|   Version 1.0 - 2026-02-24                                       |
//+------------------------------------------------------------------+
#property copyright "LinReg_UTBot_Cla v2.2 (2026-03-05)"
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
   int      direction;
   bool     slPlaced;
   bool     target1Hit;
   bool     target2Hit;
   bool     target3Hit;
   int      trailLevel;
   int      randomBEPips;
   int      randomL2Pips;
   int      randomL3Pips;
   double   maxProfit;
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== LINEAR REGRESSION CANDLES ==="
input int      LinReg_Length       = 11;       // LinReg Period
input int      Signal_Smoothing    = 9;        // Signal Line Smoothing
input bool     Use_SMA_Signal      = true;     // Use SMA for Signal (vs EMA)

input group "=== UT BOT ALERTS ==="
input double   UTBot_KeyValue      = 3.0;      // Key Value (Sensitivity) - 3.0 for Gold
input int      UTBot_ATR_Period    = 6;        // ATR Period

input group "=== H1 TREND FILTER ==="
input bool     UseH1TrendFilter    = true;     // Use H1 EMA Trend Filter
input int      H1_EMA_Fast         = 20;       // H1 Fast EMA
input int      H1_EMA_Slow         = 50;       // H1 Slow EMA

input group "=== TARGETS ==="
input double   Target1_ATR_Mult    = 1.5;      // Target 1 (x ATR)
input double   Target2_ATR_Mult    = 2.5;      // Target 2 (x ATR)
input double   Target3_ATR_Mult    = 3.5;      // Target 3 (x ATR)

input group "=== STOP LOSS ==="
input double   SL_ATR_Mult         = 1.5;      // SL = ATR * this
input double   MinSL_Points        = 100;      // Minimum SL in points

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent         = 1.0;      // Risk % per trade
input int      MaxOpenTrades       = 3;        // Max open trades
input double   MaxDailyDD          = 3.0;      // Max daily DD %

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin          = 7;        // Min SL delay (seconds)
input int      SLDelayMax          = 13;       // Max SL delay (seconds)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR      = 3.0;      // Block if candle > X * ATR

input group "=== TRAILING STOP (3-LEVEL + MFE) ==="
input int      Trail1_Pips         = 500;      // L1: Activate at X pips
input int      Trail1_BEMin        = 38;       // L1: BE + min pips
input int      Trail1_BEMax        = 43;       // L1: BE + max pips
input int      Trail2_Pips         = 800;      // L2: Activate at X pips
input int      Trail2_LockMin      = 150;      // L2: Lock min pips
input int      Trail2_LockMax      = 200;      // L2: Lock max pips
input int      Trail3_Pips         = 1200;     // L3: Activate at X pips
input int      Trail3_LockMin      = 180;      // L3: Lock min pips
input int      Trail3_LockMax      = 220;      // L3: Lock max pips
input int      MFE_Pips            = 1500;     // MFE: Trail aktivacija (pips)
input int      MFE_TrailDist       = 500;      // MFE: Trail distance (pips)

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter       = true;     // Use News Filter
input int      NewsImportance      = 2;        // Min importance (1-3)
input int      NewsMinsBefore      = 30;       // Minutes before news
input int      NewsMinsAfter       = 30;       // Minutes after news

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter     = true;     // Use Spread Filter
input int      MaxSpread           = 40;       // Max spread in points

input group "=== GENERAL ==="
input ulong    MagicNumber         = 667799;   // Magic Number
input int      Slippage            = 30;       // Slippage (points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
int            atrHandle, h1EmaFastHandle, h1EmaSlowHandle;
datetime       lastBarTime;
TradeData      trades[];
int            tradesCount = 0;

// UT Bot variables
double         utBotTrailingStop[];
int            utBotPos[];

// Statistics
int            statBuys = 0, statSells = 0;
int            statNewsBlocked = 0, statSpreadBlocked = 0;
int            statLargeCandleBlocked = 0;
int            statLinRegBlocked = 0, statUTBotBlocked = 0;
int            statH1TrendBlocked = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, UTBot_ATR_Period);
   h1EmaFastHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h1EmaSlowHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handle");
      return INIT_FAILED;
   }

   if(UseH1TrendFilter && (h1EmaFastHandle == INVALID_HANDLE || h1EmaSlowHandle == INVALID_HANDLE))
   {
      Print("ERROR: Failed to create H1 EMA handles");
      return INIT_FAILED;
   }

   // Initialize UT Bot arrays
   ArrayResize(utBotTrailingStop, 3);
   ArrayResize(utBotPos, 3);
   ArrayInitialize(utBotTrailingStop, 0);
   ArrayInitialize(utBotPos, 0);

   ArrayResize(trades, 0);
   tradesCount = 0;
   lastBarTime = 0;

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   Print("╔═══════════════════════════════════════════════════════════════╗");
   Print("║     LINREG + UTBOT CLA v1.0 - SMOOTHED TREND STRATEGY         ║");
   Print("╠═══════════════════════════════════════════════════════════════╣");
   Print("║ LinReg: Length=", LinReg_Length, ", Signal Smoothing=", Signal_Smoothing);
   Print("║ UT Bot: Key=", UTBot_KeyValue, ", ATR Period=", UTBot_ATR_Period);
   Print("║ Targets: ", Target1_ATR_Mult, "x / ", Target2_ATR_Mult, "x / ", Target3_ATR_Mult, "x ATR");
   Print("║ SL: ", SL_ATR_Mult, "x ATR (min ", MinSL_Points, " pts)");
   Print("║ Stealth: SL delay ", SLDelayMin, "-", SLDelayMax, "s | TP hidden");
   Print("║ Trailing: L1=BE+", Trail1_BEMin, "-", Trail1_BEMax, " @ ", Trail1_Pips, "pips");
   Print("║ Trading: Sunday 00:01 - Friday 11:30 (Server Time)");
   Print("╚═══════════════════════════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(h1EmaFastHandle != INVALID_HANDLE) IndicatorRelease(h1EmaFastHandle);
   if(h1EmaSlowHandle != INVALID_HANDLE) IndicatorRelease(h1EmaSlowHandle);

   Print("═══════════════════════════════════════════════════");
   Print("     LINREG + UTBOT CLA - FINAL STATISTICS");
   Print("═══════════════════════════════════════════════════");
   Print("Total BUY: ", statBuys, " | Total SELL: ", statSells);
   Print("Blocked by NEWS: ", statNewsBlocked);
   Print("Blocked by SPREAD: ", statSpreadBlocked);
   Print("Blocked by LARGE CANDLE: ", statLargeCandleBlocked);
   Print("Blocked by LinReg position: ", statLinRegBlocked);
   Print("Blocked by H1 Trend: ", statH1TrendBlocked);
   Print("Blocked by UT Bot (no signal): ", statUTBotBlocked);
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
//| LINEAR REGRESSION FUNCTION                                        |
//+------------------------------------------------------------------+
double LinReg(const double &arr[], int period, int shift)
{
   if(ArraySize(arr) < shift + period) return 0;

   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

   for(int i = 0; i < period; i++)
   {
      double x = (double)i;
      double y = arr[shift + i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
   }

   double n = (double)period;
   double slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
   double intercept = (sumY - slope * sumX) / n;

   return intercept;  // Value at shift=0 (most recent)
}

//+------------------------------------------------------------------+
//| CALCULATE LINEAR REGRESSION CANDLES                               |
//+------------------------------------------------------------------+
void CalculateLinRegCandles(double &linOpen, double &linHigh, double &linLow, double &linClose, double &signalLine)
{
   double open[], high[], low[], close[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   int barsNeeded = LinReg_Length + Signal_Smoothing + 5;

   if(CopyOpen(_Symbol, PERIOD_CURRENT, 0, barsNeeded, open) <= 0) return;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, high) <= 0) return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, low) <= 0) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, close) <= 0) return;

   // Calculate LinReg values for bar 1 (completed candle)
   linOpen = LinReg(open, LinReg_Length, 1);
   linHigh = LinReg(high, LinReg_Length, 1);
   linLow = LinReg(low, LinReg_Length, 1);
   linClose = LinReg(close, LinReg_Length, 1);

   // Calculate signal line (SMA or EMA of LinReg Close)
   double linCloseArr[];
   ArrayResize(linCloseArr, Signal_Smoothing + 2);

   for(int i = 0; i < Signal_Smoothing + 2; i++)
   {
      linCloseArr[i] = LinReg(close, LinReg_Length, i + 1);
   }

   // Calculate signal (SMA)
   if(Use_SMA_Signal)
   {
      double sum = 0;
      for(int i = 0; i < Signal_Smoothing; i++)
         sum += linCloseArr[i];
      signalLine = sum / Signal_Smoothing;
   }
   else
   {
      // EMA
      double k = 2.0 / (Signal_Smoothing + 1);
      signalLine = linCloseArr[Signal_Smoothing - 1];
      for(int i = Signal_Smoothing - 2; i >= 0; i--)
         signalLine = linCloseArr[i] * k + signalLine * (1 - k);
   }
}

//+------------------------------------------------------------------+
//| UT BOT CALCULATION                                                |
//+------------------------------------------------------------------+
void CalculateUTBot(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   double close[];
   ArraySetAsSeries(close, true);

   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 5, close) <= 0) return;

   double atr = GetATR(1);
   if(atr <= 0) return;

   double nLoss = UTBot_KeyValue * atr;
   double src = close[1];
   double srcPrev = close[2];

   // Calculate ATR Trailing Stop
   double xATRTrailingStop = 0;
   double prevTrailingStop = utBotTrailingStop[1];

   if(src > prevTrailingStop && srcPrev > prevTrailingStop)
      xATRTrailingStop = MathMax(prevTrailingStop, src - nLoss);
   else if(src < prevTrailingStop && srcPrev < prevTrailingStop)
      xATRTrailingStop = MathMin(prevTrailingStop, src + nLoss);
   else if(src > prevTrailingStop)
      xATRTrailingStop = src - nLoss;
   else
      xATRTrailingStop = src + nLoss;

   // Determine position
   int pos = utBotPos[1];
   if(srcPrev < prevTrailingStop && src > prevTrailingStop)
      pos = 1;
   else if(srcPrev > prevTrailingStop && src < prevTrailingStop)
      pos = -1;

   // Shift arrays
   utBotTrailingStop[2] = utBotTrailingStop[1];
   utBotTrailingStop[1] = utBotTrailingStop[0];
   utBotTrailingStop[0] = xATRTrailingStop;

   utBotPos[2] = utBotPos[1];
   utBotPos[1] = utBotPos[0];
   utBotPos[0] = pos;

   // Generate signals
   bool above = (src > xATRTrailingStop) && (srcPrev <= prevTrailingStop || prevTrailingStop == 0);
   bool below = (src < xATRTrailingStop) && (srcPrev >= prevTrailingStop || prevTrailingStop == 0);

   buySignal = (src > xATRTrailingStop) && above;
   sellSignal = (src < xATRTrailingStop) && below;
}

//+------------------------------------------------------------------+
//| GET SIGNALS                                                       |
//+------------------------------------------------------------------+
int GetH1Trend()
{
   if(!UseH1TrendFilter) return 0;  // No filter = allow all

   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(h1EmaFastHandle, 0, 0, 2, fast) < 2) return 0;
   if(CopyBuffer(h1EmaSlowHandle, 0, 0, 2, slow) < 2) return 0;

   if(fast[0] > slow[0]) return 1;   // Bullish
   if(fast[0] < slow[0]) return -1;  // Bearish
   return 0;
}

void GetSignals(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   // 0. Check H1 Trend Filter first
   int h1Trend = GetH1Trend();

   // 1. Calculate Linear Regression Candles
   double linOpen, linHigh, linLow, linClose, signalLine;
   CalculateLinRegCandles(linOpen, linHigh, linLow, linClose, signalLine);

   if(signalLine == 0) return;

   // Check LinReg candle position relative to signal line
   bool linRegAbove = (linClose > signalLine);
   bool linRegBelow = (linClose < signalLine);

   // Check LinReg candle color
   bool linRegGreen = (linClose > linOpen);  // Bullish
   bool linRegRed = (linClose < linOpen);    // Bearish

   // 2. Calculate UT Bot
   bool utBotBuy, utBotSell;
   CalculateUTBot(utBotBuy, utBotSell);

   // 3. Combined signals with H1 trend filter
   // LONG: H1 bullish (or neutral) + LinReg above signal + Green candle + UT Bot Buy
   if(utBotBuy)
   {
      if(UseH1TrendFilter && h1Trend == -1)
      {
         statH1TrendBlocked++;
         Print("BUY blocked: H1 trend is BEARISH");
         return;
      }

      if(linRegAbove && linRegGreen)
      {
         buySignal = true;
         Print("BUY: LinReg Close=", DoubleToString(linClose, _Digits),
               " > Signal=", DoubleToString(signalLine, _Digits),
               ", H1=", (h1Trend == 1 ? "BULL" : "NEUTRAL"));
      }
      else
      {
         statLinRegBlocked++;
         Print("BUY blocked: LinReg Above=", linRegAbove, ", Green=", linRegGreen);
      }
   }

   // SHORT: H1 bearish (or neutral) + LinReg below signal + Red candle + UT Bot Sell
   if(utBotSell)
   {
      if(UseH1TrendFilter && h1Trend == 1)
      {
         statH1TrendBlocked++;
         Print("SELL blocked: H1 trend is BULLISH");
         return;
      }

      if(linRegBelow && linRegRed)
      {
         sellSignal = true;
         Print("SELL: LinReg Close=", DoubleToString(linClose, _Digits),
               " < Signal=", DoubleToString(signalLine, _Digits),
               ", H1=", (h1Trend == -1 ? "BEAR" : "NEUTRAL"));
      }
      else
      {
         statLinRegBlocked++;
         Print("SELL blocked: LinReg Below=", linRegBelow, ", Red=", linRegRed);
      }
   }
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
              double t1, double t2, double t3, int dir, int bePips, int l2Pips, int l3Pips)
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
   trades[tradesCount].slDelaySeconds = 0;
   trades[tradesCount].direction = dir;
   trades[tradesCount].slPlaced = true;  // SL ODMAH postavljen
   trades[tradesCount].target1Hit = false;
   trades[tradesCount].target2Hit = false;
   trades[tradesCount].target3Hit = false;
   trades[tradesCount].trailLevel = 0;
   trades[tradesCount].randomBEPips = bePips;
   trades[tradesCount].randomL2Pips = l2Pips;
   trades[tradesCount].randomL3Pips = l3Pips;
   trades[tradesCount].maxProfit = 0;
   tradesCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
   if(trade.PositionClose(ticket))
      Print("LINREG_UTBOT CLOSE [", ticket, "]: ", reason);
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
      Print("LINREG_UTBOT PARTIAL [", ticket, "]: ", reason, " (", closeVol, " lots)");
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

      //=== 1. BACKUP SL CHECK (ako SL nije postavljen) ===
      if(!trades[i].slPlaced && trades[i].intendedSL != 0)
      {
         double sl = NormalizeDouble(trades[i].intendedSL, digits);
         if(trade.PositionModify(ticket, sl, 0))
         {
            trades[i].slPlaced = true;
            Print("BACKUP SL [", ticket, "]: @ ", sl);
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

      //=== 3. 3-LEVEL TRAILING + MFE ===
      double profitPips = (trades[i].direction == 1)
         ? (currentPrice - trades[i].entryPrice) / point
         : (trades[i].entryPrice - currentPrice) / point;

      // Update MFE
      if(profitPips > trades[i].maxProfit)
         trades[i].maxProfit = profitPips;

      // MFE TRAILING - ako profit >= MFE_Pips, trail MFE_TrailDist iza max
      if(trades[i].trailLevel >= 3 && profitPips >= MFE_Pips)
      {
         double mfeSL;
         if(trades[i].direction == 1)
         {
            mfeSL = trades[i].entryPrice + (trades[i].maxProfit - MFE_TrailDist) * point;
            mfeSL = NormalizeDouble(mfeSL, digits);
            if(mfeSL > currentSL && trade.PositionModify(ticket, mfeSL, 0))
               Print("MFE TRAIL [", ticket, "]: @ ", mfeSL, " (max: ", (int)trades[i].maxProfit, " pips)");
         }
         else
         {
            mfeSL = trades[i].entryPrice - (trades[i].maxProfit - MFE_TrailDist) * point;
            mfeSL = NormalizeDouble(mfeSL, digits);
            if((mfeSL < currentSL || currentSL == 0) && trade.PositionModify(ticket, mfeSL, 0))
               Print("MFE TRAIL [", ticket, "]: @ ", mfeSL, " (max: ", (int)trades[i].maxProfit, " pips)");
         }
      }
      // L3: Lock 180-220 pips @ 1200 pips profit
      else if(trades[i].trailLevel == 2 && profitPips >= Trail3_Pips)
      {
         double newSL;
         if(trades[i].direction == 1)
            newSL = trades[i].entryPrice + trades[i].randomL3Pips * point;
         else
            newSL = trades[i].entryPrice - trades[i].randomL3Pips * point;

         newSL = NormalizeDouble(newSL, digits);
         bool shouldMod = (trades[i].direction == 1 && newSL > currentSL) ||
                          (trades[i].direction == -1 && (newSL < currentSL || currentSL == 0));

         if(shouldMod && trade.PositionModify(ticket, newSL, 0))
         {
            trades[i].trailLevel = 3;
            Print("TRAIL L3 [", ticket, "]: Lock +", trades[i].randomL3Pips);
         }
      }
      // L2: Lock 150-200 pips @ 800 pips profit
      else if(trades[i].trailLevel == 1 && profitPips >= Trail2_Pips)
      {
         double newSL;
         if(trades[i].direction == 1)
            newSL = trades[i].entryPrice + trades[i].randomL2Pips * point;
         else
            newSL = trades[i].entryPrice - trades[i].randomL2Pips * point;

         newSL = NormalizeDouble(newSL, digits);
         bool shouldMod = (trades[i].direction == 1 && newSL > currentSL) ||
                          (trades[i].direction == -1 && (newSL < currentSL || currentSL == 0));

         if(shouldMod && trade.PositionModify(ticket, newSL, 0))
         {
            trades[i].trailLevel = 2;
            Print("TRAIL L2 [", ticket, "]: Lock +", trades[i].randomL2Pips);
         }
      }
      // L1: BE + 38-43 pips @ 500 pips profit
      else if(trades[i].trailLevel == 0 && profitPips >= Trail1_Pips)
      {
         double newSL;
         if(trades[i].direction == 1)
            newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
         else
            newSL = trades[i].entryPrice - trades[i].randomBEPips * point;

         newSL = NormalizeDouble(newSL, digits);
         bool shouldMod = (trades[i].direction == 1 && newSL > currentSL) ||
                          (trades[i].direction == -1 && (newSL < currentSL || currentSL == 0));

         if(shouldMod && trade.PositionModify(ticket, newSL, 0))
         {
            trades[i].trailLevel = 1;
            Print("TRAIL L1 [", ticket, "]: BE+", trades[i].randomBEPips);
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
   double atr = GetATR(1);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Calculate SL
   double slDist = atr * SL_ATR_Mult;
   double minSL = MinSL_Points * point;
   if(slDist < minSL) slDist = minSL;

   double sl = price - slDist;

   // Calculate targets
   double t1 = price + atr * Target1_ATR_Mult;
   double t2 = price + atr * Target2_ATR_Mult;
   double t3 = price + atr * Target3_ATR_Mult;

   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);
   int l3Pips = RandomRange(Trail3_LockMin, Trail3_LockMax);

   // SL ODMAH - postavlja se odmah pri otvaranju trejda
   if(trade.Buy(lots, _Symbol, price, sl, 0, "LINREG_UTBOT BUY"))
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, 1, bePips, l2Pips, l3Pips);
      statBuys++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ LINREG_UTBOT BUY #", ticket, " (SL ODMAH)");
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (ODMAH!)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3, " (STEALTH)");
      Print("║ Trail: L1=BE+", bePips, " | L2=+", l2Pips, " | L3=+", l3Pips);
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
   double t1 = price - atr * Target1_ATR_Mult;
   double t2 = price - atr * Target2_ATR_Mult;
   double t3 = price - atr * Target3_ATR_Mult;

   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;

   sl = NormalizeDouble(sl, digits);
   t1 = NormalizeDouble(t1, digits);
   t2 = NormalizeDouble(t2, digits);
   t3 = NormalizeDouble(t3, digits);

   int bePips = RandomRange(Trail1_BEMin, Trail1_BEMax);
   int l2Pips = RandomRange(Trail2_LockMin, Trail2_LockMax);
   int l3Pips = RandomRange(Trail3_LockMin, Trail3_LockMax);

   // SL ODMAH - postavlja se odmah pri otvaranju trejda
   if(trade.Sell(lots, _Symbol, price, sl, 0, "LINREG_UTBOT SELL"))
   {
      ulong ticket = trade.ResultOrder();
      AddTrade(ticket, price, sl, t3, t1, t2, t3, -1, bePips, l2Pips, l3Pips);
      statSells++;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ LINREG_UTBOT SELL #", ticket, " (SL ODMAH)");
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", price, " | Lots: ", lots);
      Print("║ SL: ", sl, " (ODMAH!)");
      Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3, " (STEALTH)");
      Print("║ Trail: L1=BE+", bePips, " | L2=+", l2Pips, " | L3=+", l3Pips);
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

   // GET SIGNALS
   bool buySignal, sellSignal;
   GetSignals(buySignal, sellSignal);

   if(buySignal)
   {
      Print("═══ LINREG_UTBOT BUY SIGNAL ═══");
      OpenBuy();
   }
   else if(sellSignal)
   {
      Print("═══ LINREG_UTBOT SELL SIGNAL ═══");
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
