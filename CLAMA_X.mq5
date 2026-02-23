//+------------------------------------------------------------------+
//|                                                      CLAMA_X.mq5 |
//|                        *** CLAMA X v2.0 *** |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   + Stealth Execution & Trailing Upgrade         |
//|                   + MULTIPLE TRADES (no limit)                   |
//|                   Date: 2026-02-23                               |
//+------------------------------------------------------------------+
#property copyright "CLAMA X v2.0 - Stealth Edition (2026-02-23)"
#property version   "2.00"
#property strict
#include <Trade\Trade.mqh>
//--- Struktura za praćenje svakog tradea
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;      // Dodano: Za odgođeno postavljanje SL-a
    datetime openTime;        // Dodano: Za odgođeno postavljanje SL-a
    int      slDelaySeconds;  // Random delay 7-13s
    double   stealthTP;
    int      trailLevel;      // 0=none, 1=BE, 2=L2
    int      randomBEPips;
    int      randomLevel2Pips;
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
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 3.0;
input int      ATRPeriod        = 20;
input double   MinATR           = 1.0;
input int      MaxBarsInTrade   = 48;
input double   RiskPercent      = 1.0;
input int      MaxOpenTrades    = 10;
input group "=== STEALTH & EXECUTION ==="
input int      SLDelayMin       = 7;        // Delay min (sekunde)
input int      SLDelayMax       = 13;       // Delay max (sekunde)
input double   LargeCandleATR   = 3.0;      // Ne ulazi ako je svijeća > 3x ATR
input group "=== TRAILING STOP ==="
input int      TrailActivatePips   = 500;   // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin      = 38;    // BE + min pips (Ažurirano)
input int      TrailBEPipsMax      = 43;    // BE + max pips (Ažurirano)
input int      TrailLevel2Pips     = 1000;  // Level 2 aktivacija (pips profit)
input int      TrailLevel2SLMin    = 181;   // Level 2 SL min pips profit
input int      TrailLevel2SLMax    = 213;   // Level 2 SL max pips profit
input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;
input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 334567;
input int      Slippage         = 30;
//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
//--- Array za praćenje svih otvorenih tradeova
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
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    Print("=== CLAMA X v2.0 STEALTH EDITION inicijaliziran ===");
    return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
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
// NOVO RADNO VRIJEME (Novi Prompt)
bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1)); // Nedjelja od 00:01
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true; // Pon-Čet cijeli dan
    if(dt.day_of_week == 5) return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30)); // Petak do 11:30
    return false;
}
//+------------------------------------------------------------------+
// NOVI FILTER ZA EKSTREMNE SVIJEĆE
bool IsLargeCandle()
{
    double atr = GetATR();
    if(atr <= 0) return false;
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);
    return ((high - low) > LargeCandleATR * atr);
}
//+------------------------------------------------------------------+
bool IsHistogramGrowing(bool forBuy)
{
    if(!UseHistogramFilter) return true;
    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true); ArraySetAsSeries(macdSignal, true);
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
    double close[]; ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2 + 5;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close) <= 0) return 0;
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0.0, wmaFull = 0.0, sumWeightsHalf = 0.0, sumWeightsFull = 0.0;
    for(int i = 0; i < halfPeriod; i++) { double w = (double)(halfPeriod - i); wmaHalf += close[i+1] * w; sumWeightsHalf += w; }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;
    for(int i = 0; i < HullPeriod; i++) { double w = (double)(HullPeriod - i); wmaFull += close[i+1] * w; sumWeightsFull += w; }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;
    double hullCurrent = 2.0 * wmaHalf - wmaFull;
    wmaHalf = 0.0; wmaFull = 0.0; sumWeightsHalf = 0.0; sumWeightsFull = 0.0;
    for(int i = 0; i < halfPeriod; i++) { double w = (double)(halfPeriod - i); wmaHalf += close[i+3] * w; sumWeightsHalf += w; }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;
    for(int i = 0; i < HullPeriod; i++) { double w = (double)(HullPeriod - i); wmaFull += close[i+3] * w; sumWeightsFull += w; }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;
    double hullPrev = 2.0 * wmaHalf - wmaFull;
    double diff = hullCurrent - hullPrev;
    double threshold = GetATR() * 0.1;
    if(diff > threshold) return 1;
    if(diff < -threshold) return -1;
    return 0;
}
//+------------------------------------------------------------------+
double GetATR() { double atrBuffer[]; ArraySetAsSeries(atrBuffer, true); if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0; return atrBuffer[0]; }
//+------------------------------------------------------------------+
void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false; sellSignal = false;
    if(barsSinceLastTrade < MinBarsBetweenTrades) return;
    double atr = GetATR(); if(atr < MinATR) return;
    double macdMain[], macdSignal[]; ArraySetAsSeries(macdMain, true); ArraySetAsSeries(macdSignal, true);
    if(CopyBuffer(macdHandle, 0, 0, 3, macdMain) <= 0) return; if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) <= 0) return;
    bool macdCrossUp = (macdMain[1] > macdSignal[1]) && (macdMain[2] < macdSignal[2]);
    bool macdCrossDown = (macdMain[1] < macdSignal[1]) && (macdMain[2] > macdSignal[2]);
    int hullDir = GetHullDirection();
    if(macdCrossUp && (!UseTrendFilter || (StrictHullFilter ? hullDir == 1 : hullDir >= 0))) if(IsHistogramGrowing(true)) buySignal = true;
    if(macdCrossDown && (!UseTrendFilter || (StrictHullFilter ? hullDir == -1 : hullDir <= 0))) if(IsHistogramGrowing(false)) sellSignal = true;
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
    return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lotSize)), 2);
}
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) count++;
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
            for(int j = i; j < tradesCount - 1; j++) trades[j] = trades[j + 1];
            tradesCount--; ArrayResize(trades, tradesCount);
        }
    }
}
//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double intendedSL, double tp, int delay, int bePips, int l2Pips)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = intendedSL;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = delay;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].trailLevel = 0;
    trades[tradesCount].randomBEPips = bePips;
    trades[tradesCount].randomLevel2Pips = l2Pips;
    trades[tradesCount].barsInTrade = 0;
    tradesCount++;
}
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason) { if(trade.PositionClose(ticket)) Print("CLAMA X CLOSE [", ticket, "]: ", reason); }
//+------------------------------------------------------------------+
void ManageAllPositions()
{
    SyncTradesArray();
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        //--- 1. Odgođeni Stop Loss ---
        if(currentSL == 0 && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                double sl = NormalizeDouble(trades[i].intendedSL, digits);
                if(trade.PositionModify(ticket, sl, 0)) Print("CLAMA X STEALTH: SL postavljen na ", sl, " za #", ticket);
            }
        }
        //--- 2. Stealth TP ---
        if(trades[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= trades[i].stealthTP) || (posType == POSITION_TYPE_SELL && currentPrice <= trades[i].stealthTP);
            if(tpHit) { ClosePosition(ticket, "Stealth TP HIT"); continue; }
        }
        //--- 3. Trailing Stops ---
        if(currentSL > 0) // Pokreni trailing tek kad je inicijalni SL postavljen
        {
            double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - trades[i].entryPrice) / point : (trades[i].entryPrice - currentPrice) / point;
            // Level 2
            if(trades[i].trailLevel < 2 && profitPips >= TrailLevel2Pips)
            {
                double newSL = (posType == POSITION_TYPE_BUY) ? trades[i].entryPrice + trades[i].randomLevel2Pips * point : trades[i].entryPrice - trades[i].randomLevel2Pips * point;
                newSL = NormalizeDouble(newSL, digits);
                if((posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL))
                    if(trade.PositionModify(ticket, newSL, 0)) trades[i].trailLevel = 2;
                continue;
            }
            // Level 1 BE
            if(trades[i].trailLevel < 1 && profitPips >= TrailActivatePips)
            {
                double newSL = (posType == POSITION_TYPE_BUY) ? trades[i].entryPrice + trades[i].randomBEPips * point : trades[i].entryPrice - trades[i].randomBEPips * point;
                newSL = NormalizeDouble(newSL, digits);
                if((posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL))
                    if(trade.PositionModify(ticket, newSL, 0)) trades[i].trailLevel = 1;
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
        if(trades[i].barsInTrade >= MaxBarsInTrade) ClosePosition(trades[i].ticket, "Time exit");
    }
}
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(); if(atr <= 0) return;
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double sl = (type == ORDER_TYPE_BUY) ? price - SLMultiplier * atr : price + SLMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return;
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int l2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    // ULaz BEZ SL i BEZ TP (Stealth)
    bool ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lots, _Symbol, price, 0, 0, "CLAMA X") : trade.Sell(lots, _Symbol, price, 0, 0, "CLAMA X");
    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        double stealthTP = (type == ORDER_TYPE_BUY) ? NormalizeDouble(price + TPMultiplier * atr, digits) : NormalizeDouble(price - TPMultiplier * atr, digits);

        AddTrade(ticket, price, sl, stealthTP, slDelay, bePips, l2Pips);
        barsSinceLastTrade = 0;
        Print("CLAMA X STEALTH OTVORENO [", ticket, "] -> SL Delay: ", slDelay, "s");
    }
}
//+------------------------------------------------------------------+
void OnTick()
{
    ManageAllPositions();
    if(!IsNewBar()) return;
    CheckTimeExits();
    SyncTradesArray();

    if(!IsTradingWindow()) return;
    if(IsLargeCandle()) return;
    if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;
    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);
    if(buySignal) OpenTrade(ORDER_TYPE_BUY);
    else if(sellSignal) OpenTrade(ORDER_TYPE_SELL);
}
//+------------------------------------------------------------------+
