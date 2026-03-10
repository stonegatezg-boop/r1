//+------------------------------------------------------------------+
//|                                                  Mix2_ADX_Cla.mq5|
//|      *** MIX2 - IMPROVED EMA Cross + ADX + Anti-Late Entry ***   |
//|                   XAUUSD M5 Optimized                            |
//|                                                                  |
//|   IMPROVEMENTS over Mix1:                                        |
//|   - MaxBarsInTrend filter (no late entries)                      |
//|   - Distance from EMA filter                                     |
//|   - Pullback detection before entry                              |
//|   - Stronger ADX requirements                                    |
//|   - Random SL 988-1054 pips                                      |
//|   - Better Time Failure parameters                               |
//|   - SL ODMAH (immediate)                                         |
//|   - BE+ @1000 pips, Trailing 1000 pips                           |
//|                                                                  |
//|   Created: 05.03.2026 (Zagreb)                                   |
//|   Fixed: 10.03.2026 (Zagreb) - Random SL, BE+@1000, Trail 1000   |
//+------------------------------------------------------------------+
#property copyright "Mix2_ADX_Cla v1.1 (10.03.2026)"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== EMA CROSS POSTAVKE ==="
input int      EMA_Fast           = 26;
input int      EMA_Medium         = 50;
input int      MA_Trend           = 200;

input group "=== ADX/DI POSTAVKE ==="
input int      ADX_Period         = 14;
input int      ADX_Threshold      = 25;       // Povecano s 22
input int      ADX_MinEntry       = 20;       // NIKAD ne ulazi ispod ovoga
input double   DI_Buffer          = 5.0;      // Fiksni buffer (ne %)

input group "=== ANTI-LATE ENTRY FILTERI ==="
input bool     UseAntiLateEntry   = true;
input int      MaxBarsInTrend     = 15;       // Max barova u istom trendu
input double   MaxDistanceATR     = 2.0;      // Max udaljenost od EMA
input bool     RequirePullback    = true;     // Cekaj pullback prije ulaza
input int      PullbackBars       = 3;        // Koliko barova provjeravati

input group "=== SL POSTAVKE (RANDOM) ==="
input int      InitialSL_Min      = 988;      // SL min pips
input int      InitialSL_Max      = 1054;     // SL max pips

input group "=== TARGETS (ATR MULTIPLE) ==="
input double   Target1_ATR        = 1.5;
input double   Target2_ATR        = 2.5;
input double   Target3_ATR        = 4.0;
input int      ClosePercent1      = 33;
input int      ClosePercent2      = 50;

input group "=== TRAILING STANDARD ==="
input int      TrailingStartBE    = 1000;     // BE+ aktivacija (pips profit)
input int      BEOffset_Min       = 41;       // BE+ offset min pips
input int      BEOffset_Max       = 46;       // BE+ offset max pips
input int      TrailingDistance   = 1000;     // Trailing udaljenost (pips)

input group "=== FAILURE EXITS ==="
input int      EarlyFailurePips   = 800;
input int      TimeFailureBars    = 8;        // Povecano s 3
input int      TimeFailurePips    = 80;       // Povecano s 20

input group "=== FILTERI ==="
input double   MaxSpread          = 50;
input double   LargeCandleATR     = 2.5;      // Smanjeno s 3.0
input double   Channel_ATR_Mult   = 0.618;

input group "=== RADNO VRIJEME (ZAGREB) ==="
input int      ZagrebStartHour    = 8;        // Početak tradinga
input int      ZagrebEndHour      = 22;       // Kraj tradinga
input int      FridayCloseHour    = 20;       // Petak zatvaranje

