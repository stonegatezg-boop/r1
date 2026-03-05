//+------------------------------------------------------------------+
//|                                           Apex_Notebook_Cla.mq5  |
//|                   *** Apex Notebook Cla v1.0 ***                 |
//|         Created: 05.03.2026 (Zagreb)                             |
//|         UTBot + H1 EMA + ADX Filter + Session Filter             |
//|         + Stealth TP + 3-Level Trailing + MFE Trailing           |
//|         + Early/Time Failure Exits                               |
//+------------------------------------------------------------------+
#property copyright "Apex Notebook Cla v1.0 (2026-03-05)"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

//--- Position tracking structure
struct StealthPos
{
    bool     active;
    ulong    ticket;
    double   entry;
    double   stealthTP;
    double   realSL;
    double   maxProfit;
    int      trailLevel;
    int      bars;
    int      dir;
    datetime openTime;
};

//=== INPUT PARAMETERS ===
input group "=== RISK MANAGEMENT ==="
input double RiskPercent     = 1.0;
input int    MaxSL_Pips      = 800;
input ulong  MagicNumber     = 20260305;
input int    Slippage        = 30;

input group "=== UTBOT SETTINGS ==="
input double UTKey           = 2.0;
input int    UTAtrPeriod     = 10;
input bool   RequireCandleConf = true;

input group "=== H1 EMA FILTER ==="
input bool   UseH1_Filter    = true;
input int    H1_EMA_Period   = 50;

input group "=== ADX FILTER ==="
input bool   UseADX_Filter   = true;
input int    ADX_Period      = 14;
input int    ADX_Threshold   = 20;

input group "=== SESSION FILTER ==="
input bool   UseSessionFilter = true;
input int    LondonStart     = 8;
input int    LondonEnd       = 12;
input int    NYStart         = 13;
input int    NYEnd           = 17;

input group "=== SPREAD FILTER ==="
input bool   UseSpreadFilter = true;
input int    MaxSpread       = 50;

input group "=== SL/TP SETTINGS ==="
input double SLMultiplier    = 2.0;
input double TPMultiplier    = 4.0;
input int    ATRPeriod       = 14;

input group "=== TRAILING STOP (3-LEVEL) ==="
input int    TrailL1_Pips    = 500;
input int    TrailL1_BE      = 40;
input int    TrailL2_Pips    = 800;
input int    TrailL2_Lock    = 150;
input int    TrailL3_Pips    = 1200;
input int    TrailL3_Lock    = 200;

input group "=== MFE TRAILING ==="
input int    MFE_ActivatePips  = 1500;
input int    MFE_TrailDistance = 500;

input group "=== EARLY/TIME FAILURE ==="
input int    EarlyFailurePips  = 800;
input int    TimeFailureBars   = 4;
input int    TimeFailureMinPips = 20;

//=== GLOBAL VARIABLES ===
CTrade       trade;
int          atrHandle, emaHandle, adxHandle;
double       trailingStop[4];
int          utPosition[4];
double       point;
datetime     lastBarTime = 0;
StealthPos   posArray[];
int          posCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    atrHandle = iATR(_Symbol, PERIOD_M5, ATRPeriod);
    emaHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    adxHandle = iADX(_Symbol, PERIOD_M5, ADX_Period);

    if(atrHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicators!");
        return INIT_FAILED;
    }

    ArrayResize(posArray, 0);
    posCount = 0;

    Print("=== APEX NOTEBOOK CLA v1.0 INITIALIZED ===");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
    if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
double GetATR()
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
double GetADX()
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
int GetH1Trend()
{
    if(!UseH1_Filter) return 0;
    double ema[];
    ArraySetAsSeries(ema, true);
    if(CopyBuffer(emaHandle, 0, 0, 3, ema) < 3) return 0;
    double price = iClose(_Symbol, PERIOD_H1, 1);
    if(price > ema[0] && ema[0] > ema[1]) return 1;
    if(price < ema[0] && ema[0] < ema[1]) return -1;
    return 0;
}

//+------------------------------------------------------------------+
bool IsMarketTrending()
{
    if(!UseADX_Filter) return true;
    return (GetADX() >= ADX_Threshold);
}

//+------------------------------------------------------------------+
bool IsValidSession()
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
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
    if(dt.day_of_week == 5) return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));
    return false;
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    if(!UseSpreadFilter) return true;
    int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
