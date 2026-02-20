//+------------------------------------------------------------------+
//|                                                CALF_D_RSI.mq5    |
//|                        *** CALF D - RSI Reversal ***             |
//|                   + Stealth Mode v2.0 + Trailing                 |
//|                   Version 2.0 - 2026-02-20                       |
//+------------------------------------------------------------------+
#property copyright "CALF D - RSI + Stealth (2026-02-20)"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Stealth structures
struct StealthPosInfo
{
    bool     active;
    ulong    ticket;
    double   intendedSL;
    double   stealthTP;
    double   entryPrice;
    datetime openTime;
    int      delaySeconds;
    int      randomBEPips;
    int      trailLevel;
};

struct PendingTradeInfo
{
    bool           active;
    ENUM_ORDER_TYPE type;
    double         lot;
    double         intendedSL;
    double         intendedTP;
    datetime       signalTime;
    int            delaySeconds;
};

input group "=== RSI POSTAVKE ==="
input int      RSIPeriod        = 14;       // RSI Period
input int      OversoldLevel    = 30;       // Oversold level (BUY zone)
input int      OverboughtLevel  = 70;       // Overbought level (SELL zone)

input group "=== HULL FILTER ==="
input bool     UseHullFilter    = true;     // Trade with trend only
input int      HullPeriod       = 20;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 2.5;      // Smaller TP for mean reversion
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== SESSION ==="
input bool     UseSessionFilter = true;
input int      Session1Start    = 8;
input int      Session1End      = 11;
input int      Session2Start    = 14;
input int      Session2End      = 20;

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
input int      SLDelayMin       = 7;
input int      SLDelayMax       = 13;
input double   LargeCandleATR   = 3.0;

input group "=== TRAILING POSTAVKE ==="
input bool     UseTrailing      = true;
input int      TrailActivatePips = 500;
input int      TrailBEPipsMin   = 33;
input int      TrailBEPipsMax   = 38;
input int      TrailLevel2Pips  = 1000;
input int      TrailLevel2SLMin = 150;
input int      TrailLevel2SLMax = 200;

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100004;
input int      Slippage         = 30;

CTrade trade;
int rsiHandle, atrHandle;
datetime lastBarTime;

StealthPosInfo g_stealthPos;
PendingTradeInfo g_pendingTrade;

//+------------------------------------------------------------------+
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
    g_stealthPos.active = false;
    g_pendingTrade.active = false;

    Print("=== CALF D v2.0 (RSI ", RSIPeriod, " [", OversoldLevel, "/", OverboughtLevel, "]) + STEALTH ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+

int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != lastBarTime) { lastBarTime = t; return true; }
    return false;
}

bool IsGoodSession()
{
    if(!UseSessionFilter) return true;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
    if(h >= Session1Start && h < Session1End) return true;
    if(h >= Session2Start && h < Session2End) return true;
    return false;
}

bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0) return (dt.hour > 1 || (dt.hour == 1 && dt.min >= 1));
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
    if(dt.day_of_week == 5) return (dt.hour < 12 || (dt.hour == 12 && dt.min <= 30));
    return false;
}

bool IsBlackoutPeriod()
{
    if(!UseStealthMode) return false;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int minutes = dt.hour * 60 + dt.min;
    return (minutes >= 15*60+30 && minutes < 16*60+30);
}

bool IsLargeCandle()
{
    if(!UseStealthMode) return false;
    double atr = GetATR();
    if(atr <= 0) return false;
    double candleRange = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleRange > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| HULL MA DIRECTION                                                 |
//+------------------------------------------------------------------+

int GetHullDirection()
{
    if(!UseHullFilter) return 0;

    double close[];
    ArraySetAsSeries(close, true);
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

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                 |
//+------------------------------------------------------------------+

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

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

bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
    }
    return false;
}

