//+------------------------------------------------------------------+
//|                                                CALF_E_Breakout.mq5|
//|                        *** CALF E - Breakout ***                  |
//|                   + Stealth Mode v3.3 (PIP FIX)                  |
//|                   Created: 23.02.2026 (Zagreb)                    |
//|                   Fixed: 03.03.2026 14:30 (Zagreb)                |
//|                   Fixed: 03.03.2026 22:30 (Zagreb) - REAL SL     |
//|                   Fixed: 04.03.2026 (Zagreb) - PIP FIX *10       |
//|                   - SL 789-811 pips (random) ODMAH               |
//|                   - Stealth samo za TP                           |
//+------------------------------------------------------------------+
#property copyright "CALF E - Breakout v3.3 PIP FIX"
#property version   "3.30"
#property strict
#include <Trade\Trade.mqh>
input group "=== BREAKOUT POSTAVKE ==="
input int      LookbackBars     = 20;
input double   BreakoutBuffer   = 0.5;
input group "=== VOLUME FILTER ==="
input bool     UseVolumeFilter  = true;
input int      VolumePeriod     = 20;
input group "=== TRADE MANAGEMENT ==="
input int      HardSL_Pips      = 800;        // Hard SL u pipsima
input double   TPMultiplier     = 3.5;
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;
input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
// SLDelayMin/Max uklonjeni - SL se postavlja ODMAH (v3.2)
input double   LargeCandleATR   = 3.0;    // Filter dugih svijeća
input group "=== TRAILING POSTAVKE ==="
input int      TrailLevel1_Pips  = 500;   // Level 1: aktivacija
input int      TrailBEPipsMin    = 38;    // Level 1: BE + min
input int      TrailBEPipsMax    = 43;    // Level 1: BE + max
input int      TrailLevel2_Pips  = 800;   // Level 2: aktivacija
input int      TrailLock2_PipsMin = 150;  // Level 2: lock min
input int      TrailLock2_PipsMax = 200;  // Level 2: lock max
input int      TrailLevel3_Pips  = 1200;  // Level 3: aktivacija
input int      TrailDistance3    = 250;   // Level 3: trailing distance

input group "=== RANGE COMPRESSION ==="
input bool     UseRangeFilter    = true;  // Koristi range compression filter
input int      RangeATRPeriod    = 10;    // Period za compression check
input double   RangeCompressMin  = 0.7;   // Min ratio (uži range = bolji)
input group "=== OPĆE ==="
input ulong    MagicNumber      = 100005;
input int      Slippage         = 30;
struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo { bool active; ulong ticket; double intendedSL; double stealthTP; double entryPrice; datetime openTime; int delaySeconds; int randomBEPips; int randomLock2Pips; int trailLevel; };
CTrade trade;
int atrHandle;
datetime lastBarTime;
PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0); g_posCount = 0;
    Print("=== CALF E v3.0 | Hard SL=", HardSL_Pips, " | 3-Level Trailing | Range Filter ===");
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle); }
int RandomRange(int minVal, int maxVal) { if(minVal >= maxVal) return minVal; return minVal + (MathRand() % (maxVal - minVal + 1)); }
// AŽURIRANO: Radno vrijeme bez ikakvih unutar-dnevnih pauza!
bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1)); // Nedjelja od 00:01
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true; // Pon-Čet cijeli dan
    if(dt.day_of_week == 5) return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30)); // Petak do 11:30
    return false;
}
bool IsLargeCandle()
{
    if(!UseStealthMode) return false;
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    return ((iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) > LargeCandleATR * atr[0]);
}
bool IsNewBar() { datetime t = iTime(_Symbol, PERIOD_CURRENT, 0); if(t != lastBarTime) { lastBarTime = t; return true; } return false; }
double GetATR() { double buf[]; ArraySetAsSeries(buf, true); if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0; return buf[0]; }
bool IsVolumeAboveAverage() { if(!UseVolumeFilter) return true; long vol[]; ArraySetAsSeries(vol, true); if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, VolumePeriod + 1, vol) <= 0) return true; double sum = 0; for(int i = 1; i <= VolumePeriod; i++) sum += (double)vol[i]; double avg = sum / (double)VolumePeriod; return ((double)vol[1] > avg * 1.2); }

