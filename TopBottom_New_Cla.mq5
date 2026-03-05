//+------------------------------------------------------------------+
//|                                            TopBottom_New_Cla.mq5 |
//|                   EMA Pullback + Kalman Hull RSI v3.0            |
//|                   XAUUSD M5 - IMPROVED VERSION                   |
//|                                                                  |
//|   IMPROVEMENTS:                                                  |
//|   - Fixed Kalman filter for multi-symbol                         |
//|   - Fixed VWAP calculation (session-based)                       |
//|   - Increased Time Failure tolerance                             |
//|   - Added Aggressive Mode option                                 |
//|   - Dynamic SL based on swing                                    |
//|   - SL ODMAH (immediate SL placement)                            |
//|                                                                  |
//|   Created: 05.03.2026 (Zagreb)                                   |
//+------------------------------------------------------------------+
#property copyright "TopBottom_New_Cla v3.0 (2026-03-05)"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETRI                                                    |
//+------------------------------------------------------------------+
input group "=== OSNOVNI PARAMETRI ==="
input double   LotSize = 0.01;
input int      MagicNumber = 778801;
input double   MaxSpread = 50;

input group "=== SIGNAL MODE ==="
input bool     AggressiveMode = false;     // TRUE = vise trejdova
input bool     RequireEngulfing = true;    // Require engulfing pattern
input bool     RequireKHRSI = true;        // Require KHRSI confirmation

input group "=== EMA POSTAVKE ==="
input int      EMA_Fast = 10;
input int      EMA_Slow = 20;
input int      PullbackCandles = 5;        // Max pullback candles

input group "=== KALMAN HULL RSI ==="
input double   KalmanNoise = 3.0;
input double   KalmanProcess = 0.01;
input int      RSI_Period = 12;
input double   KHRSI_BuyLevel = 45;        // KHRSI > ovo za BUY
input double   KHRSI_SellLevel = 55;       // KHRSI < ovo za SELL

input group "=== TARGETS (PIPS) ==="
input int      Target1_Pips = 300;
input int      Target2_Pips = 500;
input int      Target3_Pips = 800;

input group "=== SL POSTAVKE ==="
input int      SL_Pips = 300;
input bool     UseDynamicSL = true;        // SL based on swing
input int      SwingLookback = 10;
input int      SL_Buffer_Pips = 30;

input group "=== TRAILING (3 LEVEL + MFE) ==="
input int      TrailLevel1_Pips = 500;
input int      TrailLevel1_BE = 40;
input int      TrailLevel2_Pips = 800;
input int      TrailLevel2_Lock = 150;
input int      TrailLevel3_Pips = 1200;
input int      TrailLevel3_Lock = 200;
input int      MFE_ActivatePips = 1500;
input int      MFE_TrailDistance = 500;

input group "=== FAILURE EXIT ==="
input int      EarlyFailurePips = 800;
input int      TimeFailureBars = 6;        // 30 min na M5
input int      TimeFailureMinPips = 50;

input group "=== FILTERI ==="
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 3.0;
input bool     UseVWAPFilter = true;

input group "=== TRADING WINDOW ==="
input bool     UseTradingWindow = true;
input int      FridayCloseHour = 11;
input int      FridayCloseMinute = 30;

//+------------------------------------------------------------------+
//| GLOBALNE VARIJABLE                                                |
//+------------------------------------------------------------------+
CTrade trade;

bool     hasOpenPosition = false;
ulong    currentTicket = 0;
double   entryPrice = 0;
int      positionType = -1;
datetime entryTime = 0;

bool     target1Hit = false;
bool     target2Hit = false;
double   originalLots = 0;

int      trailLevel = 0;
double   maxProfitPips = 0;
int      barsInTrade = 0;
datetime lastBarTime = 0;
datetime lastSignalBar = 0;

// XAUUSD: 1 pip = 0.01
double   pipValue = 0.01;

// Kalman state
string   kalmanSymbol = "";
double   kf1State, kf1Cov;
double   kf2State, kf2Cov;
double   kfHullState, kfHullCov;
double   khHistory[];
int      khHistorySize = 0;