void CalculateUTBot()
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    int needed = UTAtrPeriod + 5;
    if(CopyClose(_Symbol, PERIOD_M5, 0, needed, close) <= 0) return;
    CopyHigh(_Symbol, PERIOD_M5, 0, needed, high);
    CopyLow(_Symbol, PERIOD_M5, 0, needed, low);

    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i],
                    MathMax(MathAbs(high[i] - close[i+1]),
                            MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / UTAtrPeriod;
    if(atr <= 0) return;

    double nLoss = UTKey * atr;
    double ts[5];
    int pos[5];

    ts[4] = close[4];
    pos[4] = (close[4] > close[5]) ? 1 : -1;

    for(int i = 3; i >= 0; i--)
    {
        double src = close[i];
        double prevTS = ts[i+1];
        int prevPos = pos[i+1];

        if(prevPos == 1)
        {
            ts[i] = MathMax(prevTS, src - nLoss);
            if(src < ts[i]) { ts[i] = src + nLoss; pos[i] = -1; }
            else pos[i] = 1;
        }
        else
        {
            ts[i] = MathMin(prevTS, src + nLoss);
            if(src > ts[i]) { ts[i] = src - nLoss; pos[i] = 1; }
            else pos[i] = -1;
        }
    }

    for(int i = 0; i < 4; i++)
    {
        trailingStop[i] = ts[i];
        utPosition[i] = pos[i];
    }
}

//+------------------------------------------------------------------+
double CalcLot(double slDist)
{
    if(slDist <= 0) return 0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk = balance * RiskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double lot = risk / ((slDist / tickSize) * tickVal);
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
int CountPositions()
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
void SyncPositions()
{
    for(int i = posCount - 1; i >= 0; i--)
    {
        if(!posArray[i].active) continue;
        if(!PositionSelectByTicket(posArray[i].ticket))
        {
            posArray[i].active = false;
            for(int j = i; j < posCount - 1; j++)
                posArray[j] = posArray[j + 1];
            posCount--;
            ArrayResize(posArray, posCount);
        }
    }
}

//+------------------------------------------------------------------+
void AddPosition(ulong ticket, double entry, double sl, double tp, int dir)
{
    ArrayResize(posArray, posCount + 1);
    posArray[posCount].active = true;
    posArray[posCount].ticket = ticket;
    posArray[posCount].entry = entry;
    posArray[posCount].stealthTP = tp;
    posArray[posCount].realSL = sl;
    posArray[posCount].maxProfit = 0;
    posArray[posCount].trailLevel = 0;
    posArray[posCount].bars = 0;
    posArray[posCount].dir = dir;
    posArray[posCount].openTime = TimeCurrent();
    posCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
        Print("APEX CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
double GetProfitPips(int idx)
{
    if(!posArray[idx].active) return 0;
    if(!PositionSelectByTicket(posArray[idx].ticket)) return 0;

    double currentPrice;
    if(posArray[idx].dir == 1)
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    else
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double diff;
    if(posArray[idx].dir == 1)
        diff = currentPrice - posArray[idx].entry;
    else
        diff = posArray[idx].entry - currentPrice;

    return diff / point;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
    SyncPositions();
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = posCount - 1; i >= 0; i--)
    {
        if(!posArray[i].active) continue;
        if(!PositionSelectByTicket(posArray[i].ticket)) continue;

        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice;
        if(posArray[i].dir == 1)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        else
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double profitPips = GetProfitPips(i);

        if(profitPips > posArray[i].maxProfit)
            posArray[i].maxProfit = profitPips;

        // 1. STEALTH TP
        bool tpHit = false;
        if(posArray[i].dir == 1 && currentPrice >= posArray[i].stealthTP) tpHit = true;
        else if(posArray[i].dir == -1 && currentPrice <= posArray[i].stealthTP) tpHit = true;

        if(tpHit)
        {
            ClosePosition(posArray[i].ticket, "STEALTH TP @ " + DoubleToString(currentPrice, digits));
            continue;
        }

        // 2. EARLY FAILURE
        if(EarlyFailurePips > 0 && posArray[i].bars <= 2 && profitPips < -EarlyFailurePips)
        {
            ClosePosition(posArray[i].ticket, "EARLY FAILURE @ " + DoubleToString(profitPips, 0) + " pips");
            continue;
        }

        // 3. TIME FAILURE
        if(TimeFailureBars > 0 && posArray[i].bars >= TimeFailureBars && profitPips < TimeFailureMinPips)
        {
            ClosePosition(posArray[i].ticket, "TIME FAILURE - bars=" + IntegerToString(posArray[i].bars));
            continue;
        }

        // 4. MFE TRAILING
        if(posArray[i].trailLevel >= 3 && profitPips >= MFE_ActivatePips)
        {
            double mfeSL;
            double trailDist = MFE_TrailDistance * point;
            if(posArray[i].dir == 1)
            {
                mfeSL = posArray[i].entry + (posArray[i].maxProfit * point) - trailDist;
                mfeSL = NormalizeDouble(mfeSL, digits);
                if(mfeSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, mfeSL, 0))
                        Print("APEX MFE [", posArray[i].ticket, "]: Trail @ ", mfeSL);
            }
            else
            {
                mfeSL = posArray[i].entry - (posArray[i].maxProfit * point) + trailDist;
                mfeSL = NormalizeDouble(mfeSL, digits);
                if(mfeSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, mfeSL, 0))
                        Print("APEX MFE [", posArray[i].ticket, "]: Trail @ ", mfeSL);
            }
        }
        // 5. L3 TRAILING
        else if(posArray[i].trailLevel == 2 && profitPips >= TrailL3_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + TrailL3_Lock * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 3; Print("APEX L3 [", posArray[i].ticket, "]: Lock +", TrailL3_Lock); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - TrailL3_Lock * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 3; Print("APEX L3 [", posArray[i].ticket, "]: Lock +", TrailL3_Lock); }
            }
        }
        // 6. L2 TRAILING
        else if(posArray[i].trailLevel == 1 && profitPips >= TrailL2_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + TrailL2_Lock * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 2; Print("APEX L2 [", posArray[i].ticket, "]: Lock +", TrailL2_Lock); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - TrailL2_Lock * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 2; Print("APEX L2 [", posArray[i].ticket, "]: Lock +", TrailL2_Lock); }
            }
        }
        // 7. L1 TRAILING (BE)
        else if(posArray[i].trailLevel == 0 && profitPips >= TrailL1_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + TrailL1_BE * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 1; Print("APEX L1 [", posArray[i].ticket, "]: BE+", TrailL1_BE); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - TrailL1_BE * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 1; Print("APEX L1 [", posArray[i].ticket, "]: BE+", TrailL1_BE); }
            }
        }
    }
}

