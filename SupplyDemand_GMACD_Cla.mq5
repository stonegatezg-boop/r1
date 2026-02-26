//+------------------------------------------------------------------+
//|                                       SupplyDemand_GMACD_Cla.mq5 |
//|                     Supply/Demand Pattern + Gaussian MACD HA     |
//|                                          Za XAUUSD M5            |
//|                   Created: 26.02.2026 14:00 (Zagreb)             |
//|                   Fixed: 26.02.2026 20:15 (Zagreb)               |
//|                   - Dodani timestamps za verzioniranje           |
//|                   - Poboljšan pattern lookback (10 umjesto 15)   |
//+------------------------------------------------------------------+
#property copyright "Claude"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETRI                                                    |
//+------------------------------------------------------------------+
// === OSNOVNI ===
input string   INFO1 = "=== OSNOVNI PARAMETRI ===";
input double   LotSize = 0.01;
input int      MagicNumber = 556677;
input double   MaxSpread = 50;

// === SUPPLY/DEMAND PATTERN ===
input string   INFO2 = "=== SUPPLY/DEMAND PATTERN ===";
input int      CandleHealthPercent = 60;     // Min candle health %
input double   BaseMaxRetracement = 0.5;     // Max base retracement (0.5-0.8)
input int      PatternLookback = 10;         // Bars to look back for pattern

// === GAUSSIAN MACD ===
input string   INFO3 = "=== GAUSSIAN MACD ===";
input int      GMACD_FastLength = 12;
input int      GMACD_SlowLength = 26;
input int      GMACD_SmoothLen = 14;
input int      GMACD_SignalLen = 9;

// === TARGETS (PIPS) ===
input string   INFO4 = "=== TARGETS (PIPS) ===";
input int      Target1_Pips = 300;
input int      Target2_Pips = 500;
input int      Target3_Pips = 800;

// === TRAILING STOP ===
input string   INFO5 = "=== TRAILING STOP ===";
input int      TrailingStart1 = 500;
input int      BEOffset_Min = 38;
input int      BEOffset_Max = 43;
input int      TrailingStart2 = 800;
input int      LockProfit_Min = 150;
input int      LockProfit_Max = 200;

// === STEALTH POSTAVKE ===
input string   INFO6 = "=== STEALTH ===";
input int      StealthSL_DelayMin = 7;
input int      StealthSL_DelayMax = 13;
input bool     UseDynamicSL = true;          // Koristi zone level za SL

// === FILTERI ===
input string   INFO7 = "=== FILTERI ===";
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 3.0;

// === TRADING WINDOW ===
input string   INFO8 = "=== TRADING WINDOW ===";
input bool     UseTradingWindow = true;
input int      FridayCloseHour = 11;
input int      FridayCloseMinute = 30;

//+------------------------------------------------------------------+
//| GLOBALNE VARIJABLE                                                |
//+------------------------------------------------------------------+
CTrade trade;

// Position tracking
bool     hasOpenPosition = false;
ulong    currentTicket = 0;
double   entryPrice = 0;
int      positionType = -1;
datetime entryTime = 0;

// Target tracking
bool     target1Hit = false;
bool     target2Hit = false;
double   originalLots = 0;

// Stealth SL
bool     slSentToBroker = false;
datetime slSendTime = 0;
int      slDelaySeconds = 0;
double   dynamicSLPrice = 0;

// Trailing
bool     trailingLevel1Done = false;
bool     trailingLevel2Done = false;

// Points conversion
double   pipValue;
int      pipDigits;

// Supply/Demand Pattern State
int      bullPass = 0;
int      bearPass = 0;
double   bullLow1 = 0, bullHigh = 0, bullLow2 = 0;
double   bearHigh1 = 0, bearLow = 0, bearHigh2 = 0;
int      bullLineX1 = 0, bearLineX1 = 0;
int      bullFinalLoopIndex = 0;
double   bullZoneTop = 0, bullZoneBottom = 0;
double   bearZoneTop = 0, bearZoneBottom = 0;
int      activePattern = 0;  // 1 = RBR, -1 = DBD

