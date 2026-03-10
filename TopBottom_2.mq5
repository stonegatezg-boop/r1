//+------------------------------------------------------------------+
//|                                                   TopBottom_2.mq5 |
//|                   EMA Pullback + Kalman Hull RSI v2.0             |
//|                   XAUUSD M5 - STANDARD CLAUDE.md SETTINGS         |
//|                                                                   |
//|   FEATURES:                                                       |
//|   - Stealth TP (TP=0, close manually)                             |
//|   - REAL SL ODMAH (988-1054 pips random)                          |
//|   - BE+ at 1000 pips (offset 41-46 random)                        |
//|   - Trailing 1000 pips after BE+                                  |
//|   - Trading window 0-24h, Friday 11h                              |
//|                                                                   |
//|   Created: 10.03.2026 (Zagreb)                                    |
//+------------------------------------------------------------------+
#property copyright "TopBottom_2 v2.0 (2026-03-10)"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETRI                                                    |
//+------------------------------------------------------------------+
input group "=== OSNOVNI PARAMETRI ==="
input double   LotSize = 0.01;
input int      MagicNumber = 778802;          // TopBottom 2 magic
input double   MaxSpread = 50;

input group "=== SIGNAL MODE ==="
input bool     AggressiveMode = false;
input bool     RequireEngulfing = true;
input bool     RequireKHRSI = true;

input group "=== EMA POSTAVKE ==="
input int      EMA_Fast = 10;
input int      EMA_Slow = 20;
input int      PullbackCandles = 5;

input group "=== KALMAN HULL RSI ==="
input double   KalmanNoise = 3.0;
input double   KalmanProcess = 0.01;
input int      RSI_Period = 12;
input double   KHRSI_BuyLevel = 45;
input double   KHRSI_SellLevel = 55;

input group "=== TARGETS (PIPS) - STEALTH ==="
input int      Target1_Pips = 300;
input int      Target2_Pips = 500;
input int      Target3_Pips = 800;

input group "=== SL POSTAVKE (CLAUDE.md STANDARD) ==="
input int      InitialSL_Min = 988;           // SL min pips
input int      InitialSL_Max = 1054;          // SL max pips

input group "=== TRAILING (CLAUDE.md STANDARD) ==="
input int      TrailingStartBE = 1000;        // Pips za BE+
input int      BEOffset_Min = 41;             // BE+ offset min
input int      BEOffset_Max = 46;             // BE+ offset max
input int      TrailingDistance = 1000;       // Trailing udaljenost

input group "=== FILTERI ==="
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 3.0;
input bool     UseVWAPFilter = true;

input group "=== RADNO VRIJEME (ZAGREB) ==="
input int      ZagrebStartHour = 0;
input int      ZagrebEndHour = 24;
input int      FridayCloseHour = 11;

//+------------------------------------------------------------------+
//| GLOBALNE VARIJABLE                                                |
//+------------------------------------------------------------------+
CTrade trade;

bool     hasOpenPosition = false;
ulong    currentTicket = 0;
double   entryPrice = 0;
int      positionType = -1;    // 0=BUY, 1=SELL
datetime entryTime = 0;

bool     target1Hit = false;
bool     target2Hit = false;
double   originalLots = 0;

