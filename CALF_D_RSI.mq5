//+------------------------------------------------------------------+
//|                                                CALF_D_RSI.mq5    |
//|                        *** CALF D - RSI Reversal ***             |
//|                   Version 1.0 - 2026-02-11 18:00                 |
//+------------------------------------------------------------------+
#property copyright "CALF D - RSI Mean Reversion (2026-02-11)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

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

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100004;
input int      Slippage         = 30;

CTrade trade;
int rsiHandle, atrHandle;
datetime lastBarTime;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

    if(rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE) return INIT_FAILED;

    lastBarTime = 0;
    Print("=== CALF D (RSI ", RSIPeriod, " [", OversoldLevel, "/", OverboughtLevel, "]) inicijaliziran ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
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
    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF_D BUY"))
        Print("CALF_D BUY: ", lots, " @ ", price);
}

void OpenSell()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(price + SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price - TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF_D SELL"))
        Print("CALF_D SELL: ", lots, " @ ", price);
}

void OnTick()
{
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsGoodSession()) return;

    double rsi[];
    ArraySetAsSeries(rsi, true);
    if(CopyBuffer(rsiHandle, 0, 0, 3, rsi) <= 0) return;

    // RSI exits extreme zone = signal
    bool wasOversold = rsi[2] < OversoldLevel;
    bool nowAboveOversold = rsi[1] >= OversoldLevel;
    bool wasOverbought = rsi[2] > OverboughtLevel;
    bool nowBelowOverbought = rsi[1] <= OverboughtLevel;

    bool buySignal = wasOversold && nowAboveOversold;    // RSI exits oversold
    bool sellSignal = wasOverbought && nowBelowOverbought; // RSI exits overbought

    int hull = GetHullDirection();

    // Optional: only trade with trend
    if(UseHullFilter)
    {
        if(buySignal && hull < 0) buySignal = false;   // Don't buy in downtrend
        if(sellSignal && hull > 0) sellSignal = false; // Don't sell in uptrend
    }

    if(buySignal) { Print("CALF_D BUY SIGNAL (RSI exit oversold)"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_D SELL SIGNAL (RSI exit overbought)"); OpenSell(); }
}
//+------------------------------------------------------------------+
