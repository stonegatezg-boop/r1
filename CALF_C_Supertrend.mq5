//+------------------------------------------------------------------+
//|                                           CALF_C_Supertrend.mq5  |
//|                        *** CALF C - Supertrend ***                |
//|                   + Stealth Mode v3.5 (Full Standard)            |
//|                   Created: 23.02.2026 (Zagreb)                   |
//|                   Fixed: 03.03.2026 14:30 (Zagreb)               |
//|                   Fixed: 03.03.2026 22:30 (Zagreb) - REAL SL     |
//|                   Fixed: 04.03.2026 (Zagreb) - PIP FIX *10       |
//|                   Fixed: 10.03.2026 (Zagreb) - Full Standard     |
//|                   - SL 988-1054 pips (random) ODMAH              |
//|                   - Trailing: BE+ 1000 pips, kontinuirani 1000   |
//|                   - 3 Target System (33%, 50%, rest)             |
//|                   - Stealth samo za TP                           |
//+------------------------------------------------------------------+
#property copyright "CALF C - Supertrend v3.5 Full Standard"
#property version   "3.50"
#property strict
#include <Trade\Trade.mqh>
input group "=== SUPERTREND POSTAVKE ==="
input int      STperiod         = 10;
input double   STmultiplier     = 2.0;
input group "=== TRADE MANAGEMENT ==="
input int      FixedSL_Pips     = 800;       // SL u pipsima (800 pips = 80 USD za 0.01 lot)
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== ATR RANGE FILTER ==="
input bool     UseATRFilter     = true;      // Koristi ATR filter za range
input int      ATRFilterPeriod  = 6;         // Period za ATR comparison (zadnjih N barova)
input double   MinATRMultiple   = 0.7;       // Min ATR vs prosjek (ispod = range, skip)
input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
// SLDelayMin/Max uklonjeni - SL se postavlja ODMAH (v3.2)
input double   LargeCandleATR   = 3.0;    // Filter dugih svijeća
input group "=== 3 TARGET SYSTEM ==="
input int      Target1_Pips     = 300;       // Target 1: zatvori 33%
input int      Target2_Pips     = 500;       // Target 2: zatvori 50% preostalog
input int      Target3_Pips     = 800;       // Target 3: trailing ostatak
input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips = 1000;     // BE+ aktivacija (1000 pips)
input int      TrailBEPipsMin   = 41;        // BE+ offset min
input int      TrailBEPipsMax   = 46;        // BE+ offset max
input int      TrailDistancePips = 1000;     // Trailing udaljenost nakon BE+
input group "=== OPĆE ==="
input ulong    MagicNumber      = 100003;
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
int atrHandle;
double supertrend[];
int stDirection[];
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
    ArraySetAsSeries(supertrend, true); ArraySetAsSeries(stDirection, true);
    ArrayResize(supertrend, 5); ArrayResize(stDirection, 5);
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0); g_posCount = 0;
    Print("=== CALF C v3.5 Full Standard (3 Target + Trail 1000) ===");
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

