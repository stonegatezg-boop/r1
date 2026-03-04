//+------------------------------------------------------------------+
//|                                          SwingFree_MACDL_Cla.mq5 |
//|                         Swing Free Range Filter + MACD Leader    |
//|                                          Za XAUUSD M5            |
//|                   Version 2.2 - Fixed: 04.03.2026 (Zagreb)       |
//|                   SL ODMAH + 3-level trailing + MFE              |
//+------------------------------------------------------------------+
#property copyright "SwingFree_MACDL_Cla v2.2 (2026-03-04)"
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
input int      MagicNumber = 667788;
input double   MaxSpread = 50;

// === SWING FREE (RANGE FILTER) ===
input string   INFO2 = "=== SWING FREE ===";
input int      SwingPeriod = 20;              // Swing Period (default 20)
input double   SwingMultiplier = 3.5;         // Swing Multiplier (default 3.5)
input ENUM_APPLIED_PRICE SwingSource = PRICE_CLOSE;

// === MACD LEADER ===
input string   INFO3 = "=== MACD LEADER ===";
input int      MACDL_FastLength = 12;
input int      MACDL_SlowLength = 26;

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
int      trailLevel = 0;
double   maxProfitPips = 0;
int      barsInTrade = 0;
datetime lastBarTime = 0;

// Points conversion
double   pipValue;
int      pipDigits;

// Range Filter state
double   rangeFilter = 0;
double   hiBand = 0;
double   loBand = 0;
int      filterDirection = 0;  // 1 = up, -1 = down

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // XAUUSD pip = 0.01 (ISPRAVNO!)
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

   // Initialize range filter
   rangeFilter = iClose(_Symbol, PERIOD_CURRENT, 1);

   CheckExistingPosition();

   Print("╔═══════════════════════════════════════════════════════════════╗");
   Print("║     SWINGFREE_MACDL_CLA v2.2 - SL ODMAH                      ║");
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
   Print("SwingFree_MACDL_Cla removed. Reason: ", reason);
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
//| GET SOURCE PRICE                                                   |
//+------------------------------------------------------------------+
double GetSourcePrice(int shift)
{
   switch(SwingSource)
   {
      case PRICE_CLOSE:  return iClose(_Symbol, PERIOD_CURRENT, shift);
      case PRICE_OPEN:   return iOpen(_Symbol, PERIOD_CURRENT, shift);
      case PRICE_HIGH:   return iHigh(_Symbol, PERIOD_CURRENT, shift);
      case PRICE_LOW:    return iLow(_Symbol, PERIOD_CURRENT, shift);
      case PRICE_MEDIAN: return (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift)) / 2;
      case PRICE_TYPICAL: return (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift) + iClose(_Symbol, PERIOD_CURRENT, shift)) / 3;
      case PRICE_WEIGHTED: return (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift) + iClose(_Symbol, PERIOD_CURRENT, shift) * 2) / 4;
      default: return iClose(_Symbol, PERIOD_CURRENT, shift);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE RANGE SIZE                                               |
//+------------------------------------------------------------------+
double CalculateRangeSize()
{
   // AC = ema(ema(abs(x - x[1]), n), wper) * qty
   // wper = (n*2) - 1

   int wper = (SwingPeriod * 2) - 1;

   // Calculate average range using EMA
   double sumRange = 0;
   double alpha1 = 2.0 / (SwingPeriod + 1);
   double avrng = 0;

   // First pass - calculate avrng (EMA of absolute changes)
   for(int i = SwingPeriod + wper; i >= 1; i--)
   {
      double src = GetSourcePrice(i);
      double srcPrev = GetSourcePrice(i + 1);
      double change = MathAbs(src - srcPrev);

      if(i == SwingPeriod + wper)
         avrng = change;
      else
         avrng = alpha1 * change + (1 - alpha1) * avrng;
   }

   // Second pass - smooth with wper EMA
   double alpha2 = 2.0 / (wper + 1);
   double ac = avrng;

   for(int i = wper; i >= 1; i--)
   {
      double src = GetSourcePrice(i);
      double srcPrev = GetSourcePrice(i + 1);
      double change = MathAbs(src - srcPrev);

      avrng = alpha1 * change + (1 - alpha1) * avrng;
      ac = alpha2 * avrng + (1 - alpha2) * ac;
   }

   return ac * SwingMultiplier;
}

//+------------------------------------------------------------------+
//| CALCULATE RANGE FILTER                                             |
//+------------------------------------------------------------------+
void CalculateRangeFilter(double &filt, double &hBand, double &lBand, int &fDir)
{
   double src = GetSourcePrice(1);
   double rng = CalculateRangeSize();

   static double prevFilt = 0;
   static int prevDir = 0;

   if(prevFilt == 0)
      prevFilt = src;

   // Range filter logic
   if(src - rng > prevFilt)
      filt = src - rng;
   else if(src + rng < prevFilt)
      filt = src + rng;
   else
      filt = prevFilt;

   // Direction
   if(filt > prevFilt)
      fDir = 1;
   else if(filt < prevFilt)
      fDir = -1;
   else
      fDir = prevDir;

   // Bands
   hBand = filt + rng;
   lBand = filt - rng;

   prevFilt = filt;
   prevDir = fDir;
}