// Range Compression Filter - breakout nakon uskog rangea ima veći momentum
bool IsRangeCompressed() {
   if(!UseRangeFilter) return true;
   double atr14 = GetATR();
   if(atr14 <= 0) return true;

   // Izračunaj prosječni range zadnjih RangeATRPeriod svijeća
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, RangeATRPeriod, high) <= 0) return true;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, RangeATRPeriod, low) <= 0) return true;

   double sumRange = 0;
   for(int i = 0; i < RangeATRPeriod; i++)
      sumRange += (high[i] - low[i]);
   double avgRange = sumRange / RangeATRPeriod;

   // Ako je prosječni range manji od RangeCompressMin * ATR14 → kompresija
   double ratio = avgRange / atr14;
   if(ratio < RangeCompressMin) {
      Print("CALF_E: Range compressed, ratio=", DoubleToString(ratio, 2), " - GOOD setup");
      return true;
   }
   return false; // Nije dovoljno kompresiran
}
double CalculateLotSize(double slDist) { if(slDist <= 0) return 0; double balance = AccountInfoDouble(ACCOUNT_BALANCE); double riskAmt = balance * RiskPercent / 100.0; double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); double lots = riskAmt / ((slDist / point) * tickVal / tickSize); lots = MathFloor(lots / lotStep) * lotStep; return MathMax(minLot, MathMin(maxLot, lots)); }
bool HasOpenPosition() { for(int i = PositionsTotal() - 1; i >= 0; i--) { ulong ticket = PositionGetTicket(i); if(PositionSelectByTicket(ticket)) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true; } return false; }
void QueueTrade(ENUM_ORDER_TYPE type) {
   double atr = GetATR();
   if(atr <= 0) return;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // v3.3: SL se računa random 789-811 pips u ExecuteTrade()
   double slDist = HardSL_Pips * point;  // ISPRAVNO: bez * 10
   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
   double lots = CalculateLotSize(slDist);
   if(lots <= 0) return;
   if(UseStealthMode) {
      g_pendingTrade.active = true;
      g_pendingTrade.type = type;
      g_pendingTrade.lot = lots;
      g_pendingTrade.intendedSL = sl;
      g_pendingTrade.intendedTP = tp;
      g_pendingTrade.signalTime = TimeCurrent();
      g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
      Print("CALF_E: Trade queued, SL=", HardSL_Pips, " pips");
   } else {
      ExecuteTrade(type, lots, sl, tp);
   }
}
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp) {
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // v3.3 FIX: Random SL 789-811 pips (1 pip = 0.01 za XAUUSD)
   int randomSLPips = RandomRange(789, 811);
   double slDistance = randomSLPips * point;  // ISPRAVNO: bez * 10
   sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   bool ok;
   // v3.2: Otvori BEZ SL-a, pa ODMAH postavi s PositionModify
   if(UseStealthMode)
      ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_E") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_E");
   else
      ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_E BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_E SELL");
   if(ok && UseStealthMode) {
      ulong ticket = trade.ResultOrder();
      if(trade.PositionModify(ticket, sl, 0))
         Print("CALF_E: Opened #", ticket, " + SL ODMAH @ ", sl, " (", randomSLPips, " pips)");
      else
         Print("CALF_E WARNING: SL FAILED #", ticket, " - will retry!");
      ArrayResize(g_positions, g_posCount + 1);
      g_positions[g_posCount].active = true;
      g_positions[g_posCount].ticket = ticket;
      g_positions[g_posCount].intendedSL = sl;
      g_positions[g_posCount].stealthTP = tp;
      g_positions[g_posCount].entryPrice = price;
      g_positions[g_posCount].openTime = TimeCurrent();
      g_positions[g_posCount].delaySeconds = 0;
      g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
      g_positions[g_posCount].randomLock2Pips = RandomRange(TrailLock2_PipsMin, TrailLock2_PipsMax);
      g_positions[g_posCount].trailLevel = 0;
      g_posCount++;
   } else if(ok) Print("CALF_E: ", lot);
}
void ProcessPendingTrade() { if(!g_pendingTrade.active) return; if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds) { ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP); g_pendingTrade.active = false; } }
void ManageStealthPositions() {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i = g_posCount - 1; i >= 0; i--) {
      if(!g_positions[i].active) continue;
      ulong ticket = g_positions[i].ticket;
      if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; }
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - g_positions[i].entryPrice) / point : (g_positions[i].entryPrice - currentPrice) / point;

      // v3.1: SL backup (pravi SL je postavljen odmah)
      if(currentSL == 0 && g_positions[i].intendedSL != 0) {
         if(trade.PositionModify(ticket, NormalizeDouble(g_positions[i].intendedSL, digits), 0))
            Print("CALF_E BACKUP: SL set #", ticket);
      }

      // Stealth TP check
      if(g_positions[i].stealthTP > 0) {
         bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                      (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
         if(tpHit) { trade.PositionClose(ticket); g_positions[i].active = false; continue; }
      }

      // 3-LEVEL TRAILING SYSTEM
      if(currentSL > 0) {
         double newSL = 0;
         int newLevel = g_positions[i].trailLevel;

         // Level 3: +1200 pips → trailing 250 pips
         if(g_positions[i].trailLevel >= 2 && profitPips >= TrailLevel3_Pips) {
            double trailSL = (posType == POSITION_TYPE_BUY)
               ? currentPrice - TrailDistance3 * point
               : currentPrice + TrailDistance3 * point;
            trailSL = NormalizeDouble(trailSL, digits);
            bool better = (posType == POSITION_TYPE_BUY && trailSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && trailSL < currentSL);
            if(better) { newSL = trailSL; newLevel = 3; }
         }
         // Level 2: +800 pips → lock 150-200 pips
         else if(g_positions[i].trailLevel == 1 && profitPips >= TrailLevel2_Pips) {
            newSL = (posType == POSITION_TYPE_BUY)
               ? g_positions[i].entryPrice + g_positions[i].randomLock2Pips * point
               : g_positions[i].entryPrice - g_positions[i].randomLock2Pips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool better = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(better) newLevel = 2; else newSL = 0;
         }
         // Level 1: +500 pips → BE + 38-43 pips
         else if(g_positions[i].trailLevel == 0 && profitPips >= TrailLevel1_Pips) {
            newSL = (posType == POSITION_TYPE_BUY)
               ? g_positions[i].entryPrice + g_positions[i].randomBEPips * point
               : g_positions[i].entryPrice - g_positions[i].randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool better = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(better) newLevel = 1; else newSL = 0;
         }

         // Primijeni trailing
         if(newSL > 0 && newLevel > g_positions[i].trailLevel) {
            if(trade.PositionModify(ticket, newSL, 0)) {
               Print("CALF_E TRAIL L", newLevel, ": #", ticket, " SL=", newSL, " profit=", (int)profitPips, " pips");
               g_positions[i].trailLevel = newLevel;
            }
         }
         // Level 3 continuous trailing
         else if(newSL > 0 && g_positions[i].trailLevel >= 3) {
            if(trade.PositionModify(ticket, newSL, 0))
               Print("CALF_E TRAIL L3: #", ticket, " SL=", newSL);
         }
      }
   }
   CleanupPositions();
}
void CleanupPositions() { int newCount = 0; for(int i = 0; i < g_posCount; i++) { if(g_positions[i].active) { if(i != newCount) g_positions[newCount] = g_positions[i]; newCount++; } } if(newCount != g_posCount) { g_posCount = newCount; ArrayResize(g_positions, g_posCount); } }
void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPositions();
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(IsLargeCandle()) return;
    if(g_pendingTrade.active) return;
    double high[], low[], close[];
    ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, close) <= 0) return;
    double highestHigh = high[2]; double lowestLow = low[2];
    for(int i = 2; i < LookbackBars + 2; i++) { if(high[i] > highestHigh) highestHigh = high[i]; if(low[i] < lowestLow) lowestLow = low[i]; }
    double atr = GetATR();
    double buffer = BreakoutBuffer * atr;
    bool buySignal = (close[1] > highestHigh + buffer) && (close[2] <= highestHigh);
    bool sellSignal = (close[1] < lowestLow - buffer) && (close[2] >= lowestLow);
    if(!IsVolumeAboveAverage()) { buySignal = false; sellSignal = false; }
    if(!IsRangeCompressed()) { buySignal = false; sellSignal = false; }
    if(buySignal) { Print("CALF_E BUY SIGNAL (SL=", HardSL_Pips, " pips)"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal) { Print("CALF_E SELL SIGNAL (SL=", HardSL_Pips, " pips)"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