//+------------------------------------------------------------------+
void UpdateBarCount()
{
    for(int i = 0; i < posCount; i++)
        if(posArray[i].active) posArray[i].bars++;
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDist = SLMultiplier * atr;

    // MAX SL LIMIT
    if(MaxSL_Pips > 0)
    {
        double maxSlDist = MaxSL_Pips * point;
        if(slDist > maxSlDist)
        {
            slDist = maxSlDist;
            Print("SL capped to ", MaxSL_Pips, " pips");
        }
    }

    double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    double lot = CalcLot(slDist);
    if(lot <= 0) return;

    bool ok = false;
    string comment = (type == ORDER_TYPE_BUY) ? "APEX BUY" : "APEX SELL";

    if(type == ORDER_TYPE_BUY)
        ok = trade.Buy(lot, _Symbol, price, sl, 0, comment);
    else
        ok = trade.Sell(lot, _Symbol, price, sl, 0, comment);

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        int dir = (type == ORDER_TYPE_BUY) ? 1 : -1;
        AddPosition(ticket, price, sl, tp, dir);
        Print("APEX ", comment, " | Entry: ", price, " | SL: ", sl, " | TP(stealth): ", tp);
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ManagePositions();

    datetime t = iTime(_Symbol, PERIOD_M5, 0);
    if(t == lastBarTime) return;
    lastBarTime = t;

    UpdateBarCount();

    if(CountPositions() > 0) return;
    if(!IsTradingWindow()) return;
    if(!IsValidSession()) return;
    if(!IsMarketTrending()) return;
    if(!IsSpreadOK()) return;

    CalculateUTBot();

    int h1 = GetH1Trend();
    double close = iClose(_Symbol, PERIOD_M5, 1);
    double open = iOpen(_Symbol, PERIOD_M5, 1);
    bool bull = close > open;
    bool bear = close < open;

    bool utBuy = (utPosition[0] == 1 && utPosition[1] == -1);
    bool utSell = (utPosition[0] == -1 && utPosition[1] == 1);

    if(utBuy && (!RequireCandleConf || bull))
        if(!UseH1_Filter || h1 >= 0)
            ExecuteTrade(ORDER_TYPE_BUY);

    if(utSell && (!RequireCandleConf || bear))
        if(!UseH1_Filter || h1 <= 0)
            ExecuteTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
double OnTester()
{
    double pf = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    if(trades < 30) return 0;
    return pf * MathSqrt(trades);
}
//+------------------------------------------------------------------+