// ATR Range Filter - preskoči trade ako je ATR nizak (range market)
bool IsRangeMarket()
{
    if(!UseATRFilter) return false;

    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 0, ATRFilterPeriod + 10, atr) <= 0) return false;

    // Trenutni ATR
    double currentATR = atr[1];

    // Prosjek ATR zadnjih N barova
    double sumATR = 0;
    for(int i = 1; i <= ATRFilterPeriod; i++)
        sumATR += atr[i];
    double avgATR = sumATR / ATRFilterPeriod;

    // Ako je trenutni ATR ispod MinATRMultiple * prosjek = range
    if(currentATR < MinATRMultiple * avgATR)
    {
        Print("CALF_C: ATR FILTER - Range detected. ATR=", DoubleToString(currentATR, 2),
              " < ", DoubleToString(MinATRMultiple * avgATR, 2), " (", DoubleToString(MinATRMultiple * 100, 0), "% avg)");
        return true;
    }
    return false;
}
bool IsNewBar() { datetime t = iTime(_Symbol, PERIOD_CURRENT, 0); if(t != lastBarTime) { lastBarTime = t; return true; } return false; }
void CalculateSupertrend()
{
    double high[], low[], close[];
    ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
    int bars = STperiod + 10;
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
    double sumTR = 0;
    for(int i = 1; i <= STperiod; i++) { double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1]))); sumTR += tr; }
    double atr = sumTR / STperiod;
    for(int s = 4; s >= 0; s--)
    {
        double hl2 = (high[s] + low[s]) / 2.0;
        double upperBand = hl2 + STmultiplier * atr;
        double lowerBand = hl2 - STmultiplier * atr;
        double prevST = (s < 4) ? supertrend[s+1] : hl2;
        int prevDir = (s < 4) ? stDirection[s+1] : 1;
        if(prevDir == 1) { if(close[s] < prevST) { supertrend[s] = upperBand; stDirection[s] = -1; } else { supertrend[s] = MathMax(lowerBand, prevST); stDirection[s] = 1; } }
        else { if(close[s] > prevST) { supertrend[s] = lowerBand; stDirection[s] = 1; } else { supertrend[s] = MathMin(upperBand, prevST); stDirection[s] = -1; } }
    }
}
double GetATR() { double buf[]; ArraySetAsSeries(buf, true); if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0; return buf[0]; }
double CalculateLotSize(double slDist) { if(slDist <= 0) return 0; double balance = AccountInfoDouble(ACCOUNT_BALANCE); double riskAmt = balance * RiskPercent / 100.0; double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); double lots = riskAmt / ((slDist / point) * tickVal / tickSize); lots = MathFloor(lots / lotStep) * lotStep; return MathMax(minLot, MathMin(maxLot, lots)); }
bool HasOpenPosition() { for(int i = PositionsTotal() - 1; i >= 0; i--) { ulong ticket = PositionGetTicket(i); if(PositionSelectByTicket(ticket)) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true; } return false; }
void QueueTrade(ENUM_ORDER_TYPE type)
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Fiksni SL u pipsima (1 pip XAUUSD = 0.01 = point)
    double slDistance = FixedSL_Pips * point;  // ISPRAVNO: bez * 10
    double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;

    // TP = 0 jer koristimo MFE trailing (stealth)
    double tp = 0;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    if(UseStealthMode)
    {
        g_pendingTrade.active = true;
        g_pendingTrade.type = type;
        g_pendingTrade.lot = lots;
        g_pendingTrade.intendedSL = sl;
        g_pendingTrade.intendedTP = tp;
        g_pendingTrade.signalTime = TimeCurrent();
        g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
        Print("CALF_C: Trade queued. SL=", FixedSL_Pips, " pips");
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp);
    }
}
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp) {
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // v3.4 FIX: Random SL 988-1054 pips (1 pip = 0.01 za XAUUSD)
    int randomSLPips = RandomRange(988, 1054);
    double slDistance = randomSLPips * point;  // ISPRAVNO: bez * 10
    sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits);
    bool ok;
    // v3.2: Otvori BEZ SL-a, pa ODMAH postavi s PositionModify
    if(UseStealthMode) ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_C") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_C");
    else ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_C BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_C SELL");
    if(ok && UseStealthMode) {
        ulong ticket = trade.ResultOrder();
        if(trade.PositionModify(ticket, sl, 0))
            Print("CALF_C: Opened #", ticket, " + SL ODMAH @ ", sl, " (", randomSLPips, " pips)");
        else
            Print("CALF_C WARNING: SL FAILED #", ticket, " - will retry!");
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
    } else if(ok) Print("CALF_C ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), ": ", lot);
}
void ProcessPendingTrade() { if(!g_pendingTrade.active) return; if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds) { ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP); g_pendingTrade.active = false; } }
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
                Print("CALF_C BACKUP: SL set #", ticket);
        }

        // 2. 3 TARGET SYSTEM
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
                    Print("CALF_C T1: Closed 33% (", closeL, " lots) @ ", profitPips, " pips");
                }
            }
            else g_positions[i].targetLevel = 1; // Skip ako lot premali
        }

        // Target 2: 500 pips = zatvori 50% preostalog
        if(g_positions[i].targetLevel == 1 && profitPips >= Target2_Pips)
        {
            if(PositionSelectByTicket(ticket)) // Refresh
            {
                currentLot = PositionGetDouble(POSITION_VOLUME);
                double closeL = currentLot * 0.50;
                closeL = MathFloor(closeL / lotStep) * lotStep;
                if(closeL >= minLot && closeL < currentLot)
                {
                    if(trade.PositionClosePartial(ticket, closeL))
                    {
                        g_positions[i].targetLevel = 2;
                        Print("CALF_C T2: Closed 50% (", closeL, " lots) @ ", profitPips, " pips");
                    }
                }
                else g_positions[i].targetLevel = 2;
            }
        }

        // 3. BE+ @ 1000 pips
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
                Print("CALF_C BE+: #", ticket, " SL=", newSL, " (+", g_positions[i].randomBEPips, " pips)");
            }
        }

        // 4. Kontinuirani trailing nakon BE+ (prati MFE - 1000 pips)
        if(g_positions[i].trailLevel >= 1 && currentSL > 0)
        {
            double trailPips = g_positions[i].maxFavorable - TrailDistancePips;
            if(trailPips > g_positions[i].randomBEPips) // Samo ako bolje od BE+
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
                    Print("CALF_C TRAIL: #", ticket, " MFE=", NormalizeDouble(g_positions[i].maxFavorable, 0),
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
    CalculateSupertrend();
    bool buySignal = (stDirection[1] == 1 && stDirection[2] == -1);
    bool sellSignal = (stDirection[1] == -1 && stDirection[2] == 1);
    if(buySignal) { Print("CALF_C BUY SIGNAL"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal) { Print("CALF_C SELL SIGNAL"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
