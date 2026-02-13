//+------------------------------------------------------------------+
//|                                         CALF_C_Supertrend.mq5    |
//|                        *** CALF C - Supertrend ***               |
//|                   Version 1.0 - 2026-02-11 18:00                 |
//+------------------------------------------------------------------+
#property copyright "CALF C - Supertrend (2026-02-11)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== SUPERTREND POSTAVKE ==="
input int      STperiod         = 10;       // ATR Period
input double   STmultiplier     = 2.0;      // ATR Multiplier

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
input ulong    MagicNumber      = 100003;
input int      Slippage         = 30;

CTrade trade;
int atrHandle;
double supertrend[];
int stDirection[];
datetime lastBarTime;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;

    ArraySetAsSeries(supertrend, true);
    ArraySetAsSeries(stDirection, true);
    ArrayResize(supertrend, 5);
    ArrayResize(stDirection, 5);

    lastBarTime = 0;
    Print("=== CALF C (Supertrend ", STperiod, ",", STmultiplier, ") inicijaliziran ===");
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

void CalculateSupertrend()
{
    double high[], low[], close[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    int bars = STperiod + 10;
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);

    // Calculate ATR manually
    double sumTR = 0;
    for(int i = 1; i <= STperiod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / STperiod;

    // Calculate Supertrend for last 5 bars
    for(int s = 4; s >= 0; s--)
    {
        double hl2 = (high[s] + low[s]) / 2.0;
        double upperBand = hl2 + STmultiplier * atr;
        double lowerBand = hl2 - STmultiplier * atr;

        double prevST = (s < 4) ? supertrend[s+1] : hl2;
        int prevDir = (s < 4) ? stDirection[s+1] : 1;

        if(prevDir == 1) // Was bullish
        {
            if(close[s] < prevST)
            {
                supertrend[s] = upperBand;
                stDirection[s] = -1;
            }
            else
            {
                supertrend[s] = MathMax(lowerBand, prevST);
                stDirection[s] = 1;
            }
        }
        else // Was bearish
        {
            if(close[s] > prevST)
            {
                supertrend[s] = lowerBand;
                stDirection[s] = 1;
            }
            else
            {
                supertrend[s] = MathMin(upperBand, prevST);
                stDirection[s] = -1;
            }
        }
    }
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
    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF_C BUY"))
        Print("CALF_C BUY: ", lots, " @ ", price);
}

void OpenSell()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(price + SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price - TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF_C SELL"))
        Print("CALF_C SELL: ", lots, " @ ", price);
}

void OnTick()
{
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsGoodSession()) return;

    CalculateSupertrend();

    // Supertrend flip signals
    bool buySignal = (stDirection[1] == 1 && stDirection[2] == -1);
    bool sellSignal = (stDirection[1] == -1 && stDirection[2] == 1);

    if(buySignal) { Print("CALF_C BUY SIGNAL (Supertrend flip)"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_C SELL SIGNAL (Supertrend flip)"); OpenSell(); }
}
//+------------------------------------------------------------------+
