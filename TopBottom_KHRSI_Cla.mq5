//+------------------------------------------------------------------+
//|                                          TopBottom_KHRSI_Cla.mq5 |
//|                   EMA20 Pullback Engulf + Kalman Hull RSI        |
//|                                          Za XAUUSD M5            |
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
input int      MagicNumber = 778800;
input double   MaxSpread = 50;

// === EMA PULLBACK ENGULF ===
input string   INFO2 = "=== EMA PULLBACK ENGULF ===";
input int      EMA_Fast = 10;
input int      EMA_Slow = 20;
input int      PullbackCandles = 3;           // Max pullback candles to check

// === KALMAN HULL RSI ===
input string   INFO3 = "=== KALMAN HULL RSI ===";
input double   KalmanNoise = 3.0;             // Measurement Noise (like period)
input double   KalmanProcess = 0.01;          // Process Noise
input int      RSI_Period = 12;               // RSI Period

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
input int      SL_Pips = 300;

// === FILTERI ===
input string   INFO7 = "=== FILTERI ===";
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 3.0;
input bool     UseVWAPFilter = true;          // VWAP trend filter

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

// Trailing
bool     trailingLevel1Done = false;
bool     trailingLevel2Done = false;

// Points conversion
double   pipValue;
int      pipDigits;

// Kalman filter state
double   kalmanState = 0;
double   kalmanCovariance = 1.0;

// EMA handles
int      emaFastHandle;
int      emaSlowHandle;

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

   // Create EMA handles
   emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
   {
      Print("Error creating EMA handles");
      return(INIT_FAILED);
   }

   // Initialize Kalman
   kalmanState = iClose(_Symbol, PERIOD_CURRENT, 1);

   CheckExistingPosition();

   Print("TopBottom_KHRSI_Cla initialized. Pip value: ", pipValue);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
   Print("TopBottom_KHRSI_Cla removed. Reason: ", reason);
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
//| KALMAN FILTER                                                      |
//+------------------------------------------------------------------+
double KalmanFilter(double measurement)
{
   // Prediction
   double predictedState = kalmanState;
   double predictedCovariance = kalmanCovariance + KalmanProcess;

   // Update
   double kalmanGain = predictedCovariance / (predictedCovariance + KalmanNoise);
   kalmanState = predictedState + kalmanGain * (measurement - predictedState);
   kalmanCovariance = (1 - kalmanGain) * predictedCovariance;

   return kalmanState;
}

//+------------------------------------------------------------------+
//| KALMAN HULL MA                                                     |
//+------------------------------------------------------------------+
double CalculateKalmanHull(int shift)
{
   // Hull MA concept: 2*WMA(n/2) - WMA(n), then WMA(sqrt(n))
   // But using Kalman filter instead of WMA

   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   // Simple Kalman Hull approximation
   // kf1 = Kalman(close, period/2)
   // kf2 = Kalman(close, period)
   // result = Kalman(2*kf1 - kf2, sqrt(period))

   static double kf1State = 0, kf1Cov = 1.0;
   static double kf2State = 0, kf2Cov = 1.0;
   static double kfHullState = 0, kfHullCov = 1.0;

   double halfNoise = KalmanNoise / 2;
   double sqrtNoise = MathSqrt(KalmanNoise);

   // KF1 (fast)
   double predState1 = kf1State;
   double predCov1 = kf1Cov + KalmanProcess;
   double gain1 = predCov1 / (predCov1 + halfNoise);
   kf1State = predState1 + gain1 * (close - predState1);
   kf1Cov = (1 - gain1) * predCov1;

   // KF2 (slow)
   double predState2 = kf2State;
   double predCov2 = kf2Cov + KalmanProcess;
   double gain2 = predCov2 / (predCov2 + KalmanNoise);
   kf2State = predState2 + gain2 * (close - predState2);
   kf2Cov = (1 - gain2) * predCov2;

   // Hull combination
   double hullInput = 2 * kf1State - kf2State;

   double predStateH = kfHullState;
   double predCovH = kfHullCov + KalmanProcess;
   double gainH = predCovH / (predCovH + sqrtNoise);
   kfHullState = predStateH + gainH * (hullInput - predStateH);
   kfHullCov = (1 - gainH) * predCovH;

   return kfHullState;
}

//+------------------------------------------------------------------+
//| CALCULATE KALMAN HULL RSI                                          |
//+------------------------------------------------------------------+
double CalculateKalmanHullRSI()
{
   // Calculate Kalman Hull values for RSI
   double khValues[];
   ArrayResize(khValues, RSI_Period + 2);

   // Get recent Kalman Hull values
   static double khHistory[];
   static int historySize = 0;

   double currentKH = CalculateKalmanHull(1);

   // Shift history
   if(historySize < RSI_Period + 2)
   {
      ArrayResize(khHistory, historySize + 1);
      khHistory[historySize] = currentKH;
      historySize++;
      if(historySize < RSI_Period + 1) return 50;  // Not enough data
   }
   else
   {
      for(int i = 0; i < historySize - 1; i++)
         khHistory[i] = khHistory[i + 1];
      khHistory[historySize - 1] = currentKH;
   }

   // Calculate RSI on Kalman Hull
   double avgGain = 0;
   double avgLoss = 0;

   for(int i = 1; i < historySize; i++)
   {
      double change = khHistory[i] - khHistory[i - 1];
      if(change > 0)
         avgGain += change;
      else
         avgLoss += MathAbs(change);
   }

   if(historySize > 1)
   {
      avgGain /= (historySize - 1);
      avgLoss /= (historySize - 1);
   }

   if(avgLoss == 0) return 100;

   double rs = avgGain / avgLoss;
   double rsi = 100 - (100 / (1 + rs));

   return rsi;
}