//+------------------------------------------------------------------+
//| CALCULATE MACD LEADER                                              |
//+------------------------------------------------------------------+
double CalculateMACDLeader()
{
   // MACD Leader by LazyBear
   // i1 = sema + ma(src - sema, shortLength)
   // i2 = lema + ma(src - lema, longLength)
   // macdl = i1 - i2

   double src = iClose(_Symbol, PERIOD_CURRENT, 1);

   // Calculate short EMA
   int handleFast = iMA(_Symbol, PERIOD_CURRENT, MACDL_FastLength, 0, MODE_EMA, PRICE_CLOSE);
   double sema[];
   ArraySetAsSeries(sema, true);
   CopyBuffer(handleFast, 0, 0, MACDL_FastLength + 5, sema);
   IndicatorRelease(handleFast);

   // Calculate long EMA
   int handleSlow = iMA(_Symbol, PERIOD_CURRENT, MACDL_SlowLength, 0, MODE_EMA, PRICE_CLOSE);
   double lema[];
   ArraySetAsSeries(lema, true);
   CopyBuffer(handleSlow, 0, 0, MACDL_SlowLength + 5, lema);
   IndicatorRelease(handleSlow);

   // Calculate (src - sema) EMA for leading component
   double diffFast = src - sema[1];
   double diffSlow = src - lema[1];

   // Simple approximation of the leading component
   // Using recent bars to estimate the EMA of differences
   double sumDiffFast = 0;
   double sumDiffSlow = 0;

   for(int i = 1; i <= 5; i++)
   {
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      sumDiffFast += (c - sema[i]);
      sumDiffSlow += (c - lema[i]);
   }

   double avgDiffFast = sumDiffFast / 5;
   double avgDiffSlow = sumDiffSlow / 5;

   double i1 = sema[1] + avgDiffFast;
   double i2 = lema[1] + avgDiffSlow;

   return i1 - i2;
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIKA                                                      |
//+------------------------------------------------------------------+
int GetSignal()
{
   // 1. Calculate Range Filter (Swing Free)
   double filt, hBand, lBand;
   int fDir;
   CalculateRangeFilter(filt, hBand, lBand, fDir);

   rangeFilter = filt;
   hiBand = hBand;
   loBand = lBand;
   filterDirection = fDir;

   // 2. Get source price and check conditions
   double src = GetSourcePrice(1);
   double srcPrev = GetSourcePrice(2);

   bool upward = (fDir == 1);
   bool downward = (fDir == -1);

   // Long condition: src > filt and upward
   bool longCond = (src > filt) && upward;
   // Short condition: src < filt and downward
   bool shortCond = (src < filt) && downward;

   // Track condition state for signal change detection
   static int condIni = 0;
   int prevCondIni = condIni;

   if(longCond)
      condIni = 1;
   else if(shortCond)
      condIni = -1;

   // Signal only on condition change
   bool longSignal = longCond && (prevCondIni == -1);
   bool shortSignal = shortCond && (prevCondIni == 1);

   // 3. Calculate MACD Leader
   double macdl = CalculateMACDLeader();

   // 4. Current candle confirmation
   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double currentOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
   bool bullishCandle = currentClose > currentOpen;
   bool bearishCandle = currentClose < currentOpen;

   // 5. Final signals
   // BUY: Swing Free buy signal + bullish candle + MACD Leader > 0
   if(longSignal && bullishCandle && macdl > 0)
   {
      Print("BUY Signal! Filter: ", filt, " | MACD Leader: ", macdl, " | Direction: UP");
      return 1;
   }

   // SELL: Swing Free sell signal + bearish candle + MACD Leader < 0
   if(shortSignal && bearishCandle && macdl < 0)
   {
      Print("SELL Signal! Filter: ", filt, " | MACD Leader: ", macdl, " | Direction: DOWN");
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

   if(trade.Buy(LotSize, _Symbol, ask, sl, 0, "SwingFree BUY"))
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
      Print("║ SWINGFREE BUY #", currentTicket, " | SL ODMAH");
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

   if(trade.Sell(LotSize, _Symbol, bid, sl, 0, "SwingFree SELL"))
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
      Print("║ SWINGFREE SELL #", currentTicket, " | SL ODMAH");
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

   // Stealth TP - check targets
   CheckTargets(profitPips, currentPrice);

   // Trailing
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

   // MFE Trailing
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