// Gaussian Filter buffers
double   gaussFastBuffer[];
double   gaussSlowBuffer[];
double   gaussRangeBuffer[];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 2)
   {
      pipValue = 0.1;
      pipDigits = 1;
   }
   else
   {
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      pipDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) - 1;
   }

   ArrayResize(gaussFastBuffer, 100);
   ArrayResize(gaussSlowBuffer, 100);
   ArrayResize(gaussRangeBuffer, 100);
   ArrayInitialize(gaussFastBuffer, 0);
   ArrayInitialize(gaussSlowBuffer, 0);
   ArrayInitialize(gaussRangeBuffer, 0);

   CheckExistingPosition();

   Print("SupplyDemand_GMACD_Cla initialized. Pip value: ", pipValue);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("SupplyDemand_GMACD_Cla removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(hasOpenPosition)
   {
      ManagePosition();
      return;
   }

   if(!CanTrade()) return;

   int signal = GetSignal();

   if(signal == 1)
      OpenBuy();
   else if(signal == -1)
      OpenSell();
}

//+------------------------------------------------------------------+
//| GAUSSIAN FILTER                                                    |
//+------------------------------------------------------------------+
double GaussianFilter(double &buffer[], double value, int length)
{
   double beta = (1.0 - MathCos(2.0 * M_PI / length)) / (MathPow(2.0, 1.0 / 1.0) - 1.0);
   double alpha = -beta + MathSqrt(MathPow(beta, 2) + 2.0 * beta);

   double prevFilter = buffer[0];
   double newFilter = alpha * value + (1.0 - alpha) * prevFilter;

   // Shift buffer
   for(int i = ArraySize(buffer) - 1; i > 0; i--)
      buffer[i] = buffer[i-1];
   buffer[0] = newFilter;

   return newFilter;
}

//+------------------------------------------------------------------+
//| NORMALIZED GAUSSIAN MACD                                          |
//+------------------------------------------------------------------+
void CalculateGaussianMACD(double &haOpen, double &haHigh, double &haLow, double &haClose, double &histogram)
{
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   double highPrice = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lowPrice = iLow(_Symbol, PERIOD_CURRENT, 1);
   double range = highPrice - lowPrice;

   // Gaussian filtered values
   double gfFast = GaussianFilter(gaussFastBuffer, closePrice, GMACD_FastLength);
   double gfSlow = GaussianFilter(gaussSlowBuffer, closePrice, GMACD_SlowLength);
   double gfRange = GaussianFilter(gaussRangeBuffer, range, GMACD_SlowLength);

   // Normalized MACD
   double macdRaw = 0;
   if(gfRange > 0)
      macdRaw = ((gfFast - gfSlow) / gfRange) * 100;

   // HMA smoothing (simplified as EMA for MQL5)
   static double macdSmoothed = 0;
   static double signalLine = 0;

   double smoothAlpha = 2.0 / (GMACD_SmoothLen + 1);
   macdSmoothed = smoothAlpha * macdRaw + (1 - smoothAlpha) * macdSmoothed;

   double signalAlpha = 2.0 / (GMACD_SignalLen + 1);
   signalLine = signalAlpha * macdSmoothed + (1 - signalAlpha) * signalLine;

   histogram = macdSmoothed - signalLine;

   // Heikin Ashi transformation of MACD
   static double prevHaOpen = 0;
   static double prevHaClose = 0;

   double openMACD = macdSmoothed;
   double highMACD = MathMax(macdSmoothed, macdSmoothed);
   double lowMACD = MathMin(macdSmoothed, macdSmoothed);
   double closeMACD = macdSmoothed;

   haClose = (openMACD + highMACD + lowMACD + closeMACD) / 4.0;

   if(prevHaOpen == 0 && prevHaClose == 0)
      haOpen = (openMACD + closeMACD) / 2.0;
   else
      haOpen = (prevHaOpen + prevHaClose) / 2.0;

   haHigh = MathMax(highMACD, MathMax(haOpen, haClose));
   haLow = MathMin(lowMACD, MathMin(haOpen, haClose));

   prevHaOpen = haOpen;
   prevHaClose = haClose;
}

//+------------------------------------------------------------------+
//| CANDLE BODY HEALTH                                                |
//+------------------------------------------------------------------+
double GetCandleHealth(int shift)
{
   double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double low = iLow(_Symbol, PERIOD_CURRENT, shift);
   double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   double totalRange = high - low;
   if(totalRange == 0) return 0;

   double body = MathAbs(close - open);
   double wick = totalRange - body;

   // Health = kako malo wicka ima (100 = sve body, 0 = sve wick)
   return (body / totalRange) * 100;
}

