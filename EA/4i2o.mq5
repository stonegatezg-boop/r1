//+------------------------------------------------------------------+
//|                                                          4i2o.mq5 |
//|                                                         v4.0      |
//|          EA for CE signals filtered by VIKAS SuperTrend          |
//|          + Stealth Mode v2.0 (2026-02-20 Zagreb)                 |
//+------------------------------------------------------------------+
#property copyright "4i2o v4.0 - Stealth Mode"
#property link      ""
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;
    double   stealthTP;
    datetime openTime;
    int      slDelaySeconds;
    int      posType;
};

struct PendingTradeInfo { bool active; int signalType; datetime signalTime; int delaySeconds; };

//--- Input parameters
input double InpLotSize = 0.01;
input ulong  InpMagicNumber = 412000;

input group "=== STEALTH POSTAVKE ==="
input bool   UseStealthMode = true;
input int    OpenDelayMin   = 0;
input int    OpenDelayMax   = 4;
input int    SLDelayMin     = 7;
input int    SLDelayMax     = 13;

input group "=== TRADE MANAGEMENT ==="
input int    SLPipsMin      = 1400;
input int    SLPipsMax      = 1500;
input int    TPPipsMin      = 96;
input int    TPPipsMax      = 107;

//--- Global variables
CTrade trade;
datetime lastSignalTime = 0;
datetime lastBarTime = 0;

TradeData trades[];
int tradesCount = 0;
PendingTradeInfo g_pendingTrade;
datetime pendingSignalCandleTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    trade.SetExpertMagicNumber(InpMagicNumber);

    ArrayResize(trades, 0);
    tradesCount = 0;
    g_pendingTrade.active = false;

    lastBarTime = iTime(_Symbol, PERIOD_M5, 0);

    Print("=== 4i2o v4.0 STEALTH MODE inicijaliziran ===");
    Print("MagicNumber: ", InpMagicNumber);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal) { if(minVal >= maxVal) return minVal; return minVal + (MathRand() % (maxVal - minVal + 1)); }

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 6) return false;
    if(dt.day_of_week == 0) return (dt.hour > 1 || (dt.hour == 1 && dt.min >= 1));
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
    if(dt.day_of_week == 5) return (dt.hour < 12 || (dt.hour == 12 && dt.min <= 30));
    return false;
}

//+------------------------------------------------------------------+
bool IsBlackoutPeriod()
{
    if(!UseStealthMode) return false;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int minutes = dt.hour * 60 + dt.min;
    return (minutes >= 15*60+30 && minutes < 16*60+30);
}

//+------------------------------------------------------------------+
double GetPipValue()
{
    string symbol = _Symbol;
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    if(digits == 5 || digits == 3) return _Point * 10;
    if(digits == 4 || digits == 2) return _Point;
    if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0) return 0.1;
    if(StringFind(symbol, "XAG") >= 0 || StringFind(symbol, "SILVER") >= 0) return 0.01;
    if(StringFind(symbol, "XPD") >= 0 || StringFind(symbol, "XPT") >= 0) return 0.1;
    if(StringFind(symbol, "BTC") >= 0) return 1.0;
    if(StringFind(symbol, "ETH") >= 0) return 0.1;
    if(digits == 1) return _Point;
    return _Point * 10;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                return true;
    }
    return false;
}

//+------------------------------------------------------------------+
int GetPositionType()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            {
                ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                return (type == POSITION_TYPE_BUY) ? 1 : -1;
            }
        }
    }
    return 0;
}

//+------------------------------------------------------------------+
void SyncTradesArray()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(trades[i].ticket))
        {
            for(int j = i; j < tradesCount - 1; j++) trades[j] = trades[j + 1];
            tradesCount--;
            ArrayResize(trades, tradesCount);
        }
    }
}

//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double sl, double tp, int posType, int slDelay)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = sl;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = slDelay;
    trades[tradesCount].posType = posType;
    tradesCount++;
}

//+------------------------------------------------------------------+
int FindTradeByTicket(ulong ticket)
{
    for(int i = 0; i < tradesCount; i++) if(trades[i].ticket == ticket) return i;
    return -1;
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                trade.PositionClose(ticket);
        }
    }
}

//+------------------------------------------------------------------+
int CheckCESignal(datetime candleTime)
{
    string buyArrowName = "CE_BuyArrow_" + IntegerToString(candleTime);
    string sellArrowName = "CE_SellArrow_" + IntegerToString(candleTime);
    if(ObjectFind(0, buyArrowName) >= 0) return 1;
    if(ObjectFind(0, sellArrowName) >= 0) return -1;
    return 0;
}

