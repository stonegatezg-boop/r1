//+------------------------------------------------------------------+
//|                                              CALF_A_UTBot.mq5    |
//|                        *** CALF A - UT Bot Only ***              |
//|                   Version 1.0 - 2026-02-11 18:00                 |
//+------------------------------------------------------------------+
#property copyright "CALF A - UT Bot Only (2026-02-11)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== UT BOT POSTAVKE ==="
input double   UTKey            = 2.0;      // Key Value (sensitivity)
input int      UTAtrPeriod      = 10;       // ATR Period

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;      // Stop Loss (x ATR)
input double   TPMultiplier     = 3.0;      // Take Profit (x ATR)
input int      ATRPeriod        = 14;       // ATR Period za SL/TP
input double   RiskPercent      = 1.0;      // Risk %

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;
input int      Session1Start    = 8;        // London start
input int      Session1End      = 11;       // London end
input int      Session2Start    = 14;       // NY start
input int      Session2End      = 20;       // NY end

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100001;   // Magic Number
input int      Slippage         = 30;

CTrade trade;
int atrHandle;
double trailingStop[];
int utPosition[];
datetime lastBarTime;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;

    ArraySetAsSeries(trailingStop, true);
    ArraySetAsSeries(utPosition, true);
    ArrayResize(trailingStop, 3);
    ArrayResize(utPosition, 3);

    lastBarTime = 0;
    Print("=== CALF A (UT Bot) inicijaliziran ===");
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

void CalculateUTBot()
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    CopyClose(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, low);

    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / UTAtrPeriod;
    double nLoss = UTKey * atr;

    for(int s = 2; s >= 0; s--)
    {
        double src = close[s];
        double srcPrev = close[s+1];
        double prevTS = (s < 2) ? trailingStop[s+1] : close[s];

        if(src > prevTS && srcPrev > prevTS)
            trailingStop[s] = MathMax(prevTS, src - nLoss);
        else if(src < prevTS && srcPrev < prevTS)
            trailingStop[s] = MathMin(prevTS, src + nLoss);
        else if(src > prevTS)
            trailingStop[s] = src - nLoss;
        else
            trailingStop[s] = src + nLoss;

        if(srcPrev < prevTS && src > prevTS)
            utPosition[s] = 1;
        else if(srcPrev > prevTS && src < prevTS)
            utPosition[s] = -1;
        else
            utPosition[s] = (s < 2) ? utPosition[s+1] : 0;
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
    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF_A BUY"))
        Print("CALF_A BUY: ", lots, " @ ", price);
}

void OpenSell()
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(price + SLMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double tp = NormalizeDouble(price - TPMultiplier * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF_A SELL"))
        Print("CALF_A SELL: ", lots, " @ ", price);
}

void OnTick()
{
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsGoodSession()) return;

    CalculateUTBot();

    bool buySignal = (utPosition[1] == 1 && utPosition[2] == -1);
    bool sellSignal = (utPosition[1] == -1 && utPosition[2] == 1);

    if(buySignal) { Print("CALF_A BUY SIGNAL"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_A SELL SIGNAL"); OpenSell(); }
}
//+------------------------------------------------------------------+