//+------------------------------------------------------------------+
//| DETECT RBR PATTERN (Rally-Base-Rally)                             |
//+------------------------------------------------------------------+
bool DetectRBRPattern(double &zoneTop, double &zoneBottom)
{
   // Tražimo RBR pattern:
   // 1. Rally (bullish candles with good health)
   // 2. Base (consolidation/retracement)
   // 3. Rally (breakout above previous high)

   double rallyHighs[];
   double rallyLows[];
   ArrayResize(rallyHighs, PatternLookback);
   ArrayResize(rallyLows, PatternLookback);

   int rallyCount = 0;
   double firstRallyHigh = 0;
   double firstRallyLow = 0;
   bool foundBase = false;
   double baseHigh = 0;
   double baseLow = 999999;
   int healthyCandles = 0;

   // Scan backwards
   for(int i = 2; i < PatternLookback + 10; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      bool bullish = close > open;

      double health = GetCandleHealth(i);

      // First Rally detection
      if(rallyCount == 0 && bullish)
      {
         if(health >= CandleHealthPercent)
            healthyCandles++;

         if(firstRallyHigh == 0) firstRallyHigh = high;
         else firstRallyHigh = MathMax(firstRallyHigh, high);

         if(firstRallyLow == 0) firstRallyLow = low;
         else firstRallyLow = MathMin(firstRallyLow, low);

         rallyCount++;
      }
      else if(rallyCount > 0 && !bullish && !foundBase)
      {
         // Base detection
         foundBase = true;
         baseHigh = high;
         baseLow = low;
      }
      else if(foundBase && !bullish)
      {
         baseHigh = MathMax(baseHigh, high);
         baseLow = MathMin(baseLow, low);
      }
      else if(foundBase && bullish)
      {
         // End of pattern scan
         break;
      }
   }

   if(healthyCandles == 0 || !foundBase) return false;

   // Check current candle for breakout (second rally)
   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double currentOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   bool currentBullish = currentClose > currentOpen;

   if(!currentBullish) return false;

   // Check retracement condition
   double rallyRange = firstRallyHigh - firstRallyLow;
   if(rallyRange == 0) return false;

   double retracementLevel = firstRallyLow + rallyRange * (1 - BaseMaxRetracement);

   // Base low should not retrace too much
   if(baseLow < retracementLevel) return false;

   // Breakout confirmation
   if(currentClose > firstRallyHigh)
   {
      zoneTop = baseHigh;
      zoneBottom = baseLow;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| DETECT DBD PATTERN (Drop-Base-Drop)                               |
//+------------------------------------------------------------------+
bool DetectDBDPattern(double &zoneTop, double &zoneBottom)
{
   // Tražimo DBD pattern:
   // 1. Drop (bearish candles with good health)
   // 2. Base (consolidation/retracement)
   // 3. Drop (breakdown below previous low)

   int dropCount = 0;
   double firstDropHigh = 0;
   double firstDropLow = 999999;
   bool foundBase = false;
   double baseHigh = 0;
   double baseLow = 999999;
   int healthyCandles = 0;

   // Scan backwards
   for(int i = 2; i < PatternLookback + 10; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      bool bearish = close < open;

      double health = GetCandleHealth(i);

      // First Drop detection
      if(dropCount == 0 && bearish)
      {
         if(health >= CandleHealthPercent)
            healthyCandles++;

         if(firstDropHigh == 0) firstDropHigh = high;
         else firstDropHigh = MathMax(firstDropHigh, high);

         firstDropLow = MathMin(firstDropLow, low);

         dropCount++;
      }
      else if(dropCount > 0 && !bearish && !foundBase)
      {
         // Base detection
         foundBase = true;
         baseHigh = high;
         baseLow = low;
      }
      else if(foundBase && !bearish)
      {
         baseHigh = MathMax(baseHigh, high);
         baseLow = MathMin(baseLow, low);
      }
      else if(foundBase && bearish)
      {
         // End of pattern scan
         break;
      }
   }

   if(healthyCandles == 0 || !foundBase) return false;

   // Check current candle for breakdown (second drop)
   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double currentOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   bool currentBearish = currentClose < currentOpen;

   if(!currentBearish) return false;

   // Check retracement condition
   double dropRange = firstDropHigh - firstDropLow;
   if(dropRange == 0) return false;

   double retracementLevel = firstDropHigh - dropRange * (1 - BaseMaxRetracement);

   // Base high should not retrace too much
   if(baseHigh > retracementLevel) return false;

   // Breakdown confirmation
   if(currentClose < firstDropLow)
   {
      zoneTop = baseHigh;
      zoneBottom = baseLow;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIKA                                                      |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. Get Gaussian MACD HA values
   double haOpen, haHigh, haLow, haClose, histogram;
   CalculateGaussianMACD(haOpen, haHigh, haLow, haClose, histogram);

   // Heikin Ashi MACD direction
   bool haBullish = haClose > haOpen;
   bool haBearish = haClose < haOpen;

   // Histogram direction
   bool histBullish = histogram > 0;
   bool histBearish = histogram < 0;

   // 2. Current candle
   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double currentOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   bool candleBullish = currentClose > currentOpen;
   bool candleBearish = currentClose < currentOpen;

   // 3. Check patterns
   double zoneTop = 0, zoneBottom = 0;

   // BUY: RBR pattern + bullish candle + bullish HA MACD + bullish histogram
   if(DetectRBRPattern(zoneTop, zoneBottom))
   {
      if(candleBullish && haBullish && histBullish)
      {
         bullZoneTop = zoneTop;
         bullZoneBottom = zoneBottom;
         dynamicSLPrice = zoneBottom - 50 * pipValue;  // SL below zone
         Print("RBR Signal! Zone: ", zoneBottom, " - ", zoneTop, " | HA Bullish: ", haBullish, " | Hist: ", histogram);
         return 1;
      }
   }

   // SELL: DBD pattern + bearish candle + bearish HA MACD + bearish histogram
   if(DetectDBDPattern(zoneTop, zoneBottom))
   {
      if(candleBearish && haBearish && histBearish)
      {
         bearZoneTop = zoneTop;
         bearZoneBottom = zoneBottom;
         dynamicSLPrice = zoneTop + 50 * pipValue;  // SL above zone
         Print("DBD Signal! Zone: ", zoneBottom, " - ", zoneTop, " | HA Bearish: ", haBearish, " | Hist: ", histogram);
         return -1;
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| PROVJERA MOŽE LI SE TREJDATI                                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   if(UseTradingWindow && !IsTradingTime())
      return false;

   if(UseSpreadFilter)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadPips = spread * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / pipValue;
      if(spreadPips > MaxSpread)
         return false;
   }

   if(UseLargeCandleFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
      CopyBuffer(atrHandle, 0, 0, 2, atr);
      IndicatorRelease(atrHandle);

      double candleSize = MathAbs(iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1));
      if(candleSize > atr[1] * LargeCandleATR)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| TRADING WINDOW CHECK                                               |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 && (dt.hour == 0 && dt.min < 1))
      return false;

   if(dt.day_of_week == 5)
   {
      if(dt.hour > FridayCloseHour || (dt.hour == FridayCloseHour && dt.min >= FridayCloseMinute))
         return false;
   }

   if(dt.day_of_week == 6)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                           |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "SD_GMACD BUY"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = ask;
      positionType = 0;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      target1Hit = false;
      target2Hit = false;
      slSentToBroker = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      slDelaySeconds = StealthSL_DelayMin + MathRand() % (StealthSL_DelayMax - StealthSL_DelayMin + 1);
      slSendTime = TimeCurrent() + slDelaySeconds;

      Print("BUY opened at ", ask, ". Dynamic SL at ", dynamicSLPrice);
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                          |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "SD_GMACD SELL"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = bid;
      positionType = 1;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      target1Hit = false;
      target2Hit = false;
      slSentToBroker = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      slDelaySeconds = StealthSL_DelayMin + MathRand() % (StealthSL_DelayMax - StealthSL_DelayMin + 1);
      slSendTime = TimeCurrent() + slDelaySeconds;

      Print("SELL opened at ", bid, ". Dynamic SL at ", dynamicSLPrice);
   }
}

//+------------------------------------------------------------------+
//| MANAGE POSITION                                                    |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!PositionSelectByTicket(currentTicket))
   {
      hasOpenPosition = false;
      Print("Position closed externally");
      return;
   }

   double currentPrice = (positionType == 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPips = 0;

   if(positionType == 0)
      profitPips = (currentPrice - entryPrice) / pipValue;
   else
      profitPips = (entryPrice - currentPrice) / pipValue;

   // Stealth SL
   if(!slSentToBroker && TimeCurrent() >= slSendTime)
      SendStealthSL();

   // Stealth TP - check targets
   CheckTargets(profitPips, currentPrice);

   // Trailing
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
//| SEND STEALTH SL                                                    |
//+------------------------------------------------------------------+
void SendStealthSL()
{
   double slPrice = 0;

   if(UseDynamicSL && dynamicSLPrice > 0)
   {
      slPrice = dynamicSLPrice;
   }
   else
   {
      // Default SL based on entry
      if(positionType == 0)
         slPrice = entryPrice - 500 * pipValue;
      else
         slPrice = entryPrice + 500 * pipValue;
   }

   slPrice = NormalizeDouble(slPrice, _Digits);

   if(trade.PositionModify(currentTicket, slPrice, 0))
   {
      slSentToBroker = true;
      Print("Stealth SL sent at ", slPrice, " (delayed ", slDelaySeconds, "s)");
   }
}

//+------------------------------------------------------------------+
//| CHECK TARGETS (STEALTH TP)                                        |
//+------------------------------------------------------------------+
void CheckTargets(double profitPips, double currentPrice)
{
   double currentLots = PositionGetDouble(POSITION_VOLUME);

   if(!target1Hit && profitPips >= Target1_Pips)
   {
      double closeSize = NormalizeDouble(originalLots * 0.33, 2);
      if(closeSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         closeSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(closeSize <= currentLots)
      {
         if(trade.PositionClosePartial(currentTicket, closeSize))
         {
            target1Hit = true;
            Print("Target 1 hit! Closed 33% at ", currentPrice, " (+", profitPips, " pips)");
         }
      }
   }

   if(!target2Hit && target1Hit && profitPips >= Target2_Pips)
   {
      currentLots = PositionGetDouble(POSITION_VOLUME);
      double closeSize = NormalizeDouble(currentLots * 0.50, 2);
      if(closeSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         closeSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(closeSize <= currentLots)
      {
         if(trade.PositionClosePartial(currentTicket, closeSize))
         {
            target2Hit = true;
            Print("Target 2 hit! Closed 50% at ", currentPrice, " (+", profitPips, " pips)");
         }
      }
   }

   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("Target 3 hit! Closed all at ", currentPrice, " (+", profitPips, " pips)");
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE TRAILING STOP                                               |
//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   if(!slSentToBroker) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double newSL = currentSL;

   if(!trailingLevel1Done && profitPips >= TrailingStart1)
   {
      int offset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

      if(positionType == 0)
         newSL = entryPrice + offset * pipValue;
      else
         newSL = entryPrice - offset * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);

      if(trade.PositionModify(currentTicket, newSL, 0))
      {
         trailingLevel1Done = true;
         Print("Trailing Level 1: SL moved to BE + ", offset, " pips");
      }
   }

   if(!trailingLevel2Done && trailingLevel1Done && profitPips >= TrailingStart2)
   {
      int lockPips = LockProfit_Min + MathRand() % (LockProfit_Max - LockProfit_Min + 1);

      if(positionType == 0)
         newSL = entryPrice + lockPips * pipValue;
      else
         newSL = entryPrice - lockPips * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);

      if(trade.PositionModify(currentTicket, newSL, 0))
      {
         trailingLevel2Done = true;
         Print("Trailing Level 2: Locked ", lockPips, " pips profit");
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK EXISTING POSITION                                            |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            currentTicket = ticket;
            entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positionType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 0 : 1;
            entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            hasOpenPosition = true;
            originalLots = PositionGetDouble(POSITION_VOLUME);
            slSentToBroker = (PositionGetDouble(POSITION_SL) != 0);

            Print("Existing position found. Ticket: ", ticket);
            break;
         }
      }
   }
}
//+------------------------------------------------------------------+
