//+------------------------------------------------------------------+
//|                                                KymcoDe_V4_Cla.mq5|
//|   Donchian Breakout + Trend Filter                               |
//|   + Stealth Mode v2.0                                            |
//|   + V4.0: Fixed ATR filter, improved trend logic                 |
//|                                                                  |
//|   Version 4.0 - 2026-02-24                                       |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property copyright "KymcoDe v4.0 Cla"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| STEALTH KONFIGURACIJA                                            |
//| Radno vrijeme: Ned 00:01 - Pet 11:30 (user time)                 |
//| Server = User + 1h                                               |
//+------------------------------------------------------------------+

//--- inputs
input group "=== TRADE POSTAVKE ==="
input double RiskPercent        = 0.5;
input double SLMultiplier       = 2.0;      // SL = ATR * multiplier
input double TPMultiplier       = 4.0;      // TP = ATR * multiplier (2:1 ratio)
input int    ATRperiod          = 20;
input int    DonchianPeriod     = 20;
input int    CooldownBars       = 3;        // Smanjeno s 5
input int    MaxSpread          = 40;
input int    MagicNumber        = 9024026;
input double MaxDailyDD         = 3.0;

input group "=== TREND FILTER ==="
input bool   UseTrendFilter     = false;    // OFF - Donchian radi bolje bez
input int    H1_EMA_Period      = 50;       // H1 EMA za glavni trend
input int    HullPeriod         = 20;       // Hull MA za M5 trend
input bool   StrictTrendFilter  = false;    // FALSE = lakši uvjeti
input double TrendThreshold     = 0.2;      // Smanjen s 0.5 na 0.2 ATR

input group "=== VOLATILITY FILTER (u POINTS) ==="
input double MinATRPoints       = 50;       // Min ATR u points (5 pips EURUSD, 50 cents Gold)
input double MaxATRPoints       = 2000;     // Max ATR u points
input int    ATRmaPeriod        = 100;

input group "=== PARTIAL PROFIT ==="
input bool   UsePartialTP       = true;
input double PartialTPRatio     = 0.5;      // Zatvori 50% na prvom TP
input double PartialTPMultiplier = 2.0;     // Prvi TP = ATR * 2 (1:1)

input group "=== STEALTH POSTAVKE ==="
input bool   UseStealthMode     = true;
input int    OpenDelayMin       = 0;
input int    OpenDelayMax       = 4;
input int    SLDelayMin         = 7;
input int    SLDelayMax         = 13;
input double LargeCandleATR     = 3.0;

input group "=== TRAILING POSTAVKE ==="
input int    TrailActivatePips  = 500;      // Level 1: BE + pips
input int    TrailBEPipsMin     = 33;
input int    TrailBEPipsMax     = 38;
input int    TrailLevel2Pips    = 800;      // Level 2: Lock more profit
input int    TrailLevel2LockMin = 150;      // Lock min pips at L2
input int    TrailLevel2LockMax = 200;      // Lock max pips at L2

//--- Struktura za pending trade
struct PendingTradeInfo
{
   bool              active;
   ENUM_ORDER_TYPE   type;
   double            lot;
   double            intendedSL;
   double            intendedTP;
   double            partialTP;
   datetime          signalTime;
   int               delaySeconds;
};

//--- Struktura za poziciju
struct PositionInfo
{
   bool     active;
   ulong    ticket;
   double   intendedSL;
   double   stealthTP;
   double   partialTP;
   double   entryPrice;
   double   originalLot;
   datetime openTime;
   int      delaySeconds;
   int      randomBEPips;
   int      randomL2Pips;
   int      trailLevel;
   bool     partialClosed;
};

//--- globals
CTrade trade;
int atrHandle, h1EmaHandle;
datetime lastBar = 0;
datetime lastTradeTime = 0;
int lossStreak = 0;

PendingTradeInfo g_pendingTrade;
PositionInfo     g_positions[];
int              g_posCount = 0;