double GetProfitPips(ulong ticket, double entryPrice)
{
    if(!PositionSelectByTicket(ticket)) return 0;
    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double currentPrice = (posType == POSITION_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(posType == POSITION_TYPE_BUY)
        return (currentPrice - entryPrice) / point;
    else
        return (entryPrice - currentPrice) / point;
}

//+------------------------------------------------------------------+
//| STEALTH POSITION MANAGEMENT                                       |
//+------------------------------------------------------------------+

void SyncStealthPosition()
{
    if(!g_stealthPos.active) return;
    if(!PositionSelectByTicket(g_stealthPos.ticket))
        g_stealthPos.active = false;
}

void ManageStealthPosition()
{
    if(!g_stealthPos.active) return;
    if(!PositionSelectByTicket(g_stealthPos.ticket)) { g_stealthPos.active = false; return; }

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double currentPrice = (posType == POSITION_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double profitPips = GetProfitPips(g_stealthPos.ticket, g_stealthPos.entryPrice);

    // Delayed SL
    if(UseStealthMode && currentSL == 0 && g_stealthPos.intendedSL != 0)
    {
        if(TimeCurrent() >= g_stealthPos.openTime + g_stealthPos.delaySeconds)
        {
            if(trade.PositionModify(g_stealthPos.ticket, NormalizeDouble(g_stealthPos.intendedSL, digits), 0))
                Print("CALF_D STEALTH: SL set #", g_stealthPos.ticket);
        }
    }

    // Hidden TP
    if(g_stealthPos.stealthTP > 0)
    {
        bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_stealthPos.stealthTP) ||
                     (posType == POSITION_TYPE_SELL && currentPrice <= g_stealthPos.stealthTP);
        if(tpHit)
        {
            if(trade.PositionClose(g_stealthPos.ticket))
                Print("CALF_D STEALTH: TP hit #", g_stealthPos.ticket);
            g_stealthPos.active = false;
            return;
        }
    }

    // Trailing Level 2
    if(UseTrailing && g_stealthPos.trailLevel < 2 && profitPips >= TrailLevel2Pips && currentSL > 0)
    {
        int randomL2 = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
        double newSL = (posType == POSITION_TYPE_BUY) ?
            g_stealthPos.entryPrice + randomL2 * point :
            g_stealthPos.entryPrice - randomL2 * point;
        newSL = NormalizeDouble(newSL, digits);

        bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                            (posType == POSITION_TYPE_SELL && newSL < currentSL);
        if(shouldModify && trade.PositionModify(g_stealthPos.ticket, newSL, 0))
        {
            g_stealthPos.trailLevel = 2;
            Print("CALF_D TRAIL L2: +", randomL2, " pips");
        }
        return;
    }

    // Trailing Level 1 (BE)
    if(UseTrailing && g_stealthPos.trailLevel < 1 && profitPips >= TrailActivatePips && currentSL > 0)
    {
        double newSL = (posType == POSITION_TYPE_BUY) ?
            g_stealthPos.entryPrice + g_stealthPos.randomBEPips * point :
            g_stealthPos.entryPrice - g_stealthPos.randomBEPips * point;
        newSL = NormalizeDouble(newSL, digits);

        bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                            (posType == POSITION_TYPE_SELL && newSL < currentSL);
        if(shouldModify && trade.PositionModify(g_stealthPos.ticket, newSL, 0))
        {
            g_stealthPos.trailLevel = 1;
            Print("CALF_D TRAIL BE: +", g_stealthPos.randomBEPips, " pips");
        }
    }
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION                                                   |
//+------------------------------------------------------------------+

void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (type == ORDER_TYPE_BUY) ? price - SLMultiplier * atr : price + SLMultiplier * atr;
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr);
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
        Print("CALF_D: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp);
    }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    bool ok;
    if(UseStealthMode)
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, 0, 0, "CALF_D") :
            trade.Sell(lot, _Symbol, price, 0, 0, "CALF_D");
    else
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, sl, tp, "CALF_D BUY") :
            trade.Sell(lot, _Symbol, price, sl, tp, "CALF_D SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        if(UseStealthMode)
        {
            g_stealthPos.active = true;
            g_stealthPos.ticket = ticket;
            g_stealthPos.intendedSL = sl;
            g_stealthPos.stealthTP = tp;
            g_stealthPos.entryPrice = price;
            g_stealthPos.openTime = TimeCurrent();
            g_stealthPos.delaySeconds = slDelay;
            g_stealthPos.randomBEPips = bePips;
            g_stealthPos.trailLevel = 0;
            Print("CALF_D STEALTH: Opened #", ticket, ", SL delay ", slDelay, "s");
        }
        Print("CALF_D ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), ": ", lot, " @ ", price);
    }
}

void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;
    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                     g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
        g_pendingTrade.active = false;
    }
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                 |
//+------------------------------------------------------------------+

void OnTick()
{
    ProcessPendingTrade();
    SyncStealthPosition();
    ManageStealthPosition();

    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(!IsGoodSession()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(g_pendingTrade.active) return;

    double rsi[];
    ArraySetAsSeries(rsi, true);
    if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) <= 0) return;

    // RSI exits extreme zone = signal
    bool wasOversold = rsi[2] < OversoldLevel;
    bool nowAboveOversold = rsi[1] >= OversoldLevel;
    bool wasOverbought = rsi[2] > OverboughtLevel;
    bool nowBelowOverbought = rsi[1] <= OverboughtLevel;

    bool buySignal = wasOversold && nowAboveOversold;
    bool sellSignal = wasOverbought && nowBelowOverbought;

    int hull = GetHullDirection();

    if(UseHullFilter)
    {
        if(buySignal && hull < 0) buySignal = false;
        if(sellSignal && hull > 0) sellSignal = false;
    }

    if(buySignal) { Print("CALF_D BUY SIGNAL (RSI exit oversold)"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal) { Print("CALF_D SELL SIGNAL (RSI exit overbought)"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