//+------------------------------------------------------------------+
int CheckVIKASTrend(datetime candleTime)
{
    string upTrendName = "VIKAS_BuyArrow_" + IntegerToString(candleTime);
    string dnTrendName = "VIKAS_SellArrow_" + IntegerToString(candleTime);
    if(ObjectFind(0, upTrendName) >= 0) return 1;
    if(ObjectFind(0, dnTrendName) >= 0) return -1;

    int barIndex = iBarShift(_Symbol, PERIOD_M5, candleTime);
    if(barIndex < 0) barIndex = 0;

    int total = ChartIndicatorsTotal(0, 0);
    for(int i = 0; i < total; i++)
    {
        string name = ChartIndicatorName(0, 0, i);
        if(StringFind(name, "VIKAS") >= 0)
        {
            int handle = ChartIndicatorGet(0, 0, name);
            if(handle != INVALID_HANDLE)
            {
                double upValue[1], dnValue[1];
                if(CopyBuffer(handle, 0, barIndex, 1, upValue) > 0 && CopyBuffer(handle, 1, barIndex, 1, dnValue) > 0)
                {
                    if(upValue[0] != EMPTY_VALUE && upValue[0] != 0 && (dnValue[0] == EMPTY_VALUE || dnValue[0] == 0)) return 1;
                    if(dnValue[0] != EMPTY_VALUE && dnValue[0] != 0 && (upValue[0] == EMPTY_VALUE || upValue[0] == 0)) return -1;
                }
            }
            break;
        }
    }
    return 0;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
    if(currentBarTime != lastBarTime) { lastBarTime = currentBarTime; return true; }
    return false;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
    double pipValue = GetPipValue();
    double slPips = RandomRange(SLPipsMin, SLPipsMax);
    double tpPips = RandomRange(TPPipsMin, TPPipsMax);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = NormalizeDouble(ask - slPips * pipValue, _Digits);
    double tp = NormalizeDouble(ask + tpPips * pipValue, _Digits);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    bool ok;
    if(UseStealthMode)
        ok = trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "4i2o BUY");
    else
        ok = trade.Buy(InpLotSize, _Symbol, ask, sl, 0, "4i2o BUY");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        if(UseStealthMode)
        {
            AddTrade(ticket, ask, sl, tp, 1, slDelay);
            Print("4i2o STEALTH BUY: ", InpLotSize, " @ ", ask, " SL delay ", slDelay, "s, StealthTP=", tpPips, " pips");
        }
        else
        {
            AddTrade(ticket, ask, sl, tp, 1, 0);
            Print("4i2o BUY: ", InpLotSize, " @ ", ask, " SL=", sl, " Target=", tpPips, " pips");
        }
    }
}

//+------------------------------------------------------------------+
void OpenSell()
{
    double pipValue = GetPipValue();
    double slPips = RandomRange(SLPipsMin, SLPipsMax);
    double tpPips = RandomRange(TPPipsMin, TPPipsMax);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = NormalizeDouble(bid + slPips * pipValue, _Digits);
    double tp = NormalizeDouble(bid - tpPips * pipValue, _Digits);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    bool ok;
    if(UseStealthMode)
        ok = trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "4i2o SELL");
    else
        ok = trade.Sell(InpLotSize, _Symbol, bid, sl, 0, "4i2o SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        if(UseStealthMode)
        {
            AddTrade(ticket, bid, sl, tp, -1, slDelay);
            Print("4i2o STEALTH SELL: ", InpLotSize, " @ ", bid, " SL delay ", slDelay, "s, StealthTP=", tpPips, " pips");
        }
        else
        {
            AddTrade(ticket, bid, sl, tp, -1, 0);
            Print("4i2o SELL: ", InpLotSize, " @ ", bid, " SL=", sl, " Target=", tpPips, " pips");
        }
    }
}

//+------------------------------------------------------------------+
void ManageStealthPositions()
{
    SyncTradesArray();
    double pipValue = GetPipValue();

    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        double currentSL = PositionGetDouble(POSITION_SL);

        // Delayed SL
        if(UseStealthMode && currentSL == 0 && trades[i].intendedSL != 0 && TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
        {
            if(trade.PositionModify(ticket, NormalizeDouble(trades[i].intendedSL, _Digits), 0))
                Print("4i2o STEALTH: SL set #", ticket);
        }

        // Stealth TP check
        if(trades[i].stealthTP > 0)
        {
            double currentPrice;
            bool tpHit = false;

            if(trades[i].posType == 1)
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
                double profitPips = (trades[i].posType == 1) ? (currentPrice - trades[i].entryPrice) / pipValue : (trades[i].entryPrice - currentPrice) / pipValue;
                trade.PositionClose(ticket);
                Print("4i2o STEALTH: TP hit #", ticket, " (", DoubleToString(profitPips, 1), " pips)");
            }
        }
    }
}

//+------------------------------------------------------------------+
void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;
    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        int verifySignal = CheckCESignal(pendingSignalCandleTime);
        int vikasTrend = CheckVIKASTrend(pendingSignalCandleTime);

        if(verifySignal == g_pendingTrade.signalType && !HasOpenPosition())
        {
            bool canTrade = false;
            if(g_pendingTrade.signalType == 1 && vikasTrend == 1) canTrade = true;
            else if(g_pendingTrade.signalType == -1 && vikasTrend == -1) canTrade = true;
            else if(vikasTrend == 0) canTrade = true;

            if(canTrade)
            {
                if(g_pendingTrade.signalType == 1) OpenBuy();
                else if(g_pendingTrade.signalType == -1) OpenSell();
            }
        }

        g_pendingTrade.active = false;
        g_pendingTrade.signalType = 0;
        pendingSignalCandleTime = 0;
    }
}

//+------------------------------------------------------------------+
void QueueTrade(int signalType, datetime candleTime)
{
    g_pendingTrade.active = true;
    g_pendingTrade.signalType = signalType;
    g_pendingTrade.signalTime = TimeCurrent();
    g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
    pendingSignalCandleTime = candleTime;
    Print("4i2o: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
}

//+------------------------------------------------------------------+
void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPositions();

    if(!IsNewBar()) return;

    datetime prevCandleTime = iTime(_Symbol, PERIOD_M5, 1);
    if(prevCandleTime <= lastSignalTime) return;

    int signal = CheckCESignal(prevCandleTime);
    if(signal == 0) return;

    lastSignalTime = prevCandleTime;

    if(HasOpenPosition())
    {
        int currentPosType = GetPositionType();
        if(signal != currentPosType)
        {
            Print("4i2o: Opposite signal - closing position");
            CloseAllPositions();

            if(IsTradingWindow() && !IsBlackoutPeriod())
                QueueTrade(signal, prevCandleTime);
        }
        return;
    }

    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(g_pendingTrade.active) return;

    QueueTrade(signal, prevCandleTime);
}
//+------------------------------------------------------------------+
