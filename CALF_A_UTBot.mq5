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

    int copied = CopyClose(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, low);

    if(copied < UTAtrPeriod + 5) return;

    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / UTAtrPeriod;
    if(atr <= 0) return;
    double nLoss = UTKey * atr;

    // Calculate trailing stop for bars 4,3,2,1,0 (need history for position)
    double ts[5];
    int pos[5];
    ArrayInitialize(ts, 0);
    ArrayInitialize(pos, 0);

    // Initialize first bar's trailing stop
    ts[4] = close[4];
    pos[4] = (close[4] > close[5]) ? 1 : -1;

    // Calculate trailing stop and position for each bar
    for(int i = 3; i >= 0; i--)
    {
        double src = close[i];
        double srcPrev = close[i+1];
        double prevTS = ts[i+1];
        int prevPos = pos[i+1];

        // Update trailing stop based on price action
        if(prevPos == 1)
        {
            // In uptrend - trailing stop follows price up
            ts[i] = MathMax(prevTS, src - nLoss);
            if(src < ts[i])
            {
                ts[i] = src + nLoss;
                pos[i] = -1;  // Flip to downtrend
            }
            else
            {
                pos[i] = 1;   // Stay in uptrend
            }
        }
        else
        {
            // In downtrend - trailing stop follows price down
            ts[i] = MathMin(prevTS, src + nLoss);
            if(src > ts[i])
            {
                ts[i] = src - nLoss;
                pos[i] = 1;   // Flip to uptrend
            }
            else
            {
                pos[i] = -1;  // Stay in downtrend
            }
        }
    }

    // Copy to global arrays (index 0,1,2)
    for(int i = 0; i < 3; i++)
    {
        trailingStop[i] = ts[i];
        utPosition[i] = pos[i];
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

    // Debug: print UT Bot state every new bar
    Print("CALF_A: utPos[0]=", utPosition[0], " utPos[1]=", utPosition[1], " utPos[2]=", utPosition[2],
          " TS=", DoubleToString(trailingStop[1], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));

    if(buySignal) { Print("CALF_A BUY SIGNAL (flip from down to up)"); OpenBuy(); }
    else if(sellSignal) { Print("CALF_A SELL SIGNAL (flip from up to down)"); OpenSell(); }
}
//+------------------------------------------------------------------+
