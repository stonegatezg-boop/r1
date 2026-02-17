//+------------------------------------------------------------------+
//|                                              CLAMA_X_NoTrail.mq5 |
//|                     *** CLAMA X NoTrail v1.0 ***                 |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   + MULTIPLE TRADES + Stealth TP (NO TRAILING)   |
//|                   Date: 2026-02-17 16:45 (Zagreb, CET)           |
//+------------------------------------------------------------------+
#property copyright "CLAMA X NoTrail v1.0 (2026-02-17)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Struktura za praćenje svakog tradea (JEDNOSTAVNA - bez trailinga)
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   stealthTP;
    int      barsInTrade;
};

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 8;
input int      SlowEMA          = 17;
input int      SignalSMA        = 9;
input bool     UseHistogramFilter = true;

input group "=== TREND FILTER (Hull MA) ==="
input bool     UseTrendFilter   = true;
input int      HullPeriod       = 20;
input bool     StrictHullFilter = true;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;      // Stop Loss (x ATR)
input double   TPMultiplier     = 3.0;      // Take Profit (x ATR) - STEALTH
input int      ATRPeriod        = 20;
input double   MinATR           = 1.0;
input int      MaxBarsInTrade   = 48;
input double   RiskPercent      = 1.0;
input int      MaxOpenTrades    = 10;       // 0 = bez limita

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;
input int      LondonStart      = 8;
input int      LondonEnd        = 11;
input int      NYStart          = 14;
input int      NYEnd            = 20;

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 434567;   // Različit od CLAMA X (334567)!
input int      Slippage         = 30;

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;

TradeData      trades[];
int            tradesCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    macdHandle = iMACD(_Symbol, PERIOD_CURRENT, FastEMA, SlowEMA, SignalSMA, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

    if(macdHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = MinBarsBetweenTrades + 1;
    ArrayResize(trades, 0);
    tradesCount = 0;

    Print("=== CLAMA X NoTrail v1.0 (2026-02-17 16:45 Zagreb) ===");
    Print("*** NO TRAILING - samo Stealth TP ***");
    Print("MagicNumber: ", MagicNumber);
    Print("SL=", SLMultiplier, "xATR, TP=", TPMultiplier, "xATR");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        barsSinceLastTrade++;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    if(hour >= LondonStart && hour < LondonEnd) return true;
    if(hour >= NYStart && hour < NYEnd) return true;
    return false;
}

//+------------------------------------------------------------------+
bool IsHistogramGrowing(bool forBuy)
{
    if(!UseHistogramFilter) return true;
    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);
    if(CopyBuffer(macdHandle, 0, 0, 4, macdMain) <= 0) return false;
    if(CopyBuffer(macdHandle, 1, 0, 4, macdSignal) <= 0) return false;
    double hist1 = macdMain[1] - macdSignal[1];
    double hist2 = macdMain[2] - macdSignal[2];
    double hist3 = macdMain[3] - macdSignal[3];
    if(forBuy) return (hist1 > hist2 && hist2 > hist3);
    else return (hist1 < hist2 && hist2 < hist3);
}

//+------------------------------------------------------------------+
int GetHullDirection()
{
    if(!UseTrendFilter) return 0;
    double close[];
    ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2 + 5;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close) <= 0) return 0;
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0.0, wmaFull = 0.0;
    double sumWeightsHalf = 0.0, sumWeightsFull = 0.0;
    for(int i = 0; i < halfPeriod; i++)
    {
        double w = (double)(halfPeriod - i);
        wmaHalf += close[i+1] * w;
        sumWeightsHalf += w;
    }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;
    for(int i = 0; i < HullPeriod; i++)
    {
        double w = (double)(HullPeriod - i);
        wmaFull += close[i+1] * w;
        sumWeightsFull += w;
    }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;
    double hullCurrent = 2.0 * wmaHalf - wmaFull;
    wmaHalf = 0.0; wmaFull = 0.0;
    sumWeightsHalf = 0.0; sumWeightsFull = 0.0;
    for(int i = 0; i < halfPeriod; i++)
    {
        double w = (double)(halfPeriod - i);
        wmaHalf += close[i+3] * w;
        sumWeightsHalf += w;
    }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;
    for(int i = 0; i < HullPeriod; i++)
    {
        double w = (double)(HullPeriod - i);
        wmaFull += close[i+3] * w;
        sumWeightsFull += w;
    }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;
    double hullPrev = 2.0 * wmaHalf - wmaFull;
    double diff = hullCurrent - hullPrev;
    double threshold = GetATR() * 0.1;
    if(diff > threshold) return 1;
    if(diff < -threshold) return -1;
    return 0;
}

