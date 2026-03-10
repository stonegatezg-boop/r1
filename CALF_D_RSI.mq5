//+------------------------------------------------------------------+
//|                                                CALF_D_RSI.mq5    |
//|                        *** CALF D - RSI Reversal ***             |
//|                   + Stealth Mode v2.5 (Full Standard)            |
//|                   Created: 23.02.2026 (Zagreb)                   |
//|                   Fixed: 03.03.2026 22:30 (Zagreb) - REAL SL     |
//|                   Fixed: 04.03.2026 (Zagreb) - PIP FIX *10       |
//|                   Fixed: 10.03.2026 (Zagreb) - Full Standard     |
//|                   - SL 988-1054 pips (random) ODMAH              |
//|                   - 3 Target System (33%, 50%, rest)             |
//|                   - Trailing: BE+ 1000 pips, kontinuirani 1000   |
//+------------------------------------------------------------------+
#property copyright "CALF D - RSI + Stealth v2.5 Full Standard"
#property version   "2.50"
#property strict
#include <Trade\Trade.mqh>
input group "=== RSI POSTAVKE ==="
input int      RSIPeriod        = 14;
input int      OversoldLevel    = 30;
input int      OverboughtLevel  = 70;
input group "=== HULL FILTER ==="
input bool     UseHullFilter    = true;
input int      HullPeriod       = 20;
input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 2.5;
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;
input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
// SLDelayMin/Max uklonjeni - SL se postavlja ODMAH (v2.3)
input double   LargeCandleATR   = 3.0;    // Filter dugih svijeća
input group "=== 3 TARGET SYSTEM ==="
input int      Target1_Pips     = 300;    // Target 1: zatvori 33%
input int      Target2_Pips     = 500;    // Target 2: zatvori 50% preostalog
input int      Target3_Pips     = 800;    // Target 3: trailing ostatak
input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips = 1000;  // BE+ aktivacija (1000 pips)
input int      TrailBEPipsMin   = 41;     // BE+ offset min
input int      TrailBEPipsMax   = 46;     // BE+ offset max
input int      TrailDistancePips = 1000;  // Trailing udaljenost nakon BE+
input group "=== OPĆE ==="
input ulong    MagicNumber      = 100004;
input int      Slippage         = 30;
struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo {
    bool active;
    ulong ticket;
    double intendedSL;
    double stealthTP;
    double entryPrice;
    double originalLot;      // Početni lot za 3 target
    datetime openTime;
    int delaySeconds;
    int randomBEPips;
    int trailLevel;          // 0=none, 1=BE+, 2+=trailing
    double maxFavorable;     // MFE tracking u pipsima
    int targetLevel;         // 0=none, 1=T1 done, 2=T2 done
};
CTrade trade;
int rsiHandle, atrHandle;
datetime lastBarTime;
PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE) return INIT_FAILED;
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0); g_posCount = 0;
    Print("=== CALF D v2.5 Full Standard (3 Target + Trail 1000) ===");
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle); if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle); }
int RandomRange(int minVal, int maxVal) { if(minVal >= maxVal) return minVal; return minVal + (MathRand() % (maxVal - minVal + 1)); }
// AŽURIRANO: Radno vrijeme bez ikakvih unutar-dnevnih pauza!
bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1)); // Nedjelja od 00:01
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true; // Pon-Čet cijeli dan
    if(dt.day_of_week == 5) return (dt.hour < 11); // Petak do 11:00
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
double CalculateLotSize(double slDist) { if(slDist <= 0) return 0; double balance = AccountInfoDouble(ACCOUNT_BALANCE); double riskAmt = balance * RiskPercent / 100.0; double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); double lots = riskAmt / ((slDist / point) * tickVal / tickSize); lots = MathFloor(lots / lotStep) * lotStep; return MathMax(minLot, MathMin(maxLot, lots)); }
bool HasOpenPosition() { for(int i = PositionsTotal() - 1; i >= 0; i--) { ulong ticket = PositionGetTicket(i); if(PositionSelectByTicket(ticket)) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true; } return false; }
void QueueTrade(ENUM_ORDER_TYPE type) { double atr = GetATR(); if(atr <= 0) return; double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID); double sl = (type == ORDER_TYPE_BUY) ? price - SLMultiplier * atr : price + SLMultiplier * atr; double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr; double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return; if(UseStealthMode) { g_pendingTrade.active = true; g_pendingTrade.type = type; g_pendingTrade.lot = lots; g_pendingTrade.intendedSL = sl; g_pendingTrade.intendedTP = tp; g_pendingTrade.signalTime = TimeCurrent(); g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax); Print("CALF_D: Trade queued"); } else { ExecuteTrade(type, lots, sl, tp); } }
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp) {
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // v2.5 FIX: Random SL 988-1054 pips (1 pip = 0.01 za XAUUSD)
    int randomSLPips = RandomRange(988, 1054);
    double slDistance = randomSLPips * point;  // ISPRAVNO: bez * 10
    sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits);
    bool ok;
    // v2.3: Otvori BEZ SL-a, pa ODMAH postavi s PositionModify
    if(UseStealthMode) ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_D") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_D");
    else ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_D BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_D SELL");
    if(ok && UseStealthMode) {
        ulong ticket = trade.ResultOrder();
        if(trade.PositionModify(ticket, sl, 0))
            Print("CALF_D: Opened #", ticket, " + SL ODMAH @ ", sl, " (", randomSLPips, " pips)");
        else
            Print("CALF_D WARNING: SL FAILED #", ticket, " - will retry!");
        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = sl;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].originalLot = lot;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].delaySeconds = 0;
        g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
        g_positions[g_posCount].trailLevel = 0;
        g_positions[g_posCount].maxFavorable = 0;
        g_positions[g_posCount].targetLevel = 0;
        g_posCount++;
    } else if(ok) Print("CALF_D: ", lot);
}
void ProcessPendingTrade() { if(!g_pendingTrade.active) return; if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds) { ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP); g_pendingTrade.active = false; } }
// v2.5: Full Standard - 3 Target + MFE Trailing
void ManageStealthPositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;
        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentLot = PositionGetDouble(POSITION_VOLUME);
        double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Profit u pipsima
        double profitPips = (posType == POSITION_TYPE_BUY)
            ? (currentPrice - g_positions[i].entryPrice) / point
            : (g_positions[i].entryPrice - currentPrice) / point;

        // MFE tracking
        if(profitPips > g_positions[i].maxFavorable)
            g_positions[i].maxFavorable = profitPips;

        // 1. SL backup
        if(currentSL == 0 && g_positions[i].intendedSL != 0)
        {
            if(trade.PositionModify(ticket, NormalizeDouble(g_positions[i].intendedSL, digits), 0))
                Print("CALF_D BACKUP: SL set #", ticket);
        }

        // 2. Stealth TP provjera
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP)
                      || (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("CALF_D STEALTH: TP hit #", ticket, " MFE=", NormalizeDouble(g_positions[i].maxFavorable, 1), " pips");
                g_positions[i].active = false;
                continue;
            }
        }

        // 3. 3 TARGET SYSTEM
        // Target 1: 300 pips = zatvori 33%
        if(g_positions[i].targetLevel == 0 && profitPips >= Target1_Pips)
        {
            double closeL = g_positions[i].originalLot * 0.33;
            closeL = MathFloor(closeL / lotStep) * lotStep;
            if(closeL >= minLot && closeL < currentLot)
            {
                if(trade.PositionClosePartial(ticket, closeL))
                {
                    g_positions[i].targetLevel = 1;
                    Print("CALF_D T1: Closed 33% (", closeL, " lots) @ ", profitPips, " pips");
                }
            }
            else g_positions[i].targetLevel = 1;
        }

        // Target 2: 500 pips = zatvori 50% preostalog
        if(g_positions[i].targetLevel == 1 && profitPips >= Target2_Pips)
        {
            if(PositionSelectByTicket(ticket))
            {
                currentLot = PositionGetDouble(POSITION_VOLUME);
                double closeL = currentLot * 0.50;
                closeL = MathFloor(closeL / lotStep) * lotStep;
                if(closeL >= minLot && closeL < currentLot)
                {
                    if(trade.PositionClosePartial(ticket, closeL))
                    {
                        g_positions[i].targetLevel = 2;
                        Print("CALF_D T2: Closed 50% (", closeL, " lots) @ ", profitPips, " pips");
                    }
                }
                else g_positions[i].targetLevel = 2;
            }
        }

        // 4. BE+ @ 1000 pips
        if(g_positions[i].trailLevel == 0 && currentSL > 0 && profitPips >= TrailActivatePips)
        {
            double newSL = (posType == POSITION_TYPE_BUY)
                ? g_positions[i].entryPrice + g_positions[i].randomBEPips * point
                : g_positions[i].entryPrice - g_positions[i].randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL)
                             || (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_positions[i].trailLevel = 1;
                Print("CALF_D BE+: #", ticket, " SL=", newSL, " (+", g_positions[i].randomBEPips, " pips)");
            }
        }

        // 5. Kontinuirani trailing nakon BE+ (prati MFE - 1000 pips)
        if(g_positions[i].trailLevel >= 1 && currentSL > 0)
        {
            double trailPips = g_positions[i].maxFavorable - TrailDistancePips;
            if(trailPips > g_positions[i].randomBEPips)
            {
                double newSL = (posType == POSITION_TYPE_BUY)
                    ? g_positions[i].entryPrice + trailPips * point
                    : g_positions[i].entryPrice - trailPips * point;
                newSL = NormalizeDouble(newSL, digits);
                bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL)
                                 || (posType == POSITION_TYPE_SELL && newSL < currentSL);
                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 2;
                    Print("CALF_D TRAIL: #", ticket, " MFE=", NormalizeDouble(g_positions[i].maxFavorable, 0),
                          " Lock=", NormalizeDouble(trailPips, 0), " pips");
                }
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
    double rsi[];
    ArraySetAsSeries(rsi, true);
    if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) <= 0) return;
    bool wasOversold = rsi[2] < OversoldLevel;
    bool nowAboveOversold = rsi[1] >= OversoldLevel;
    bool wasOverbought = rsi[2] > OverboughtLevel;
    bool nowBelowOverbought = rsi[1] <= OverboughtLevel;
    bool buySignal = wasOversold && nowAboveOversold;
    bool sellSignal = wasOverbought && nowBelowOverbought;
    int hull = GetHullDirection();
    if(UseHullFilter) { if(buySignal && hull < 0) buySignal = false; if(sellSignal && hull > 0) sellSignal = false; }
    if(buySignal) { Print("CALF_D BUY SIGNAL"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal) { Print("CALF_D SELL SIGNAL"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