// Debug counters
int g_signalCount = 0;
int g_trendBlockCount = 0;
int g_volBlockCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_M5, ATRperiod);
   h1EmaHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE || h1EmaHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   g_pendingTrade.active = false;
   ArrayResize(g_positions, 0);
   g_posCount = 0;

   Print("=== KymcoDe v4.0 Cla - ENHANCED + FIXED ===");
   Print("Symbol: ", _Symbol);
   Print("Trend Filter: ", UseTrendFilter ? "ON" : "OFF", " (Strict: ", StrictTrendFilter ? "ON" : "OFF", ")");
   Print("Partial TP: ", UsePartialTP ? "ON" : "OFF");
   Print("SL=", SLMultiplier, "xATR, TP=", TPMultiplier, "xATR");
   Print("MinATR=", MinATRPoints, " points, MaxATR=", MaxATRPoints, " points");

   // Prikaži trenutni ATR za provjeru
   double atr = GetATR(1);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   Print("Current ATR: ", DoubleToString(atr, _Digits), " = ", DoubleToString(atr/point, 0), " points");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(h1EmaHandle != INVALID_HANDLE) IndicatorRelease(h1EmaHandle);

   Print("=== KymcoDe v4.0 Stats ===");
   Print("Signals detected: ", g_signalCount);
   Print("Blocked by trend: ", g_trendBlockCount);
   Print("Blocked by volatility: ", g_volBlockCount);
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
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, shift, 1, atr) <= 0) return 0;
   return atr[0];
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
//| TREND FILTER: H1 EMA direction (poboljšan)                       |
//+------------------------------------------------------------------+
int GetH1TrendDirection()
{
   if(!UseTrendFilter) return 0;

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(h1EmaHandle, 0, 0, 3, ema) < 3) return 0;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATR(1);
   double threshold = atr * TrendThreshold;  // Koristi input parametar

   // Bullish: cijena iznad EMA i EMA raste
   if(price > ema[0] + threshold && ema[0] > ema[1]) return 1;

   // Bearish: cijena ispod EMA i EMA pada
   if(price < ema[0] - threshold && ema[0] < ema[1]) return -1;

   // Lakši uvjet - samo pozicija relativno na EMA
   if(price > ema[0]) return 1;   // Iznad EMA = bullish bias
   if(price < ema[0]) return -1;  // Ispod EMA = bearish bias

   return 0;
}

//+------------------------------------------------------------------+
//| TREND FILTER: Hull MA direction (M5)                             |
//+------------------------------------------------------------------+
int GetHullDirection()
{
   if(!UseTrendFilter) return 0;

   double close[];
   ArraySetAsSeries(close, true);
   int bars = HullPeriod * 2 + 5;
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, close) <= 0) return 0;

   int halfPeriod = HullPeriod / 2;

   // Current Hull
   double wmaHalf = 0.0, wmaFull = 0.0;
   double sumWeightsHalf = 0.0, sumWeightsFull = 0.0;

   for(int i = 0; i < halfPeriod; i++)
   {
      double w = (double)(halfPeriod - i);
      wmaHalf += close[i+1] * w;
      sumWeightsHalf += w;
   }
   if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;

   for(int i = 0; i < HullPeriod; i++)
   {
      double w = (double)(HullPeriod - i);
      wmaFull += close[i+1] * w;
      sumWeightsFull += w;
   }
   if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;

   double hullCurrent = 2.0 * wmaHalf - wmaFull;

   // Previous Hull
   wmaHalf = 0.0; wmaFull = 0.0;
   sumWeightsHalf = 0.0; sumWeightsFull = 0.0;

   for(int i = 0; i < halfPeriod; i++)
   {
      double w = (double)(halfPeriod - i);
      wmaHalf += close[i+3] * w;
      sumWeightsHalf += w;
   }
   if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;

   for(int i = 0; i < HullPeriod; i++)
   {
      double w = (double)(HullPeriod - i);
      wmaFull += close[i+3] * w;
      sumWeightsFull += w;
   }
   if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;

   double hullPrev = 2.0 * wmaHalf - wmaFull;

   double diff = hullCurrent - hullPrev;
   double atr = GetATR(1);
   double threshold = atr * 0.1;

   if(diff > threshold) return 1;
   if(diff < -threshold) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| COMBINED TREND: H1 + Hull (poboljšan)                            |
