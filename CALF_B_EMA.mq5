//+------------------------------------------------------------------+
//|                                                CALF_B_EMA.mq5    |
//|                        *** CALF B - EMA Crossover ***            |
//|                   Version 1.0 - 2026-02-11 18:00                 |
//+------------------------------------------------------------------+
#property copyright "CALF B - EMA 9/21 Crossover (2026-02-11)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== EMA POSTAVKE ==="
input int      FastEMA          = 9;        // Fast EMA Period
input int      SlowEMA          = 21;       // Slow EMA Period

input group "=== HULL FILTER ==="
input bool     UseHullFilter    = true;     // Use Hull MA filter
input int      HullPeriod       = 20;       // Hull Period

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 3.0;
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== SESSION ==="
input bool     UseSessionFilter = true;
input int      Session1Start    = 8;
input int      Session1End      = 11;
input int      Session2Start    = 14;
input int      Session2End      = 20;

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100002;
input int      Slippage         = 30;

CTrade trade;
int fastEmaHandle, slowEmaHandle, atrHandle;
datetime lastBarTime;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    fastEmaHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
    slowEmaHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

    if(fastEmaHandle == INVALID_HANDLE || slowEmaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
        return INIT_FAILED;

    lastBarTime = 0;
    Print("=== CALF B (EMA ", FastEMA, "/", SlowEMA, ") inicijaliziran ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(fastEmaHandle != INVALID_HANDLE) IndicatorRelease(fastEmaHandle);
    if(slowEmaHandle != INVALID_HANDLE) IndicatorRelease(slowEmaHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
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

void OpenBuy()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = NormalizeDouble(price - SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price + TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF_B BUY"))
        Print("CALF_B BUY: ", lots, " @ ", price);
}

void OpenSell()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(price + SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price - TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF_B SELL"))
        Print("CALF_B SELL: ", lots, " @ ", price);
}

void OnTick()
{
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsGoodSession()) return;

    double fast[], slow[];
    ArraySetAsSeries(fast, true);
    ArraySetAsSeries(slow, true);

    if(CopyBuffer(fastEmaHandle, 0, 0, 3, fast) <= 0) return;
    if(CopyBuffer(slowEmaHandle, 0, 0, 3, slow) <= 0) return;

    bool crossUp = (fast[1] > slow[1]) && (fast[2] <= slow[2]);
    bool crossDown = (fast[1] < slow[1]) && (fast[2] >= slow[2]);

    int hull = GetHullDirection();

    bool buySignal = crossUp && (!UseHullFilter || hull >= 0);
    bool sellSignal = crossDown && (!UseHullFilter || hull <= 0);

    if(buySignal) { Print("CALF_B BUY SIGNAL (EMA cross up)"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_B SELL SIGNAL (EMA cross down)"); OpenSell(); }
}
//+------------------------------------------------------------------+