int      emaFastHandle, emaSlowHandle, atrHandle;
int      statBuys = 0, statSells = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
   {
      Print("Error creating handles");
      return(INIT_FAILED);
   }

   InitializeKalman();
   CheckExistingPosition();

   Print("===========================================");
   Print("  TOPBOTTOM NEW v3.0 - XAUUSD M5");
   Print("===========================================");
   Print("Mode: ", AggressiveMode ? "AGGRESSIVE" : "NORMAL");
   Print("Engulf: ", RequireEngulfing ? "ON" : "OFF");
   Print("KHRSI: ", RequireKHRSI ? "ON" : "OFF");
   Print("SL: ", SL_Pips, " pips (ODMAH)");
   Print("Trail: L1=", TrailLevel1_Pips, " L2=", TrailLevel2_Pips, " L3=", TrailLevel3_Pips);
   Print("===========================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void InitializeKalman()
{
   kalmanSymbol = _Symbol;
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   kf1State = close; kf1Cov = 1.0;
   kf2State = close; kf2Cov = 1.0;
   kfHullState = close; kfHullCov = 1.0;
   ArrayResize(khHistory, 0);
   khHistorySize = 0;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

   Print("=== STATISTICS ===");
   Print("BUY: ", statBuys, " | SELL: ", statSells);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(kalmanSymbol != _Symbol) InitializeKalman();

   if(hasOpenPosition)
   {
      ManagePosition();
      return;
   }

   if(!CanTrade()) return;

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == lastSignalBar) return;

   int signal = GetSignal();

   if(signal == 1)
   {
      OpenBuy();
      lastSignalBar = currentBar;
   }
   else if(signal == -1)
   {
      OpenSell();
      lastSignalBar = currentBar;
   }
}

//+------------------------------------------------------------------+
double CalculateKalmanHull()
{
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double halfNoise = KalmanNoise / 2;
   double sqrtNoise = MathSqrt(KalmanNoise);

   // KF1 fast
   double pred1 = kf1State;
   double predCov1 = kf1Cov + KalmanProcess;
   double gain1 = predCov1 / (predCov1 + halfNoise);
   kf1State = pred1 + gain1 * (close - pred1);
   kf1Cov = (1 - gain1) * predCov1;

   // KF2 slow
   double pred2 = kf2State;
   double predCov2 = kf2Cov + KalmanProcess;
   double gain2 = predCov2 / (predCov2 + KalmanNoise);
   kf2State = pred2 + gain2 * (close - pred2);
   kf2Cov = (1 - gain2) * predCov2;

   // Hull
   double hullInput = 2 * kf1State - kf2State;
   double predH = kfHullState;
   double predCovH = kfHullCov + KalmanProcess;
   double gainH = predCovH / (predCovH + sqrtNoise);
   kfHullState = predH + gainH * (hullInput - predH);
   kfHullCov = (1 - gainH) * predCovH;

   return kfHullState;
}

//+------------------------------------------------------------------+
double CalculateKHRSI()
{
   double currentKH = CalculateKalmanHull();

   if(khHistorySize < RSI_Period + 2)
   {
      ArrayResize(khHistory, khHistorySize + 1);
      khHistory[khHistorySize] = currentKH;
      khHistorySize++;
      if(khHistorySize < RSI_Period + 1) return 50;
   }
   else
   {
      for(int i = 0; i < khHistorySize - 1; i++)
         khHistory[i] = khHistory[i + 1];
      khHistory[khHistorySize - 1] = currentKH;
   }

   double avgGain = 0, avgLoss = 0;
   for(int i = 1; i < khHistorySize; i++)
   {
      double change = khHistory[i] - khHistory[i - 1];
      if(change > 0) avgGain += change;
      else avgLoss += MathAbs(change);
   }

   avgGain /= (khHistorySize - 1);
   avgLoss /= (khHistorySize - 1);

   if(avgLoss == 0) return 100;
   double rs = avgGain / avgLoss;
   return 100 - (100 / (1 + rs));
}