bool     beActivated = false;
int      beOffset = 0;         // Random BE offset za ovaj trejd
int      slPips = 0;           // Random SL za ovaj trejd
double   highestProfit = 0;
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
   Print("  TOPBOTTOM 2 v2.0 - XAUUSD M5");
   Print("  CLAUDE.md Standard Settings");
   Print("===========================================");
   Print("SL: ", InitialSL_Min, "-", InitialSL_Max, " pips (random, ODMAH)");
   Print("BE+: ", TrailingStartBE, " pips (offset ", BEOffset_Min, "-", BEOffset_Max, ")");
   Print("Trail: ", TrailingDistance, " pips after BE+");
   Print("Hours: ", ZagrebStartHour, "-", ZagrebEndHour, "h (Fri: ", FridayCloseHour, "h)");
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

   double pred1 = kf1State;
   double predCov1 = kf1Cov + KalmanProcess;
   double gain1 = predCov1 / (predCov1 + halfNoise);
   kf1State = pred1 + gain1 * (close - pred1);
   kf1Cov = (1 - gain1) * predCov1;

   double pred2 = kf2State;
   double predCov2 = kf2Cov + KalmanProcess;
   double gain2 = predCov2 / (predCov2 + KalmanNoise);
   kf2State = pred2 + gain2 * (close - pred2);
   kf2Cov = (1 - gain2) * predCov2;

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

   bool bullTrend = (close > vwap || !UseVWAPFilter) && (ema10 > ema20) && (ema20 >= ema20Prev);
   bool bearTrend = (close < vwap || !UseVWAPFilter) && (ema10 < ema20) && (ema20 <= ema20Prev);

   if(!bullTrend && !bearTrend) return 0;

   bool bullPB = IsBullishPullback(ema20);
   bool bearPB = IsBearishPullback(ema20);

   bool bullEng = !RequireEngulfing || IsBullishEngulfing(ema20);
   bool bearEng = !RequireEngulfing || IsBearishEngulfing(ema20);

   bool khrsiUp = !RequireKHRSI || (khrsi > KHRSI_BuyLevel);
   bool khrsiDn = !RequireKHRSI || (khrsi < KHRSI_SellLevel);

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
bool CanTrade()
{
   if(!IsTradingTime()) return false;

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
   // Get broker time and convert to Zagreb (UTC+1, or UTC+2 in summer)
   datetime brokerTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(brokerTime, dt);

   // Assume broker is UTC+2 (common for forex), Zagreb is UTC+1 (winter) or UTC+2 (summer)
   // For simplicity, assume same timezone
   int hour = dt.hour;

   // Weekend check
   if(dt.day_of_week == 0) return false;  // Sunday
   if(dt.day_of_week == 6) return false;  // Saturday

   // Friday early close
   if(dt.day_of_week == 5 && hour >= FridayCloseHour) return false;

   // Normal hours
   if(hour < ZagrebStartHour || hour >= ZagrebEndHour) return false;

   return true;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Random SL (988-1054 pips)
   slPips = InitialSL_Min + MathRand() % (InitialSL_Max - InitialSL_Min + 1);
   double sl = NormalizeDouble(ask - slPips * pipValue, _Digits);

   // Random BE offset za kasnije
   beOffset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

   // STEALTH: SL ODMAH, TP=0
   if(trade.Buy(LotSize, _Symbol, ask, sl, 0, "TopBottom2"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = ask;
      positionType = 0;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;
      target1Hit = false;
      target2Hit = false;
      beActivated = false;
      highestProfit = 0;
      lastBarTime = 0;
      statBuys++;

      Print("=== BUY #", currentTicket, " @ ", ask, " SL: ", sl, " (", slPips, " pips) BE+", beOffset, " ===");
   }
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Random SL (988-1054 pips)
   slPips = InitialSL_Min + MathRand() % (InitialSL_Max - InitialSL_Min + 1);
   double sl = NormalizeDouble(bid + slPips * pipValue, _Digits);

   // Random BE offset za kasnije
   beOffset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

   // STEALTH: SL ODMAH, TP=0
   if(trade.Sell(LotSize, _Symbol, bid, sl, 0, "TopBottom2"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = bid;
      positionType = 1;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;
      target1Hit = false;
      target2Hit = false;
      beActivated = false;
      highestProfit = 0;
      lastBarTime = 0;
      statSells++;

      Print("=== SELL #", currentTicket, " @ ", bid, " SL: ", sl, " (", slPips, " pips) BE+", beOffset, " ===");
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

   if(profitPips > highestProfit) highestProfit = profitPips;

   // STEALTH TARGETS
   CheckStealthTargets(profitPips);

   // BE+ and Trailing
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
void CheckStealthTargets(double profitPips)
{
   double lots = PositionGetDouble(POSITION_VOLUME);

   // Target 1: 33%
   if(!target1Hit && profitPips >= Target1_Pips)
   {
      double close = NormalizeDouble(originalLots * 0.33, 2);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(close < minLot) close = minLot;
      if(close < lots && trade.PositionClosePartial(currentTicket, close))
      {
         target1Hit = true;
         Print("STEALTH T1 HIT! +", DoubleToString(profitPips, 0), " pips");
      }
   }

   // Target 2: 50% remaining
   if(!target2Hit && target1Hit && profitPips >= Target2_Pips)
   {
      lots = PositionGetDouble(POSITION_VOLUME);
      double close = NormalizeDouble(lots * 0.5, 2);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(close < minLot) close = minLot;
      if(close < lots && trade.PositionClosePartial(currentTicket, close))
      {
         target2Hit = true;
         Print("STEALTH T2 HIT! +", DoubleToString(profitPips, 0), " pips");
      }
   }

   // Target 3: Close all
   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("STEALTH T3 HIT! +", DoubleToString(profitPips, 0), " pips (FULL CLOSE)");
      }
   }
}

//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   double sl = PositionGetDouble(POSITION_SL);
   if(sl == 0)
   {
      // Backup: SL mora biti postavljen!
      double newSL = (positionType == 0) ?
         entryPrice - slPips * pipValue :
         entryPrice + slPips * pipValue;
      trade.PositionModify(currentTicket, NormalizeDouble(newSL, _Digits), 0);
      Print("BACKUP SL SET: ", newSL);
      return;
   }

   // BE+ na 1000 pips profita
   if(!beActivated && profitPips >= TrailingStartBE)
   {
      double newSL = (positionType == 0) ?
         entryPrice + beOffset * pipValue :
         entryPrice - beOffset * pipValue;
      newSL = NormalizeDouble(newSL, _Digits);

      bool better = (positionType == 0 && newSL > sl) || (positionType == 1 && newSL < sl);
      if(better && trade.PositionModify(currentTicket, newSL, 0))
      {
         beActivated = true;
         Print("BE+ ACTIVATED: +", beOffset, " pips");
      }
   }

   // Trailing nakon BE+ - prati na 1000 pips udaljenosti
   if(beActivated && highestProfit > TrailingStartBE)
   {
      double trailPips = highestProfit - TrailingDistance;
      if(trailPips > beOffset)  // Samo ako je bolje od BE+
      {
         double newSL = (positionType == 0) ?
            entryPrice + trailPips * pipValue :
            entryPrice - trailPips * pipValue;
         newSL = NormalizeDouble(newSL, _Digits);

         bool better = (positionType == 0 && newSL > sl) || (positionType == 1 && newSL < sl);
         if(better && trade.PositionModify(currentTicket, newSL, 0))
         {
            Print("TRAIL: Lock +", DoubleToString(trailPips, 0), " pips (MFE: ", DoubleToString(highestProfit, 0), ")");
         }
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

            // Default values za recovery
            slPips = (InitialSL_Min + InitialSL_Max) / 2;
            beOffset = (BEOffset_Min + BEOffset_Max) / 2;

            Print("Found position: ", ticket, " | Using default SL/BE values");
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