//+------------------------------------------------------------------+
int GetCombinedTrend()
{
   int h1Trend = GetH1TrendDirection();
   int hullTrend = GetHullDirection();

   if(StrictTrendFilter)
   {
      // Oba moraju biti isti smjer
      if(h1Trend == 1 && hullTrend >= 0) return 1;
      if(h1Trend == -1 && hullTrend <= 0) return -1;
      return 0;
   }
   else
   {
      // Lakši uvjet - H1 određuje smjer, Hull ne smije biti suprotan
      if(h1Trend >= 1 && hullTrend != -1) return 1;   // H1 bullish, Hull nije bearish
      if(h1Trend <= -1 && hullTrend != 1) return -1;  // H1 bearish, Hull nije bullish

      // Ako je H1 neutralan, koristi Hull
      if(h1Trend == 0) return hullTrend;

      return 0;
   }
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Nedjelja: nakon 01:01 (MT5 time = User 00:01)
   if(dt.day_of_week == 0)
      return (dt.hour > 1 || (dt.hour == 1 && dt.min >= 1));

   // Pon-Čet: cijeli dan
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;

   // Petak: do 12:30 (MT5 time = User 11:30)
   if(dt.day_of_week == 5)
      return (dt.hour < 12 || (dt.hour == 12 && dt.min <= 30));

   return false;
}

//+------------------------------------------------------------------+
bool IsBlackoutPeriod()
{
   if(!UseStealthMode) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int minutes = dt.hour * 60 + dt.min;
   return (minutes >= 15*60+30 && minutes < 16*60+30);
}

//+------------------------------------------------------------------+
bool IsLargeCandle()
{
   if(!UseStealthMode) return false;

   double atr = GetATR(1);
   if(atr <= 0) return false;

   double high = iHigh(_Symbol, PERIOD_M5, 1);
   double low  = iLow(_Symbol, PERIOD_M5, 1);

   return ((high - low) > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   double atrPoints = GetATRPoints(1);

   bool ok = (atrPoints >= MinATRPoints && atrPoints <= MaxATRPoints);

   if(!ok)
   {
      g_volBlockCount++;
      // Debug output svakih 100 blokova
      if(g_volBlockCount % 100 == 1)
         Print("Volatility blocked: ATR=", DoubleToString(atrPoints, 0),
               " points (min=", MinATRPoints, ", max=", MaxATRPoints, ")");
   }

   return ok;
}

//+------------------------------------------------------------------+
//| SIGNAL: Donchian Breakout (s trend filterom)                     |
//+------------------------------------------------------------------+
void CheckDonchianSignal()
{
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol, PERIOD_M5, 1, DonchianPeriod, high) < DonchianPeriod) return;
   if(CopyLow(_Symbol, PERIOD_M5, 1, DonchianPeriod, low) < DonchianPeriod) return;
   if(CopyClose(_Symbol, PERIOD_M5, 1, 1, close) != 1) return;

   double upper = high[ArrayMaximum(high)];
   double lower = low[ArrayMinimum(low)];

   int trend = GetCombinedTrend();

   // Breakout BUY
   if(close[0] > upper)
   {
      g_signalCount++;

      if(!UseTrendFilter || trend >= 0)
      {
         Print("BUY signal: Donchian breakout above ", DoubleToString(upper, _Digits),
               ", trend=", trend);
         QueueTrade(ORDER_TYPE_BUY);
      }
      else
      {
         g_trendBlockCount++;
         Print("BUY blocked by trend filter: trend=", trend);
      }
   }
   // Breakout SELL
   else if(close[0] < lower)
   {
      g_signalCount++;

      if(!UseTrendFilter || trend <= 0)
      {
         Print("SELL signal: Donchian breakout below ", DoubleToString(lower, _Digits),
               ", trend=", trend);
         QueueTrade(ORDER_TYPE_SELL);
      }
      else
      {
         g_trendBlockCount++;
         Print("SELL blocked by trend filter: trend=", trend);
      }
   }
}