//+------------------------------------------------------------------+
double CalculateVWAP()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   double sumPV = 0, sumV = 0;

   for(int i = 1; i < 300; i++)
   {
      MqlDateTime barDt;
      TimeToStruct(iTime(_Symbol, PERIOD_CURRENT, i), barDt);
      if(barDt.day != dt.day) break;

      double tp = (iHigh(_Symbol, PERIOD_CURRENT, i) +
                   iLow(_Symbol, PERIOD_CURRENT, i) +
                   iClose(_Symbol, PERIOD_CURRENT, i)) / 3;
      long vol = (long)iVolume(_Symbol, PERIOD_CURRENT, i);
      if(vol == 0) vol = 1;

      sumPV += tp * vol;
      sumV += (double)vol;
   }

   if(sumV == 0) return iClose(_Symbol, PERIOD_CURRENT, 1);
   return sumPV / sumV;
}

//+------------------------------------------------------------------+
bool IsBullishPullback(double ema20)
{
   int redCandles = 0;
   bool nearEMA = false;
   double tol = ema20 * 0.002;

   for(int i = 1; i <= PullbackCandles; i++)
   {
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);

      if(c < o) redCandles++;
      if(l <= ema20 + tol && l >= ema20 - tol) nearEMA = true;
      if(MathMin(o, c) <= ema20 && MathMax(o, c) >= ema20) nearEMA = true;
   }

   return (redCandles >= 1 && nearEMA);
}

//+------------------------------------------------------------------+
bool IsBearishPullback(double ema20)
{
   int greenCandles = 0;
   bool nearEMA = false;
   double tol = ema20 * 0.002;

   for(int i = 1; i <= PullbackCandles; i++)
   {
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);

      if(c > o) greenCandles++;
      if(h >= ema20 - tol && h <= ema20 + tol) nearEMA = true;
      if(MathMin(o, c) <= ema20 && MathMax(o, c) >= ema20) nearEMA = true;
   }

   return (greenCandles >= 1 && nearEMA);
}

//+------------------------------------------------------------------+
bool IsBullishEngulfing(double ema20)
{
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double c2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   if(c1 <= o1) return false;

   bool engulf = (c1 > MathMax(o2, c2)) && (o1 < MathMin(o2, c2));
   bool strong = (c1 > ema20) && ((c1 - o1) > (iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) * 0.6);

   return engulf || strong;
}

//+------------------------------------------------------------------+
bool IsBearishEngulfing(double ema20)
{
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, 2);
   double c2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   if(c1 >= o1) return false;

   bool engulf = (c1 < MathMin(o2, c2)) && (o1 > MathMax(o2, c2));
   bool strong = (c1 < ema20) && ((o1 - c1) > (iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) * 0.6);

   return engulf || strong;
}