input group "=== RISK ==="
input double   RiskPercent        = 1.0;
input double   LotSize            = 0.01;     // Ako RiskPercent=0
input ulong    MagicNumber        = 261451;

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
struct PositionData
{
   bool     active;
   ulong    ticket;
   double   entryPrice;
   double   tp1, tp2, tp3;
   double   initialLots;
   int      targetHit;
   bool     beActivated;        // BE+ aktiviran
   int      beOffset;           // Random BE offset za ovu poziciju
   double   maxProfitPips;
   int      barsInTrade;
   datetime openTime;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade trade;
int atrHandle, adxHandle, emaFastHandle, emaMedHandle, maTrendHandle;

datetime lastBarTime = 0;
int currentTrendDir = 0;
int barsInCurrentTrend = 0;

PositionData g_pos[];
int g_posCount = 0;

double pipValue = 0.01;  // XAUUSD

int statBuys = 0, statSells = 0;
int statLateBlocked = 0, statPullbackBlocked = 0;
int statADXBlocked = 0, statDistanceBlocked = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   adxHandle = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaMedHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Medium, 0, MODE_EMA, PRICE_CLOSE);
   maTrendHandle = iMA(_Symbol, PERIOD_CURRENT, MA_Trend, 0, MODE_SMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE ||
      emaFastHandle == INVALID_HANDLE || emaMedHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create handles");
      return INIT_FAILED;
   }

   ArrayResize(g_pos, 0);
   g_posCount = 0;

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

   Print("=====================================================");
   Print("     MIX2_ADX v1.1 - IMPROVED VERSION");
   Print("=====================================================");
   Print("EMA: ", EMA_Fast, "/", EMA_Medium, "/", MA_Trend);
   Print("ADX Threshold: ", ADX_Threshold, " (min ", ADX_MinEntry, ")");
   Print("Anti-Late: MaxBars=", MaxBarsInTrend, " MaxDist=", MaxDistanceATR, " ATR");
   Print("Pullback: ", RequirePullback ? "ON" : "OFF");
   Print("SL: RANDOM ", InitialSL_Min, "-", InitialSL_Max, " pips ODMAH");
   Print("Targets: ", Target1_ATR, "x / ", Target2_ATR, "x / ", Target3_ATR, "x ATR");
   Print("BE+: @", TrailingStartBE, " pips -> entry+", BEOffset_Min, "-", BEOffset_Max);
   Print("Trailing: ", TrailingDistance, " pips distance");
   Print("Time Exit: ", TimeFailureBars, " bars, ", TimeFailurePips, " pips");
   Print("=====================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaMedHandle != INVALID_HANDLE) IndicatorRelease(emaMedHandle);
   if(maTrendHandle != INVALID_HANDLE) IndicatorRelease(maTrendHandle);

   Print("=====================================================");
   Print("     MIX2_ADX - STATISTICS");
   Print("=====================================================");
   Print("BUY: ", statBuys, " | SELL: ", statSells);
   Print("Blocked - Late Entry: ", statLateBlocked);
   Print("Blocked - No Pullback: ", statPullbackBlocked);
   Print("Blocked - Weak ADX: ", statADXBlocked);
   Print("Blocked - Too Far: ", statDistanceBlocked);
   Print("=====================================================");
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
double GetATR(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double GetMA(int handle, int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double GetADX(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(adxHandle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double GetDIPlus(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(adxHandle, 1, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double GetDIMinus(int shift = 1)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(adxHandle, 2, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| TRADING WINDOW (Zagreb Time)                                      |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Nedjelja - ne trejdaj do 00:01
   if(dt.day_of_week == 0)
      return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

   // Subota - ne trejdaj
   if(dt.day_of_week == 6)
      return false;

   // Petak - završi ranije
   if(dt.day_of_week == 5)
   {
      if(dt.hour >= FridayCloseHour) return false;
   }

   // Pon-Pet: Trading window
   if(dt.hour < ZagrebStartHour || dt.hour >= ZagrebEndHour)
      return false;

   return true;
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpread);
}

//+------------------------------------------------------------------+
bool IsLargeCandle()
{
   double atr = GetATR(1);
   if(atr <= 0) return false;
   double size = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
   return (size > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| TREND DIRECTION - with bars counter                               |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   double emaFast = GetMA(emaFastHandle, 1);
   double emaMed = GetMA(emaMedHandle, 1);
   double maTrend = GetMA(maTrendHandle, 1);
   double atr = GetATR(1);
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(emaFast <= 0 || emaMed <= 0 || maTrend <= 0 || atr <= 0) return 0;

   int maDir = (emaFast > emaMed) ? 1 : -1;
   int maTrendDir = (close >= maTrend) ? 1 : -1;

   // Channel check
   double rangeTop = maTrend + atr * Channel_ATR_Mult;
   double rangeBot = maTrend - atr * Channel_ATR_Mult;
   bool inChannel = (close <= rangeTop && close >= rangeBot);

   if(inChannel) return 0;

   if(maTrendDir == 1 && maDir == 1) return 1;
   if(maTrendDir == -1 && maDir == -1) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| ADX/DI Signal - IMPROVED                                          |
//+------------------------------------------------------------------+
int GetADXSignal()
{
   double adx = GetADX(1);
   double diPlus = GetDIPlus(1);
   double diMinus = GetDIMinus(1);

   if(adx <= 0) return 0;

   // ADX minimum check
   if(adx < ADX_MinEntry)
   {
      statADXBlocked++;
      return 0;
   }

   // Fixed buffer (not percentage)
   bool bullish = (diPlus > diMinus + DI_Buffer);
   bool bearish = (diMinus > diPlus + DI_Buffer);

   if(bullish && adx >= ADX_Threshold) return 1;
   if(bearish && adx >= ADX_Threshold) return -1;

   // Weak signal (ADX between min and threshold)
   if(bullish && adx >= ADX_MinEntry) return 1;
   if(bearish && adx >= ADX_MinEntry) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| PULLBACK DETECTION                                                |
//+------------------------------------------------------------------+
bool HasPullback(int direction)
{
   if(!RequirePullback) return true;

   int oppositeCandles = 0;

   for(int i = 2; i <= PullbackBars + 1; i++)
   {
      double o = iOpen(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i);

      if(direction == 1 && c < o) oppositeCandles++;  // Red candle before BUY
      if(direction == -1 && c > o) oppositeCandles++; // Green candle before SELL
   }

   // Need at least 1 opposite candle (pullback)
   return (oppositeCandles >= 1);
}

//+------------------------------------------------------------------+
//| DISTANCE FROM EMA CHECK                                           |
//+------------------------------------------------------------------+
bool IsDistanceOK(int direction)
{
   if(!UseAntiLateEntry) return true;

   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double emaMed = GetMA(emaMedHandle, 1);
   double atr = GetATR(1);

   if(atr <= 0) return true;

   double distance = MathAbs(close - emaMed) / atr;

   if(distance > MaxDistanceATR)
   {
      statDistanceBlocked++;
      return false;
   }

   // Additional check: price should be on correct side of EMA
   if(direction == 1 && close < emaMed) return false;
   if(direction == -1 && close > emaMed) return false;

   return true;
}

//+------------------------------------------------------------------+
//| CANDLE CONFIRMATION                                               |
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
//| SIGNAL GENERATION - WITH ALL FILTERS                              |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
   int trendDir = GetTrendDirection();

   // Update bars counter
   if(trendDir == currentTrendDir && trendDir != 0)
      barsInCurrentTrend++;
   else
   {
      barsInCurrentTrend = 1;
      currentTrendDir = trendDir;
   }

   if(trendDir == 0) return 0;

   // 1. MaxBarsInTrend filter
   if(UseAntiLateEntry && barsInCurrentTrend > MaxBarsInTrend)
   {
      statLateBlocked++;
      return 0;
   }

   // 2. ADX/DI confirmation
   int adxSignal = GetADXSignal();
   if(adxSignal != trendDir) return 0;

   // 3. Distance from EMA
   if(!IsDistanceOK(trendDir)) return 0;

   // 4. Pullback check
   if(!HasPullback(trendDir))
   {
      statPullbackBlocked++;
      return 0;
   }

   // 5. Candle confirmation
   if(trendDir == 1 && !IsBullishCandle(1)) return 0;
   if(trendDir == -1 && !IsBearishCandle(1)) return 0;

   // All conditions met
   double adx = GetADX(1);
   double diPlus = GetDIPlus(1);
   double diMinus = GetDIMinus(1);

   Print("SIGNAL ", (trendDir == 1 ? "BUY" : "SELL"),
         " | BarsInTrend=", barsInCurrentTrend,
         " | ADX=", DoubleToString(adx, 1),
         " | DI+=", DoubleToString(diPlus, 1),
         " | DI-=", DoubleToString(diMinus, 1));

   return trendDir;
}

//+------------------------------------------------------------------+
//| HAS OPEN POSITION                                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(RiskPercent <= 0) return LotSize;
   if(slDistance <= 0) return LotSize;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0) return LotSize;

   double lots = riskAmount / ((slDistance / point) * tickValue / tickSize);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| OPEN TRADE - SL ODMAH (RANDOM)                                    |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
{
   double atr = GetATR(1);
   if(atr <= 0) return;

   double price = (direction == 1) ?
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Random SL između 988-1054 pips
   int slPips = InitialSL_Min + MathRand() % (InitialSL_Max - InitialSL_Min + 1);
   double slDistance = slPips * pipValue;

   // Random BE offset za ovu poziciju (za kasnije)
   int beOffset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

   double sl, tp1, tp2, tp3;

   if(direction == 1)
   {
      sl = price - slDistance;
      tp1 = price + Target1_ATR * atr;
      tp2 = price + Target2_ATR * atr;
      tp3 = price + Target3_ATR * atr;
   }
   else
   {
      sl = price + slDistance;
      tp1 = price - Target1_ATR * atr;
      tp2 = price - Target2_ATR * atr;
      tp3 = price - Target3_ATR * atr;
   }

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp1 = NormalizeDouble(tp1, digits);
   tp2 = NormalizeDouble(tp2, digits);
   tp3 = NormalizeDouble(tp3, digits);

   // SL ODMAH, TP=0 (stealth)
   bool ok;
   if(direction == 1)
      ok = trade.Buy(lots, _Symbol, price, sl, 0, "MIX2 BUY");
   else
      ok = trade.Sell(lots, _Symbol, price, sl, 0, "MIX2 SELL");

   if(ok)
   {
      ulong ticket = trade.ResultOrder();

      ArrayResize(g_pos, g_posCount + 1);
      g_pos[g_posCount].active = true;
      g_pos[g_posCount].ticket = ticket;
      g_pos[g_posCount].entryPrice = price;
      g_pos[g_posCount].tp1 = tp1;
      g_pos[g_posCount].tp2 = tp2;
      g_pos[g_posCount].tp3 = tp3;
      g_pos[g_posCount].initialLots = lots;
      g_pos[g_posCount].targetHit = 0;
      g_pos[g_posCount].beActivated = false;
      g_pos[g_posCount].beOffset = beOffset;
      g_pos[g_posCount].maxProfitPips = 0;
      g_pos[g_posCount].barsInTrade = 0;
      g_pos[g_posCount].openTime = TimeCurrent();
      g_posCount++;

      if(direction == 1) statBuys++;
      else statSells++;

      Print("=====================================================");
      Print("  MIX2 ", (direction == 1 ? "BUY" : "SELL"), " #", ticket);
      Print("  Entry: ", DoubleToString(price, digits));
      Print("  SL: ", DoubleToString(sl, digits), " (", slPips, " pips RANDOM) ODMAH");
      Print("  T1: ", DoubleToString(tp1, digits));
      Print("  T2: ", DoubleToString(tp2, digits));
      Print("  T3: ", DoubleToString(tp3, digits));
      Print("  BE+: @", TrailingStartBE, " pips -> +", beOffset, " | Trail: ", TrailingDistance);
      Print("  BarsInTrend: ", barsInCurrentTrend);
      Print("=====================================================");
   }
   else
   {
      Print("MIX2 ERROR: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| MANAGE POSITIONS                                                  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   for(int i = g_posCount - 1; i >= 0; i--)
   {
      if(!g_pos[i].active) continue;

      ulong ticket = g_pos[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         g_pos[i].active = false;
         continue;
      }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentLots = PositionGetDouble(POSITION_VOLUME);
      double currentPrice = (posType == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // Profit in pips
      double profitPips;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (currentPrice - g_pos[i].entryPrice) / pipValue;
      else
         profitPips = (g_pos[i].entryPrice - currentPrice) / pipValue;

      // Update MFE
      if(profitPips > g_pos[i].maxProfitPips)
         g_pos[i].maxProfitPips = profitPips;

      //=== EARLY FAILURE ===
      if(profitPips <= -EarlyFailurePips)
      {
         trade.PositionClose(ticket);
         g_pos[i].active = false;
         Print("MIX2: EARLY FAILURE @ ", DoubleToString(-profitPips, 0), " pips");
         continue;
      }

      //=== TARGET 1 ===
      if(g_pos[i].targetHit < 1)
      {
         bool t1Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_pos[i].tp1) ||
                      (posType == POSITION_TYPE_SELL && currentPrice <= g_pos[i].tp1);

         if(t1Hit)
         {
            double closeAmt = g_pos[i].initialLots * ClosePercent1 / 100.0;
            closeAmt = MathFloor(closeAmt / lotStep) * lotStep;
            closeAmt = MathMax(closeAmt, minLot);

            if(closeAmt < currentLots)
            {
               if(trade.PositionClosePartial(ticket, closeAmt))
               {
                  g_pos[i].targetHit = 1;
                  Print("MIX2: T1 HIT +", DoubleToString(profitPips, 0), " pips");
               }
            }
         }
      }

      //=== TARGET 2 ===
      if(g_pos[i].targetHit == 1)
      {
         bool t2Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_pos[i].tp2) ||
                      (posType == POSITION_TYPE_SELL && currentPrice <= g_pos[i].tp2);

         if(t2Hit)
         {
            if(!PositionSelectByTicket(ticket)) continue;
            currentLots = PositionGetDouble(POSITION_VOLUME);

            double closeAmt = currentLots * ClosePercent2 / 100.0;
            closeAmt = MathFloor(closeAmt / lotStep) * lotStep;
            closeAmt = MathMax(closeAmt, minLot);

            if(closeAmt < currentLots)
            {
               if(trade.PositionClosePartial(ticket, closeAmt))
               {
                  g_pos[i].targetHit = 2;
                  Print("MIX2: T2 HIT +", DoubleToString(profitPips, 0), " pips");
               }
            }
         }
      }

      //=== TARGET 3 ===
      if(g_pos[i].targetHit >= 1)
      {
         bool t3Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_pos[i].tp3) ||
                      (posType == POSITION_TYPE_SELL && currentPrice <= g_pos[i].tp3);

         if(t3Hit)
         {
            trade.PositionClose(ticket);
            g_pos[i].active = false;
            Print("MIX2: T3 HIT - FULL CLOSE +", DoubleToString(profitPips, 0), " pips");
            continue;
         }
      }

      //=== BE+ AKTIVACIJA (na 1000 pips profita) ===
      if(!g_pos[i].beActivated && profitPips >= TrailingStartBE)
      {
         double newSL;
         if(posType == POSITION_TYPE_BUY)
            newSL = g_pos[i].entryPrice + g_pos[i].beOffset * pipValue;
         else
            newSL = g_pos[i].entryPrice - g_pos[i].beOffset * pipValue;

         newSL = NormalizeDouble(newSL, digits);
         bool shouldMod = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && newSL < currentSL);

         if(shouldMod && trade.PositionModify(ticket, newSL, 0))
         {
            g_pos[i].beActivated = true;
            Print("MIX2: BE+ ACTIVATED @ ", TrailingStartBE, " pips -> entry+", g_pos[i].beOffset, " (SL=", newSL, ")");
         }
      }

      //=== TRAILING (nakon BE+, prati na 1000 pips udaljenosti) ===
      if(g_pos[i].beActivated)
      {
         double trailSL;
         if(posType == POSITION_TYPE_BUY)
            trailSL = currentPrice - TrailingDistance * pipValue;
         else
            trailSL = currentPrice + TrailingDistance * pipValue;

         trailSL = NormalizeDouble(trailSL, digits);
         bool shouldMod = (posType == POSITION_TYPE_BUY && trailSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && trailSL < currentSL);

         if(shouldMod && trade.PositionModify(ticket, trailSL, 0))
         {
            Print("MIX2: TRAILING @ ", TrailingDistance, " pips (SL=", trailSL, ")");
         }
      }
   }

   CleanupPositions();
}

//+------------------------------------------------------------------+
//| TIME FAILURE CHECK                                                |
//+------------------------------------------------------------------+
void CheckTimeFailure()
{
   for(int i = g_posCount - 1; i >= 0; i--)
   {
      if(!g_pos[i].active) continue;

      g_pos[i].barsInTrade++;

      if(g_pos[i].barsInTrade >= TimeFailureBars)
      {
         ulong ticket = g_pos[i].ticket;
         if(!PositionSelectByTicket(ticket)) continue;

         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         double profitPips;
         if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - g_pos[i].entryPrice) / pipValue;
         else
            profitPips = (g_pos[i].entryPrice - currentPrice) / pipValue;

         // Exit if not enough profit and not too much loss
         if(profitPips < TimeFailurePips && profitPips > -TimeFailurePips * 2)
         {
            trade.PositionClose(ticket);
            g_pos[i].active = false;
            Print("MIX2: TIME FAILURE after ", g_pos[i].barsInTrade, " bars, ", DoubleToString(profitPips, 0), " pips");
         }
      }
   }
}

//+------------------------------------------------------------------+
void CleanupPositions()
{
   int newCount = 0;
   for(int i = 0; i < g_posCount; i++)
   {
      if(g_pos[i].active)
      {
         if(i != newCount) g_pos[newCount] = g_pos[i];
         newCount++;
      }
   }
   if(newCount != g_posCount)
   {
      g_posCount = newCount;
      ArrayResize(g_pos, g_posCount);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!IsNewBar()) return;

   CheckTimeFailure();

   if(HasOpenPosition()) return;
   if(!IsTradingWindow()) return;
   if(!IsSpreadOK()) return;
   if(IsLargeCandle()) return;

   int signal = GetTradeSignal();

   if(signal == 1)
   {
      Print("=== MIX2 BUY SIGNAL ===");
      OpenTrade(1);
   }
   else if(signal == -1)
   {
      Print("=== MIX2 SELL SIGNAL ===");
      OpenTrade(-1);
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
