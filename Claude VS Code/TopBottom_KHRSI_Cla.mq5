//+------------------------------------------------------------------+
//|                                          TopBottom_KHRSI_Cla.mq5 |
//|                   EMA20 Pullback Engulf + Kalman Hull RSI        |
//|                                          Za XAUUSD M5            |
//|                   Version 2.2 - Fixed: 04.03.2026 (Zagreb)       |
//|                   SL ODMAH + 3-level trailing + MFE              |
//+------------------------------------------------------------------+
#property copyright "TopBottom_KHRSI_Cla v2.2 (2026-03-04)"
#property link      ""
#property version   "2.22"
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

// === SL POSTAVKE ===
input string   INFO5 = "=== SL POSTAVKE ===";
input int      SL_Pips = 300;

// === TRAILING POSTAVKE (3 LEVEL + MFE) ===
input string   INFO5b = "=== TRAILING (3 LEVEL + MFE) ===";
input int      TrailLevel1_Pips = 500;
input int      TrailLevel1_BE = 40;
input int      TrailLevel2_Pips = 800;
input int      TrailLevel2_Lock = 150;
input int      TrailLevel3_Pips = 1200;
input int      TrailLevel3_Lock = 200;
input int      MFE_ActivatePips = 1500;
input int      MFE_TrailDistance = 500;

// === FAILURE EXIT ===
input string   INFO5c = "=== FAILURE EXIT ===";
input int      EarlyFailurePips = 800;
input int      TimeFailureBars = 3;
input int      TimeFailureMinPips = 20;

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