//+------------------------------------------------------------------+
int GetSignal()
{
   double emaF[], emaS[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   CopyBuffer(emaFastHandle, 0, 0, 5, emaF);
   CopyBuffer(emaSlowHandle, 0, 0, 5, emaS);

   double ema10 = emaF[1];
   double ema20 = emaS[1];
   double ema20Prev = emaS[2];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double vwap = CalculateVWAP();
   double khrsi = CalculateKHRSI();

   // Trend
   bool bullTrend = (close > vwap || !UseVWAPFilter) && (ema10 > ema20) && (ema20 >= ema20Prev);
   bool bearTrend = (close < vwap || !UseVWAPFilter) && (ema10 < ema20) && (ema20 <= ema20Prev);

   if(!bullTrend && !bearTrend) return 0;

   // Pullback
   bool bullPB = IsBullishPullback(ema20);
   bool bearPB = IsBearishPullback(ema20);

   // Engulfing (optional)
   bool bullEng = !RequireEngulfing || IsBullishEngulfing(ema20);
   bool bearEng = !RequireEngulfing || IsBearishEngulfing(ema20);

   // KHRSI (optional)
   bool khrsiUp = !RequireKHRSI || (khrsi > KHRSI_BuyLevel);
   bool khrsiDn = !RequireKHRSI || (khrsi < KHRSI_SellLevel);

   // Aggressive mode relaxes conditions
   if(AggressiveMode)
   {
      bullEng = true;
      bearEng = true;
      khrsiUp = (khrsi > 40);
      khrsiDn = (khrsi < 60);
   }

   if(bullTrend && bullPB && bullEng && khrsiUp)
   {
      Print("BUY Signal | EMA10:", DoubleToString(ema10, 2), " KHRSI:", DoubleToString(khrsi, 1));
      return 1;
   }

   if(bearTrend && bearPB && bearEng && khrsiDn)
   {
      Print("SELL Signal | EMA10:", DoubleToString(ema10, 2), " KHRSI:", DoubleToString(khrsi, 1));
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
double GetDynamicSL(int dir)
{
   if(!UseDynamicSL) return SL_Pips * pipValue;

   double swing = 0;

   if(dir == 1)
   {
      swing = iLow(_Symbol, PERIOD_CURRENT, 1);
      for(int i = 2; i <= SwingLookback; i++)
      {
         double l = iLow(_Symbol, PERIOD_CURRENT, i);
         if(l < swing) swing = l;
      }
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double slDist = ask - swing + SL_Buffer_Pips * pipValue;
      return MathMax(SL_Pips * 0.5 * pipValue, MathMin(SL_Pips * 2.0 * pipValue, slDist));
   }
   else
   {
      swing = iHigh(_Symbol, PERIOD_CURRENT, 1);
      for(int i = 2; i <= SwingLookback; i++)
      {
         double h = iHigh(_Symbol, PERIOD_CURRENT, i);
         if(h > swing) swing = h;
      }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double slDist = swing - bid + SL_Buffer_Pips * pipValue;
      return MathMax(SL_Pips * 0.5 * pipValue, MathMin(SL_Pips * 2.0 * pipValue, slDist));
   }
}

//+------------------------------------------------------------------+
bool CanTrade()
{
   if(UseTradingWindow && !IsTradingTime()) return false;

   if(UseSpreadFilter)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / pipValue > MaxSpread)
         return false;
   }

   if(UseLargeCandleFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(atrHandle, 0, 0, 2, atr) > 0)
      {
         double candle = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
         if(candle > atr[1] * LargeCandleATR) return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 && dt.hour == 0 && dt.min < 1) return false;
   if(dt.day_of_week == 5 && (dt.hour > FridayCloseHour || (dt.hour == FridayCloseHour && dt.min >= FridayCloseMinute))) return false;
   if(dt.day_of_week == 6) return false;

   return true;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slDist = GetDynamicSL(1);
   double sl = NormalizeDouble(ask - slDist, _Digits);

   // SL ODMAH!
   if(trade.Buy(LotSize, _Symbol, ask, sl, 0, "TopBottom NEW"))
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
      lastBarTime = 0;
      statBuys++;

      Print("=== BUY #", currentTicket, " @ ", ask, " SL: ", sl, " ===");
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = GetDynamicSL(-1);
   double sl = NormalizeDouble(bid + slDist, _Digits);

   // SL ODMAH!
   if(trade.Sell(LotSize, _Symbol, bid, sl, 0, "TopBottom NEW"))
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
      lastBarTime = 0;
      statSells++;

      Print("=== SELL #", currentTicket, " @ ", bid, " SL: ", sl, " ===");
   }
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!PositionSelectByTicket(currentTicket))
   {
      hasOpenPosition = false;
      return;
   }

   double price = (positionType == 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPips = (positionType == 0) ? (price - entryPrice) / pipValue : (entryPrice - price) / pipValue;

   if(profitPips > maxProfitPips) maxProfitPips = profitPips;

   // Bar tracking
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar != lastBarTime)
   {
      lastBarTime = curBar;
      barsInTrade++;

      // Time failure
      if(barsInTrade >= TimeFailureBars && profitPips < TimeFailureMinPips && profitPips > -EarlyFailurePips * 0.3)
      {
         if(trade.PositionClose(currentTicket))
         {
            hasOpenPosition = false;
            Print("TIME EXIT: ", barsInTrade, " bars, ", DoubleToString(profitPips, 0), " pips");
            return;
         }
      }
   }

   // Early failure
   if(profitPips <= -EarlyFailurePips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("EARLY FAIL: ", DoubleToString(profitPips, 0), " pips");
         return;
      }
   }

   CheckTargets(profitPips);
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
void CheckTargets(double profitPips)
{
   double lots = PositionGetDouble(POSITION_VOLUME);

   if(!target1Hit && profitPips >= Target1_Pips)
   {
      double close = NormalizeDouble(originalLots * 0.33, 2);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(close < minLot) close = minLot;
      if(close < lots && trade.PositionClosePartial(currentTicket, close))
      {
         target1Hit = true;
         Print("T1 HIT! +", DoubleToString(profitPips, 0));
      }
   }

   if(!target2Hit && target1Hit && profitPips >= Target2_Pips)
   {
      lots = PositionGetDouble(POSITION_VOLUME);
      double close = NormalizeDouble(lots * 0.5, 2);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(close < minLot) close = minLot;
      if(close < lots && trade.PositionClosePartial(currentTicket, close))
      {
         target2Hit = true;
         Print("T2 HIT! +", DoubleToString(profitPips, 0));
      }
   }

   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("T3 HIT! +", DoubleToString(profitPips, 0));
      }
   }
}