//+------------------------------------------------------------------+
//| Queue trade s ATR-based SL/TP                                    |
//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
   double atr = GetATR(1);
   if(atr <= 0) return;

   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist = atr * SLMultiplier;
   double tpDist = atr * TPMultiplier;
   double partialDist = atr * PartialTPMultiplier;

   double sl = (type == ORDER_TYPE_BUY) ? entry - slDist : entry + slDist;
   double tp = (type == ORDER_TYPE_BUY) ? entry + tpDist : entry - tpDist;
   double partialTP = (type == ORDER_TYPE_BUY) ? entry + partialDist : entry - partialDist;

   double lot = CalculateLot(slDist);
   if(lot <= 0) return;

   if(UseStealthMode)
   {
      g_pendingTrade.active = true;
      g_pendingTrade.type = type;
      g_pendingTrade.lot = lot;
      g_pendingTrade.intendedSL = sl;
      g_pendingTrade.intendedTP = tp;
      g_pendingTrade.partialTP = UsePartialTP ? partialTP : 0;
      g_pendingTrade.signalTime = TimeCurrent();
      g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
      Print("KymcoDe v4: Trade queued (", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            "), ATR=", DoubleToString(atr, _Digits), ", delay ", g_pendingTrade.delaySeconds, "s");
   }
   else
   {
      ExecuteTrade(type, lot, sl, tp, UsePartialTP ? partialTP : 0);
   }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp, double partialTP)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool ok;
   if(UseStealthMode)
   {
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, 0, 0, "KymcoDe v4")
           : trade.Sell(lot, _Symbol, entry, 0, 0, "KymcoDe v4");
   }
   else
   {
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, sl, tp, "KymcoDe v4")
           : trade.Sell(lot, _Symbol, entry, sl, tp, "KymcoDe v4");
   }

   if(ok)
   {
      lastTradeTime = TimeCurrent();
      ulong ticket = trade.ResultOrder();

      ArrayResize(g_positions, g_posCount + 1);
      g_positions[g_posCount].active = true;
      g_positions[g_posCount].ticket = ticket;
      g_positions[g_posCount].intendedSL = sl;
      g_positions[g_posCount].stealthTP = tp;
      g_positions[g_posCount].partialTP = partialTP;
      g_positions[g_posCount].entryPrice = entry;
      g_positions[g_posCount].originalLot = lot;
      g_positions[g_posCount].openTime = TimeCurrent();
      g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
      g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
      g_positions[g_posCount].randomL2Pips = RandomRange(TrailLevel2LockMin, TrailLevel2LockMax);
      g_positions[g_posCount].trailLevel = 0;
      g_positions[g_posCount].partialClosed = false;
      g_posCount++;

      Print("KymcoDe v4: Opened ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " #", ticket, " @ ", entry, ", lot=", lot);
      if(UseStealthMode)
         Print("  Stealth: SL delay ", g_positions[g_posCount-1].delaySeconds, "s, BE+", g_positions[g_posCount-1].randomBEPips);
   }
   else
   {
      Print("KymcoDe v4 ERROR: Trade failed - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
double CalculateLot(double slDist)
{
   if(slDist <= 0) return 0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || point <= 0) return 0;

   double slPoints = slDist / point;
   double lot = riskMoney / (slPoints * tickValue / tickSize);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = MathFloor(lot / step) * step;
   return MathMax(minLot, MathMin(maxLot, lot));
}

//+------------------------------------------------------------------+
void ProcessPendingTrade()
{
   if(!g_pendingTrade.active) return;

   if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
   {
      ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                   g_pendingTrade.intendedSL, g_pendingTrade.intendedTP,
                   g_pendingTrade.partialTP);
      g_pendingTrade.active = false;
   }
}

//+------------------------------------------------------------------+
void ManageStealthPositions()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = g_posCount - 1; i >= 0; i--)
   {
      if(!g_positions[i].active) continue;

      ulong ticket = g_positions[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         g_positions[i].active = false;
         continue;
      }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentLot = PositionGetDouble(POSITION_VOLUME);
      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- 1. Delayed SL
      if(currentSL == 0 && g_positions[i].intendedSL != 0)
      {
         if(TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds)
         {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
               Print("KymcoDe STEALTH: SL set for #", ticket, " @ ", sl);
         }
      }

      //--- 2. Partial TP (zatvori 50% na 1:1)
      if(UsePartialTP && !g_positions[i].partialClosed && g_positions[i].partialTP > 0)
      {
         bool partialHit = false;
         if(posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].partialTP)
            partialHit = true;
         if(posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].partialTP)
            partialHit = true;

         if(partialHit)
         {
            double closeLot = NormalizeDouble(currentLot * PartialTPRatio, 2);
            double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            if(closeLot >= minLot && (currentLot - closeLot) >= minLot)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  g_positions[i].partialClosed = true;
                  Print("KymcoDe: Partial TP (", DoubleToString(closeLot, 2), " lots) for #", ticket);

                  // Pomakni SL na BE nakon partial TP
                  if(currentSL > 0)
                  {
                     double beSL = g_positions[i].entryPrice;
                     if(posType == POSITION_TYPE_BUY && beSL > currentSL)
                        trade.PositionModify(ticket, NormalizeDouble(beSL, digits), 0);
                     else if(posType == POSITION_TYPE_SELL && beSL < currentSL)
                        trade.PositionModify(ticket, NormalizeDouble(beSL, digits), 0);
                  }
               }
            }
         }
      }

      //--- 3. Stealth TP check (za ostatak)
      if(g_positions[i].stealthTP > 0)
      {
         bool tpHit = false;
         if(posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP)
            tpHit = true;
         if(posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP)
            tpHit = true;

         if(tpHit)
         {
            trade.PositionClose(ticket);
            Print("KymcoDe STEALTH: Full TP hit for #", ticket);
            g_positions[i].active = false;
            continue;
         }
      }

      //--- 4. Trailing Level 2 (800 pips -> lock 150-200 pips)
      if(g_positions[i].trailLevel < 2 && currentSL > 0)
      {
         double profitPips = (posType == POSITION_TYPE_BUY)
                             ? (currentPrice - g_positions[i].entryPrice) / point
                             : (g_positions[i].entryPrice - currentPrice) / point;

         if(profitPips >= TrailLevel2Pips)
         {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
               newSL = g_positions[i].entryPrice + g_positions[i].randomL2Pips * point;
            else
               newSL = g_positions[i].entryPrice - g_positions[i].randomL2Pips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
               g_positions[i].trailLevel = 2;
               Print("KymcoDe: Trail L2 lock +", g_positions[i].randomL2Pips, " pips for #", ticket);
            }
         }
      }

      //--- 5. Trailing Level 1 (500 pips -> BE + 33-38)
      if(g_positions[i].trailLevel < 1 && currentSL > 0)
      {
         double profitPips = (posType == POSITION_TYPE_BUY)
                             ? (currentPrice - g_positions[i].entryPrice) / point
                             : (g_positions[i].entryPrice - currentPrice) / point;

         if(profitPips >= TrailActivatePips)
         {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
               newSL = g_positions[i].entryPrice + g_positions[i].randomBEPips * point;
            else
               newSL = g_positions[i].entryPrice - g_positions[i].randomBEPips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
               g_positions[i].trailLevel = 1;
               Print("KymcoDe: Trail L1 BE+", g_positions[i].randomBEPips, " for #", ticket);
            }
         }
      }
   }

   CleanupPositions();
}