// Trailing
int      trailLevel = 0;  // 0=none, 1=L1, 2=L2, 3=L3
double   maxProfitPips = 0;
int      barsInTrade = 0;
datetime lastBarTime = 0;

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

   // XAUUSD pip = 0.01 (ISPRAVNO!)
   // 1 pip XAUUSD = 0.01 (100 points = 1 pip, cijena format xxxx.xx)
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      pipValue = 0.01;  // FIXED: bilo 0.1, sada 0.01
      pipDigits = 2;
   }
   else
   {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      if(digits == 5 || digits == 3)
      {
         pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
         pipDigits = digits - 1;
      }
      else
      {
         pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         pipDigits = digits;
      }
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

   Print("╔═══════════════════════════════════════════════════════════════╗");
   Print("║     TOPBOTTOM_KHRSI_CLA v2.2 - SL ODMAH                      ║");
   Print("╠═══════════════════════════════════════════════════════════════╣");
   Print("║ pipValue: ", pipValue, " | SL: ", SL_Pips, " pips (PRAVI SL ODMAH)");
   Print("║ Trail L1: ", TrailLevel1_Pips, " pips -> BE+", TrailLevel1_BE);
   Print("║ Trail L2: ", TrailLevel2_Pips, " pips -> Lock+", TrailLevel2_Lock);
   Print("║ Trail L3: ", TrailLevel3_Pips, " pips -> Lock+", TrailLevel3_Lock);
   Print("║ MFE: ", MFE_ActivatePips, " pips -> Trail ", MFE_TrailDistance);
   Print("║ Failure: Early -", EarlyFailurePips, " | Time ", TimeFailureBars, " bars <", TimeFailureMinPips);
   Print("╚═══════════════════════════════════════════════════════════════╝");

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
//| OPEN BUY - SL ODMAH                                               |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - SL_Pips * pipValue, _Digits);

   // SL ODMAH - pravi SL se postavlja ODMAH, TP ostaje stealth (0)
   if(trade.Buy(LotSize, _Symbol, ask, sl, 0, "TopBottom BUY"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = ask;
      positionType = 0;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      target1Hit = false;
      target2Hit = false;
      trailLevel = 0;
      maxProfitPips = 0;
      barsInTrade = 0;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ TOPBOTTOM BUY #", currentTicket, " | SL ODMAH");
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", DoubleToString(ask, _Digits), " | SL: ", DoubleToString(sl, _Digits));
      Print("╚════════════════════════════════════════════════╝");
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL - SL ODMAH                                              |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + SL_Pips * pipValue, _Digits);

   // SL ODMAH - pravi SL se postavlja ODMAH, TP ostaje stealth (0)
   if(trade.Sell(LotSize, _Symbol, bid, sl, 0, "TopBottom SELL"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = bid;
      positionType = 1;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      target1Hit = false;
      target2Hit = false;
      trailLevel = 0;
      maxProfitPips = 0;
      barsInTrade = 0;

      Print("╔════════════════════════════════════════════════╗");
      Print("║ TOPBOTTOM SELL #", currentTicket, " | SL ODMAH");
      Print("╠════════════════════════════════════════════════╣");
      Print("║ Entry: ", DoubleToString(bid, _Digits), " | SL: ", DoubleToString(sl, _Digits));
      Print("╚════════════════════════════════════════════════╝");
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

   // Update MFE
   if(profitPips > maxProfitPips)
      maxProfitPips = profitPips;

   // Check new bar for time tracking
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      barsInTrade++;

      // Time failure check
      if(barsInTrade >= TimeFailureBars && profitPips < TimeFailureMinPips && profitPips > -EarlyFailurePips/2)
      {
         if(trade.PositionClose(currentTicket))
         {
            hasOpenPosition = false;
            Print("TIME EXIT after ", barsInTrade, " bars, profit: ", DoubleToString(profitPips, 1), " pips");
            return;
         }
      }
   }

   // Early failure exit
   if(profitPips <= -EarlyFailurePips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("EARLY FAILURE at ", DoubleToString(profitPips, 0), " pips");
         return;
      }
   }

   CheckTargets(profitPips, currentPrice);
   ManageTrailing(profitPips);
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
//| MANAGE TRAILING STOP - 3 LEVEL + MFE                              |
//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   double currentSL = PositionGetDouble(POSITION_SL);
   if(currentSL == 0) return;

   double newSL = currentSL;
   bool shouldModify = false;

   // Level 1: 500 pips -> BE + 40 pips
   if(trailLevel < 1 && profitPips >= TrailLevel1_Pips)
   {
      if(positionType == 0)
         newSL = entryPrice + TrailLevel1_BE * pipValue;
      else
         newSL = entryPrice - TrailLevel1_BE * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);
      shouldModify = (positionType == 0 && newSL > currentSL) ||
                     (positionType == 1 && newSL < currentSL);

      if(shouldModify && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 1;
         Print("Trail L1: BE+", TrailLevel1_BE, " pips");
      }
   }

   // Level 2: 800 pips -> Lock 150 pips
   if(trailLevel < 2 && profitPips >= TrailLevel2_Pips)
   {
      if(positionType == 0)
         newSL = entryPrice + TrailLevel2_Lock * pipValue;
      else
         newSL = entryPrice - TrailLevel2_Lock * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);
      shouldModify = (positionType == 0 && newSL > currentSL) ||
                     (positionType == 1 && newSL < currentSL);

      if(shouldModify && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 2;
         Print("Trail L2: Lock+", TrailLevel2_Lock, " pips");
      }
   }

   // Level 3: 1200 pips -> Lock 200 pips
   if(trailLevel < 3 && profitPips >= TrailLevel3_Pips)
   {
      if(positionType == 0)
         newSL = entryPrice + TrailLevel3_Lock * pipValue;
      else
         newSL = entryPrice - TrailLevel3_Lock * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);
      shouldModify = (positionType == 0 && newSL > currentSL) ||
                     (positionType == 1 && newSL < currentSL);

      if(shouldModify && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 3;
         Print("Trail L3: Lock+", TrailLevel3_Lock, " pips");
      }
   }

   // MFE Trailing: aktivacija 1500 pips, trail 500 pips od vrha
   if(maxProfitPips >= MFE_ActivatePips)
   {
      double mfeSL;
      if(positionType == 0)
         mfeSL = entryPrice + (maxProfitPips - MFE_TrailDistance) * pipValue;
      else
         mfeSL = entryPrice - (maxProfitPips - MFE_TrailDistance) * pipValue;

      mfeSL = NormalizeDouble(mfeSL, _Digits);
      shouldModify = (positionType == 0 && mfeSL > currentSL) ||
                     (positionType == 1 && mfeSL < currentSL);

      if(shouldModify && trade.PositionModify(currentTicket, mfeSL, 0))
      {
         Print("MFE Trail: Lock MFE-", MFE_TrailDistance, " (MFE: ", DoubleToString(maxProfitPips, 0), " pips)");
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
            trailLevel = 0;
            maxProfitPips = 0;
            barsInTrade = 0;

            Print("Existing position found. Ticket: ", ticket);
            break;
         }
      }
   }
}
//+------------------------------------------------------------------+
