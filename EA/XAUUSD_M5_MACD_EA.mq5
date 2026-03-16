//+------------------------------------------------------------------+
//|                                         XAUUSD_M5_MACD_EA.mq5    |
//|                        *** CLAMA v2.0 ***                        |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   + Trailing Stop + Stealth Mode v2.0            |
//|                   Date: 2026-02-20 (Zagreb, CET)                 |
//+------------------------------------------------------------------+
#property copyright "CLAMA v2.0 - Full Stealth Mode (2026-02-20)"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

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

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
input int      SLDelayMin       = 7;
input int      SLDelayMax       = 13;
input double   LargeCandleATR   = 3.0;

input group "=== TRAILING STOP ==="
input int      TrailActivatePips   = 500;
input int      TrailBEPipsMin      = 33;
input int      TrailBEPipsMax      = 38;
input int      TrailLevel2Pips     = 1000;
input int      TrailLevel2SLMin    = 181;
input int      TrailLevel2SLMax    = 213;

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;
input int      LondonStart      = 8;
input int      LondonEnd        = 11;
input int      NYStart          = 14;
input int      NYEnd            = 20;

input group "=== OPCE POSTAVKE ==="
input ulong    MagicNumber      = 234567;
input int      Slippage         = 30;

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo { bool active; ulong ticket; double intendedSL; double stealthTP; double entryPrice; datetime openTime; int delaySeconds; int randomBEPips; int randomL2Pips; int trailLevel; int barsInTrade; };

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;

PendingTradeInfo g_pendingTrade;
StealthPosInfo   g_position;

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
        Print("Greska pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = MinBarsBetweenTrades + 1;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    g_position.active = false;

    Print("=== CLAMA v2.0 STEALTH MODE inicijaliziran ===");
    Print("MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("Stealth: OpenDelay ", OpenDelayMin, "-", OpenDelayMax, "s, SLDelay ", SLDelayMin, "-", SLDelayMax, "s");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal) { if(minVal >= maxVal) return minVal; return minVal + (MathRand() % (maxVal - minVal + 1)); }

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
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    return ((iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) > LargeCandleATR * atr[0]);
}

bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime != lastBarTime) { lastBarTime = currentBarTime; barsSinceLastTrade++; return true; }
    return false;
}

//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
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
    double close[]; ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2 + 5;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close) <= 0) return 0;
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0.0, wmaFull = 0.0;
    double sumWeightsHalf = 0.0, sumWeightsFull = 0.0;
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
double GetATR()
{
    double atrBuffer[]; ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false; sellSignal = false;
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

//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
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
        Print("CLAMA v2.0: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp);
    }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);
    bool ok;

    if(UseStealthMode)
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CLAMA v2") : trade.Sell(lot, _Symbol, price, 0, 0, "CLAMA v2");
    else
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CLAMA BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CLAMA SELL");

    if(ok && UseStealthMode)
    {
        ulong ticket = trade.ResultOrder();
        g_position.active = true;
        g_position.ticket = ticket;
        g_position.intendedSL = sl;
        g_position.stealthTP = tp;
        g_position.entryPrice = price;
        g_position.openTime = TimeCurrent();
        g_position.delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
        g_position.randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
        g_position.randomL2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
        g_position.trailLevel = 0;
        g_position.barsInTrade = 0;
        Print("CLAMA STEALTH: Opened #", ticket, ", SL delay ", g_position.delaySeconds, "s");
        Print("Random Trail: BE+", g_position.randomBEPips, " pips, L2+", g_position.randomL2Pips, " pips");
    }
    else if(ok) Print("CLAMA ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), ": ", lot, " @ ", price);

    barsSinceLastTrade = 0;
}

//+------------------------------------------------------------------+
void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;
    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
        g_pendingTrade.active = false;
    }
}

//+------------------------------------------------------------------+
void ManageStealthPosition()
{
    if(!g_position.active) return;
    ulong ticket = g_position.ticket;
    if(!PositionSelectByTicket(ticket)) { g_position.active = false; return; }

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // Delayed SL
    if(currentSL == 0 && g_position.intendedSL != 0 && TimeCurrent() >= g_position.openTime + g_position.delaySeconds)
    {
        if(trade.PositionModify(ticket, NormalizeDouble(g_position.intendedSL, digits), 0))
            Print("CLAMA STEALTH: SL set #", ticket);
    }

    // Stealth TP
    if(g_position.stealthTP > 0)
    {
        bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_position.stealthTP) ||
                     (posType == POSITION_TYPE_SELL && currentPrice <= g_position.stealthTP);
        if(tpHit) { trade.PositionClose(ticket); Print("CLAMA STEALTH: TP hit #", ticket); g_position.active = false; return; }
    }

    // Time exit
    if(g_position.barsInTrade >= MaxBarsInTrade)
    {
        trade.PositionClose(ticket);
        Print("CLAMA: Time exit #", ticket);
        g_position.active = false;
        return;
    }

    // Level 2 Trailing
    if(g_position.trailLevel < 2 && currentSL > 0)
    {
        double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - g_position.entryPrice) / point : (g_position.entryPrice - currentPrice) / point;
        if(profitPips >= TrailLevel2Pips)
        {
            double newSL = (posType == POSITION_TYPE_BUY) ? g_position.entryPrice + g_position.randomL2Pips * point : g_position.entryPrice - g_position.randomL2Pips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_position.trailLevel = 2;
                Print("CLAMA STEALTH: Trail L2+", g_position.randomL2Pips, " #", ticket);
            }
            return;
        }
    }

    // Level 1 BE Trailing
    if(g_position.trailLevel < 1 && currentSL > 0)
    {
        double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - g_position.entryPrice) / point : (g_position.entryPrice - currentPrice) / point;
        if(profitPips >= TrailActivatePips)
        {
            double newSL = (posType == POSITION_TYPE_BUY) ? g_position.entryPrice + g_position.randomBEPips * point : g_position.entryPrice - g_position.randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_position.trailLevel = 1;
                Print("CLAMA STEALTH: Trail BE+", g_position.randomBEPips, " #", ticket);
            }
        }
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPosition();

    bool newBar = IsNewBar();

    if(newBar && g_position.active) g_position.barsInTrade++;

    if(!newBar) return;

    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(!IsGoodSession()) return;
    if(g_pendingTrade.active) return;

    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    if(buySignal)
    {
        Print("CLAMA v2.0 BUY SIGNAL (Hull=", GetHullDirection(), ")");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(sellSignal)
    {
        Print("CLAMA v2.0 SELL SIGNAL (Hull=", GetHullDirection(), ")");
        QueueTrade(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    if(trades < 50) return 0;
    return profitFactor * MathSqrt(trades);
}
//+------------------------------------------------------------------+