//+------------------------------------------------------------------+
//| CALCULATE VWAP                                                     |
//+------------------------------------------------------------------+
double CalculateVWAP()
{
   // Simple session VWAP approximation
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   double sumPV = 0;
   double sumV = 0;

   int barsToday = 0;
   for(int i = 1; i < 500; i++)
   {
      MqlDateTime barDt;
      TimeToStruct(iTime(_Symbol, PERIOD_CURRENT, i), barDt);

      if(barDt.day != dt.day)
         break;

      double typicalPrice = (iHigh(_Symbol, PERIOD_CURRENT, i) +
                            iLow(_Symbol, PERIOD_CURRENT, i) +
                            iClose(_Symbol, PERIOD_CURRENT, i)) / 3;
      long volume = (long)iVolume(_Symbol, PERIOD_CURRENT, i);
      if(volume == 0) volume = 1;

      sumPV += typicalPrice * volume;
      sumV += (double)volume;
      barsToday++;
   }

   if(sumV == 0) return iClose(_Symbol, PERIOD_CURRENT, 1);
   return sumPV / sumV;
}

//+------------------------------------------------------------------+
//| CHECK PULLBACK                                                     |
//+------------------------------------------------------------------+
bool IsBullishPullback(double ema20)
{
   // Check for 1-3 red candles near EMA20
   int redCandles = 0;
   bool nearEMA = false;

   for(int i = 1; i <= PullbackCandles; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      double low = iLow(_Symbol, PERIOD_CURRENT, i);

      if(close < open)  // Red candle
         redCandles++;

      // Check if low touched or came near EMA20
      if(low <= ema20 * 1.001 && close >= ema20 * 0.999)
         nearEMA = true;
   }

   return (redCandles >= 1 && nearEMA);
}

bool IsBearishPullback(double ema20)
{
   // Check for 1-3 green candles near EMA20
   int greenCandles = 0;
   bool nearEMA = false;

   for(int i = 1; i <= PullbackCandles; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);

      if(close > open)  // Green candle
         greenCandles++;

      // Check if high touched or came near EMA20
      if(high >= ema20 * 0.999 && close <= ema20 * 1.001)
         nearEMA = true;
   }

   return (greenCandles >= 1 && nearEMA);
}

//+------------------------------------------------------------------+
//| CHECK ENGULFING PATTERN                                            |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(double ema20)
{
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   // Current candle bullish, engulfs previous
   bool engulfing = (close1 > open1) &&           // Current is bullish
                    (close1 > close2) &&          // Closes above previous close
                    (open1 < open2) &&            // Opens below previous open
                    (close1 > ema20);             // Closes above EMA20

   return engulfing;
}

bool IsBearishEngulfing(double ema20)
{
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   // Current candle bearish, engulfs previous
   bool engulfing = (close1 < open1) &&           // Current is bearish
                    (close1 < close2) &&          // Closes below previous close
                    (open1 > open2) &&            // Opens above previous open
                    (close1 < ema20);             // Closes below EMA20

   return engulfing;
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIKA                                                      |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. Get EMA values
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   CopyBuffer(emaFastHandle, 0, 0, 5, emaFast);
   CopyBuffer(emaSlowHandle, 0, 0, 5, emaSlow);

   double ema10 = emaFast[1];
   double ema20 = emaSlow[1];
   double ema20Prev = emaSlow[2];

   // 2. Get VWAP
   double vwap = CalculateVWAP();
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);

   // 3. Calculate Kalman Hull RSI
   double khrsi = CalculateKalmanHullRSI();

   // 4. Trend filters
   bool bullTrend = (close > vwap || !UseVWAPFilter) &&
                    (ema10 > ema20) &&
                    (ema20 > ema20Prev);

   bool bearTrend = (close < vwap || !UseVWAPFilter) &&
                    (ema10 < ema20) &&
                    (ema20 < ema20Prev);

   // 5. Pullback detection
   bool bullPullback = IsBullishPullback(ema20);
   bool bearPullback = IsBearishPullback(ema20);

   // 6. Engulfing patterns
   bool bullEngulf = IsBullishEngulfing(ema20);
   bool bearEngulf = IsBearishEngulfing(ema20);

   // 7. Kalman Hull RSI confirmation
   bool khrsiUp = khrsi > 50;     // Green/uptrend
   bool khrsiDown = khrsi < 50;   // Red/downtrend

   // 8. Final signals
   // BUY: Bull trend + pullback + engulf + KHRSI > 50
   if(bullTrend && bullPullback && bullEngulf && khrsiUp)
   {
      Print("BUY Signal! EMA10: ", ema10, " EMA20: ", ema20, " KHRSI: ", khrsi);
      return 1;
   }

   // SELL: Bear trend + pullback + engulf + KHRSI < 50
   if(bearTrend && bearPullback && bearEngulf && khrsiDown)
   {
      Print("SELL Signal! EMA10: ", ema10, " EMA20: ", ema20, " KHRSI: ", khrsi);
      return -1;
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

   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "TopBottom BUY"))
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

      Print("BUY opened at ", ask);
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                          |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "TopBottom SELL"))
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

      Print("SELL opened at ", bid);
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

   if(!slSentToBroker && TimeCurrent() >= slSendTime)
      SendStealthSL();

   CheckTargets(profitPips, currentPrice);
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
//| SEND STEALTH SL                                                    |
//+------------------------------------------------------------------+
void SendStealthSL()
{
   double slPrice = 0;

   if(positionType == 0)
      slPrice = entryPrice - SL_Pips * pipValue;
   else
      slPrice = entryPrice + SL_Pips * pipValue;

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
