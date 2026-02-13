//+------------------------------------------------------------------+
//|                                           CALF_E_Breakout.mq5    |
//|                        *** CALF E - Breakout ***                 |
//|                   Version 1.0 - 2026-02-11 18:00                 |
//+------------------------------------------------------------------+
#property copyright "CALF E - Breakout Strategy (2026-02-11)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== BREAKOUT POSTAVKE ==="
input int      LookbackBars     = 20;       // Bars to find High/Low
input double   BreakoutBuffer   = 0.5;      // Buffer above/below (x ATR)

input group "=== VOLUME FILTER ==="
input bool     UseVolumeFilter  = true;     // Require above avg volume
input int      VolumePeriod     = 20;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 3.5;      // Bigger TP for breakouts
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== SESSION ==="
input bool     UseSessionFilter = true;
input int      Session1Start    = 8;
input int      Session1End      = 11;
input int      Session2Start    = 14;
input int      Session2End      = 20;

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100005;
input int      Slippage         = 30;

CTrade trade;
int atrHandle;
datetime lastBarTime;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;

    lastBarTime = 0;
    Print("=== CALF E (Breakout ", LookbackBars, " bars) inicijaliziran ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle); }

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

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

bool IsVolumeAboveAverage()
{
    if(!UseVolumeFilter) return true;

    long vol[];
    ArraySetAsSeries(vol, true);
    if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, VolumePeriod + 1, vol) <= 0) return true;

    double sum = 0;
    for(int i = 1; i <= VolumePeriod; i++) sum += (double)vol[i];
    double avg = sum / (double)VolumePeriod;

    return ((double)vol[1] > avg * 1.2); // 20% above average
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
    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF_E BUY"))
        Print("CALF_E BUY: ", lots, " @ ", price);
}

void OpenSell()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(price + SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price - TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF_E SELL"))
        Print("CALF_E SELL: ", lots, " @ ", price);
}

void OnTick()
{
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsGoodSession()) return;

    double high[], low[], close[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, close) <= 0) return;

    // Find highest high and lowest low of last N bars (excluding current and previous)
    double highestHigh = high[2];
    double lowestLow = low[2];

    for(int i = 2; i < LookbackBars + 2; i++)
    {
        if(high[i] > highestHigh) highestHigh = high[i];
        if(low[i] < lowestLow) lowestLow = low[i];
    }

    double atr = GetATR();
    double buffer = BreakoutBuffer * atr;

    // Breakout signals
    bool buySignal = (close[1] > highestHigh + buffer) && (close[2] <= highestHigh);
    bool sellSignal = (close[1] < lowestLow - buffer) && (close[2] >= lowestLow);

    // Volume filter
    if(!IsVolumeAboveAverage())
    {
        buySignal = false;
        sellSignal = false;
    }

    if(buySignal) { Print("CALF_E BUY SIGNAL (Breakout high ", highestHigh, ")"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_E SELL SIGNAL (Breakout low ", lowestLow, ")"); OpenSell(); }
}
//+------------------------------------------------------------------+