//+------------------------------------------------------------------+
void CleanupPositions()
{
   int newCount = 0;
   for(int i = 0; i < g_posCount; i++)
   {
      if(g_positions[i].active)
      {
         if(i != newCount)
            g_positions[newCount] = g_positions[i];
         newCount++;
      }
   }
   if(newCount != g_posCount)
   {
      g_posCount = newCount;
      ArrayResize(g_positions, g_posCount);
   }
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
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
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber &&
            HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT)
            {
               double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               if(profit < 0)
                  lossStreak++;
               else
                  lossStreak = 0;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ProcessPendingTrade();
   ManageStealthPositions();

   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == lastBar) return;
   lastBar = barTime;

   // Provjere za novi trade
   if(!IsTradingWindow()) return;
   if(IsLargeCandle()) return;
   if(!IsVolatilityOK()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   if(CurrentDailyDD() <= -MaxDailyDD) return;
   if(HasOpenPosition()) return;
   if(g_pendingTrade.active) return;
   if(TimeCurrent() - lastTradeTime < CooldownBars * PeriodSeconds(PERIOD_M5)) return;

   // Donchian breakout signal
   CheckDonchianSignal();
}

//+------------------------------------------------------------------+
double OnTester()
{
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades = TesterStatistics(STAT_TRADES);
   double winRate = trades > 0 ? TesterStatistics(STAT_PROFIT_TRADES) / trades * 100 : 0;

   if(trades < 50) return 0;
   return profitFactor * MathSqrt(trades) * (winRate / 50);
}
//+------------------------------------------------------------------+
