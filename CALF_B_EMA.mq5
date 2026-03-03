//+------------------------------------------------------------------+
//|                                                CALF_B_EMA.mq5    |
//|                        *** CALF B - EMA Crossover ***            |
//|                   + Stealth Mode v2.32 (RANDOM SL)               |
//|                   Created: 23.02.2026 (Zagreb)                   |
//|                   Fixed: 03.03.2026 14:30 (Zagreb) - MAE/MFE opt |
//|                   Fixed: 03.03.2026 22:30 (Zagreb) - REAL SL     |
//|                   Fixed: 03.03.2026 23:xx (Zagreb) - SL na trenutnoj cijeni |
//|                   - Hard SL 800 pips ODMAH pri otvaranju         |
//|                   - Stealth samo za TP                           |
//|                   - Pametni Trailing (1000/500 dynamic lock)     |
//+------------------------------------------------------------------+
#property copyright "CALF B - EMA 9/21 + Stealth v2.32 RANDOM SL (2026-03-03)"
#property version   "2.32"
#property strict
#include <Trade\Trade.mqh>
input group "=== EMA POSTAVKE ==="
input int      FastEMA          = 9;
input int      SlowEMA          = 21;
input group "=== HULL FILTER ==="
input bool     UseHullFilter    = true;
input int      HullPeriod       = 20;
input group "=== TRADE MANAGEMENT ==="
input int      HardSLPips       = 800;    // Hard SL (MAE analiza: -8 USD granica)
input double   TPMultiplier     = 3.0;    // TP multiplier (ATR based)
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== EXHAUSTION FILTER ==="
input bool     UseExhaustionFilter = true;   // Koristi Exhaustion Filter
input int      ExhaustionCandles   = 3;      // Broj svijeća za provjeru
input double   ExhaustionATRMult   = 1.8;    // ATR multiplier za exhaustion
input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
// SLDelayMin/Max uklonjeni - SL se postavlja ODMAH (v2.31)
input double   LargeCandleATR   = 3.0;   // Filter dugih svijeća
input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips = 1000; // Aktivacija na 1000 pipsa (MFE analiza)
input int      TrailDistancePips = 500;  // Dynamic lock distance (MFE - 500 pips)
input int      TrailBEPipsMin   = 38;    // BE + 38 (legacy, za level 1 ako treba)
input int      TrailBEPipsMax   = 43;    // BE + 43 (legacy, za level 1 ako treba)
input group "=== OPĆE ==="
input ulong    MagicNumber      = 100002;
input int      Slippage         = 30;
struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo { bool active; ulong ticket; double intendedSL; double stealthTP; double entryPrice; datetime openTime; int delaySeconds; int randomBEPips; int trailLevel; double maxFavorable; };
CTrade trade;
int fastEmaHandle, slowEmaHandle, atrHandle;
datetime lastBarTime;
PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    fastEmaHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
    slowEmaHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(fastEmaHandle == INVALID_HANDLE || slowEmaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE) return INIT_FAILED;
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0); g_posCount = 0;
    Print("=== CALF B v2.2 STEALTH MODE (Forenzicka Optimizacija) ===");
    Print("Hard SL: ", HardSLPips, " pips | Exhaustion: ", (UseExhaustionFilter ? "ON" : "OFF"),
          " | Trail: ", TrailActivatePips, "/", TrailDistancePips, " pips");
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
    if(fastEmaHandle != INVALID_HANDLE) IndicatorRelease(fastEmaHandle);
    if(slowEmaHandle != INVALID_HANDLE) IndicatorRelease(slowEmaHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}
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
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low = iLow(_Symbol, PERIOD_CURRENT, 1);
    return ((high - low) > LargeCandleATR * atr[0]);
}
// NOVO v2.2: Exhaustion Filter - sprječava kasne entryje nakon potrošenog impulsa
// Ako su zadnje N svijeća u istom smjeru i ukupni range > ATRMult × ATR → skip
bool IsExhausted(bool isBuy)
{
    if(!UseExhaustionFilter) return false;
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    if(atr[0] <= 0) return false;

    int sameDirection = 0;
    double totalRange = 0;

    for(int i = 1; i <= ExhaustionCandles; i++)
    {
        double open = iOpen(_Symbol, PERIOD_CURRENT, i);
        double close = iClose(_Symbol, PERIOD_CURRENT, i);
        double high = iHigh(_Symbol, PERIOD_CURRENT, i);
        double low = iLow(_Symbol, PERIOD_CURRENT, i);

        bool isBullish = (close > open);
        bool isBearish = (close < open);

        if(isBuy && isBullish) sameDirection++;
        else if(!isBuy && isBearish) sameDirection++;

        totalRange += (high - low);
    }

    // Sve svijeće u istom smjeru I ukupni range > threshold
    if(sameDirection == ExhaustionCandles && totalRange > ExhaustionATRMult * atr[0])
    {
        Print("CALF_B: EXHAUSTION DETECTED - ", ExhaustionCandles, " candles same dir, range=",
              NormalizeDouble(totalRange/_Point/10, 1), " pips > ",
              NormalizeDouble(ExhaustionATRMult * atr[0]/_Point/10, 1), " pips threshold");
        return true;
    }
    return false;
}
bool IsNewBar() { datetime t = iTime(_Symbol, PERIOD_CURRENT, 0); if(t != lastBarTime) { lastBarTime = t; return true; } return false; }
int GetHullDirection()
{
    if(!UseHullFilter) return 0;
    double close[]; ArraySetAsSeries(close, true);
    CopyClose(_Symbol, PERIOD_CURRENT, 0, HullPeriod * 2 + 5, close);
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0, wmaFull = 0, sumH = 0, sumF = 0;
    for(int i = 0; i < halfPeriod; i++) { double w = (double)(halfPeriod - i); wmaHalf += close[i+1] * w; sumH += w; }
    if(sumH > 0) wmaHalf /= sumH;
    for(int i = 0; i < HullPeriod; i++) { double w = (double)(HullPeriod - i); wmaFull += close[i+1] * w; sumF += w; }
    if(sumF > 0) wmaFull /= sumF;
    double hullNow = 2.0 * wmaHalf - wmaFull;
    wmaHalf = 0; wmaFull = 0; sumH = 0; sumF = 0;
    for(int i = 0; i < halfPeriod; i++) { double w = (double)(halfPeriod - i); wmaHalf += close[i+3] * w; sumH += w; }
    if(sumH > 0) wmaHalf /= sumH;
    for(int i = 0; i < HullPeriod; i++) { double w = (double)(HullPeriod - i); wmaFull += close[i+3] * w; sumF += w; }
    if(sumF > 0) wmaFull /= sumF;
    double hullPrev = 2.0 * wmaHalf - wmaFull;
    if(hullNow > hullPrev) return 1;
    if(hullNow < hullPrev) return -1;
    return 0;
}
double GetATR() { double buf[]; ArraySetAsSeries(buf, true); if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0; return buf[0]; }
double CalculateLotSize(double slDist)
{
    if(slDist <= 0) return 0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt = balance * RiskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots = riskAmt / ((slDist / point) * tickVal / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}
bool HasOpenPosition() { for(int i = PositionsTotal() - 1; i >= 0; i--) { ulong ticket = PositionGetTicket(i); if(PositionSelectByTicket(ticket)) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true; } return false; }
void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(); if(atr <= 0) return;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // v2.2: Hard SL od 800 pips (MAE analiza pokazuje -8 USD kao granicu smrti tradea)
    double slDistance = HardSLPips * point * 10; // pips to price (1 pip = 10 points za XAUUSD)
    double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
    double lots = CalculateLotSize(slDistance); if(lots <= 0) return;
    if(UseStealthMode) { g_pendingTrade.active = true; g_pendingTrade.type = type; g_pendingTrade.lot = lots; g_pendingTrade.intendedSL = sl; g_pendingTrade.intendedTP = tp; g_pendingTrade.signalTime = TimeCurrent(); g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax); Print("CALF_B: Trade queued, delay ", g_pendingTrade.delaySeconds, "s"); }
    else { ExecuteTrade(type, lots, sl, tp); }
}
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // v2.32 FIX: Random SL 789-811 pips (stealth) na TRENUTNOJ cijeni
    int randomSLPips = RandomRange(789, 811);
    double slDistance = randomSLPips * point * 10;
    sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits);
    bool ok;
    // v2.31: Otvori trade BEZ SL-a, pa ODMAH postavi SL s PositionModify (stealth)
    if(UseStealthMode) ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_B") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_B");
    else ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_B BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_B SELL");
    if(ok && UseStealthMode) {
        ulong ticket = trade.ResultOrder();
        // ODMAH postavi SL (ne čekaj)
        if(trade.PositionModify(ticket, sl, 0))
            Print("CALF_B: Opened #", ticket, " + SL set ODMAH @ ", sl);
        else
            Print("CALF_B WARNING: SL FAILED for #", ticket, " - will retry!");
        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = sl;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].delaySeconds = 0;
        g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
        g_positions[g_posCount].trailLevel = 0;
        g_positions[g_posCount].maxFavorable = 0;
        g_posCount++;
    }
    else if(ok) Print("CALF_B ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), ": ", lot, " @ ", price);
}
void ProcessPendingTrade() { if(!g_pendingTrade.active) return; if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds) { ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP); g_pendingTrade.active = false; } }
// v2.2: Pametni Trailing - MFE based dynamic lock
void ManageStealthPositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;
        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Izračunaj trenutni profit u pipsima (points / 10 za XAUUSD)
        double profitPips = (posType == POSITION_TYPE_BUY)
            ? (currentPrice - g_positions[i].entryPrice) / point / 10
            : (g_positions[i].entryPrice - currentPrice) / point / 10;

        // v2.2: Ažuriraj MFE (Maximum Favorable Excursion)
        if(profitPips > g_positions[i].maxFavorable)
            g_positions[i].maxFavorable = profitPips;

        // v2.31: BACKUP - retry SL ako prvi pokušaj nije uspio
        if(currentSL == 0 && g_positions[i].intendedSL != 0)
        {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
                Print("CALF_B BACKUP: SL RETRY uspješan #", ticket, " @ ", sl);
        }

        // 2. Stealth TP provjera
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP)
                      || (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("CALF_B STEALTH: TP hit #", ticket, " MFE was ", NormalizeDouble(g_positions[i].maxFavorable, 1), " pips");
                g_positions[i].active = false;
                continue;
            }
        }

        // 3. v2.2: Pametni Trailing (MFE based dynamic lock)
        // Aktivacija tek kad trade pokaže pravi momentum (1000 pips = ~10 USD)
        // Lock = MFE - 500 pips (dinamički prati)
        if(currentSL > 0 && profitPips >= TrailActivatePips)
        {
            // Izračunaj novi SL baziran na MFE
            double lockPips = g_positions[i].maxFavorable - TrailDistancePips;
            if(lockPips < 0) lockPips = 0; // Minimalno BE

            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = g_positions[i].entryPrice + lockPips * point * 10;
            else
                newSL = g_positions[i].entryPrice - lockPips * point * 10;

            newSL = NormalizeDouble(newSL, digits);

            // SL se NIKAD ne vraća nazad
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL)
                             || (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                Print("CALF_B TRAIL: #", ticket, " MFE=", NormalizeDouble(g_positions[i].maxFavorable, 1),
                      " Lock=", NormalizeDouble(lockPips, 1), " pips, SL=", newSL);
                if(g_positions[i].trailLevel == 0) g_positions[i].trailLevel = 1;
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
    double fast[], slow[];
    ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
    if(CopyBuffer(fastEmaHandle, 0, 0, 3, fast) <= 0) return;
    if(CopyBuffer(slowEmaHandle, 0, 0, 3, slow) <= 0) return;
    bool crossUp = (fast[1] > slow[1]) && (fast[2] <= slow[2]);
    bool crossDown = (fast[1] < slow[1]) && (fast[2] >= slow[2]);
    int hull = GetHullDirection();
    bool buySignal = crossUp && (!UseHullFilter || hull >= 0);
    bool sellSignal = crossDown && (!UseHullFilter || hull <= 0);
    // v2.2: Exhaustion Filter - skip kasne entryje nakon potrošenog impulsa
    if(buySignal && !IsExhausted(true)) { Print("CALF_B BUY SIGNAL"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal && !IsExhausted(false)) { Print("CALF_B SELL SIGNAL"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