//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   double sl = PositionGetDouble(POSITION_SL);
   if(sl == 0) return;

   double newSL = sl;
   bool mod = false;

   // L1
   if(trailLevel < 1 && profitPips >= TrailLevel1_Pips)
   {
      newSL = (positionType == 0) ? entryPrice + TrailLevel1_BE * pipValue : entryPrice - TrailLevel1_BE * pipValue;
      newSL = NormalizeDouble(newSL, _Digits);
      mod = (positionType == 0 && newSL > sl) || (positionType == 1 && newSL < sl);
      if(mod && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 1;
         Print("TRAIL L1: BE+", TrailLevel1_BE);
      }
   }

   // L2
   if(trailLevel < 2 && profitPips >= TrailLevel2_Pips)
   {
      newSL = (positionType == 0) ? entryPrice + TrailLevel2_Lock * pipValue : entryPrice - TrailLevel2_Lock * pipValue;
      newSL = NormalizeDouble(newSL, _Digits);
      mod = (positionType == 0 && newSL > sl) || (positionType == 1 && newSL < sl);
      if(mod && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 2;
         Print("TRAIL L2: Lock+", TrailLevel2_Lock);
      }
   }

   // L3
   if(trailLevel < 3 && profitPips >= TrailLevel3_Pips)
   {
      newSL = (positionType == 0) ? entryPrice + TrailLevel3_Lock * pipValue : entryPrice - TrailLevel3_Lock * pipValue;
      newSL = NormalizeDouble(newSL, _Digits);
      mod = (positionType == 0 && newSL > sl) || (positionType == 1 && newSL < sl);
      if(mod && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailLevel = 3;
         Print("TRAIL L3: Lock+", TrailLevel3_Lock);
      }
   }

   // MFE
   if(maxProfitPips >= MFE_ActivatePips)
   {
      double mfeLock = maxProfitPips - MFE_TrailDistance;
      double mfeSL = (positionType == 0) ? entryPrice + mfeLock * pipValue : entryPrice - mfeLock * pipValue;
      mfeSL = NormalizeDouble(mfeSL, _Digits);
      mod = (positionType == 0 && mfeSL > sl) || (positionType == 1 && mfeSL < sl);
      if(mod && trade.PositionModify(currentTicket, mfeSL, 0))
      {
         Print("MFE TRAIL: Lock ", DoubleToString(mfeLock, 0));
      }
   }
}

//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            currentTicket = ticket;
            entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positionType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 0 : 1;
            entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            hasOpenPosition = true;
            originalLots = PositionGetDouble(POSITION_VOLUME);
            Print("Found position: ", ticket);
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades = TesterStatistics(STAT_TRADES);
   double wr = trades > 0 ? TesterStatistics(STAT_PROFIT_TRADES) / trades * 100 : 0;
   if(trades < 30) return 0;
   return pf * MathSqrt(trades) * (wr / 50);
}
//+------------------------------------------------------------------+