//+------------------------------------------------------------------+
double GetATR()
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;
    if(barsSinceLastTrade < MinBarsBetweenTrades) return;
    double atr = GetATR();
    if(atr < MinATR) return;
    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);
    if(CopyBuffer(macdHandle, 0, 0, 3, macdMain) <= 0) return;
    if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) <= 0) return;
    bool macdCrossUp = (macdMain[1] > macdSignal[1]) && (macdMain[2] < macdSignal[2]);
    bool macdCrossDown = (macdMain[1] < macdSignal[1]) && (macdMain[2] > macdSignal[2]);
    int hullDir = GetHullDirection();
    if(macdCrossUp)
    {
        if(!UseTrendFilter || (StrictHullFilter ? hullDir == 1 : hullDir >= 0))
            if(IsHistogramGrowing(true)) buySignal = true;
    }
    if(macdCrossDown)
    {
        if(!UseTrendFilter || (StrictHullFilter ? hullDir == -1 : hullDir <= 0))
            if(IsHistogramGrowing(false)) sellSignal = true;
    }
}

//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * RiskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double slPoints = slDistance / point;
    double lotSize = riskAmount / (slPoints * tickValue / tickSize);
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
void SyncTradesArray()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(trades[i].ticket))
        {
            for(int j = i; j < tradesCount - 1; j++)
                trades[j] = trades[j + 1];
            tradesCount--;
            ArrayResize(trades, tradesCount);
        }
    }
}

//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double tp)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].barsInTrade = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
        Print("CLAMA X NoTrail CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
void ManageAllPositions()
{
    SyncTradesArray();
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        //--- Samo provjera Stealth TP (NEMA TRAILINGA!)
        if(trades[i].stealthTP > 0)
        {
            double currentPrice;
            bool tpHit = false;

            if(posType == POSITION_TYPE_BUY)
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(currentPrice >= trades[i].stealthTP) tpHit = true;
            }
            else
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if(currentPrice <= trades[i].stealthTP) tpHit = true;
            }

            if(tpHit)
            {
                ClosePosition(ticket, "Stealth TP HIT @ " + DoubleToString(currentPrice, digits));
            }
        }
    }
}

//+------------------------------------------------------------------+
void CheckTimeExits()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        trades[i].barsInTrade++;
        if(trades[i].barsInTrade >= MaxBarsInTrade)
            ClosePosition(trades[i].ticket, "Time exit - " + IntegerToString(trades[i].barsInTrade) + " bars");
    }
}

//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr = GetATR();
    if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = price - SLMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    if(trade.Buy(lots, _Symbol, price, sl, 0, "CLAMA X NoTrail BUY"))
    {
        ulong ticket = trade.ResultOrder();
        double stealthTP = NormalizeDouble(price + TPMultiplier * atr, digits);
        AddTrade(ticket, price, stealthTP);
        Print("CLAMA X NoTrail BUY [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " TP=", stealthTP);
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
void OpenSell()
{
    double atr = GetATR();
    if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = price + SLMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    if(trade.Sell(lots, _Symbol, price, sl, 0, "CLAMA X NoTrail SELL"))
    {
        ulong ticket = trade.ResultOrder();
        double stealthTP = NormalizeDouble(price - TPMultiplier * atr, digits);
        AddTrade(ticket, price, stealthTP);
        Print("CLAMA X NoTrail SELL [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " TP=", stealthTP);
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ManageAllPositions();

    if(!IsNewBar()) return;

    CheckTimeExits();
    SyncTradesArray();

    if(!IsGoodSession()) return;

    if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;

    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    if(buySignal)
    {
        Print("CLAMA X NoTrail BUY SIGNAL");
        OpenBuy();
    }
    else if(sellSignal)
    {
        Print("CLAMA X NoTrail SELL SIGNAL");
        OpenSell();
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades_count = TesterStatistics(STAT_TRADES);
    if(trades_count < 50) return 0;
    return profitFactor * MathSqrt(trades_count);
}
//+------------------------------------------------------------------+
