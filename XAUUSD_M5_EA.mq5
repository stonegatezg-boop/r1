//+------------------------------------------------------------------+
//|                                              XAUUSD_M5_EA.mq5    |
//|                        *** CALF ***                              |
//|                        AlphaTrend + UT Bot + Session Filter      |
//|                   + Stealth Mode v2.0                            |
//|                   Version 2.0 - 2026-02-20                       |
//+------------------------------------------------------------------+
#property copyright "CALF - AlphaTrend + UT Bot + Stealth (2026-02-20)"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== ALPHATREND POSTAVKE ==="
input int      AlphaPeriod      = 14;
input double   AlphaCoeff       = 1.0;

input group "=== UT BOT POSTAVKE ==="
input double   UTKey            = 2.0;
input int      UTAtrPeriod      = 14;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 1.5;
input double   TPMultiplier     = 2.5;
input int      ATRPeriod        = 20;
input int      MaxBarsInTrade   = 48;
input double   RiskPercent      = 1.0;

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;
input int      LondonStart      = 2;
input int      LondonEnd        = 5;
input int      NYAMStart        = 9;
input int      NYAMEnd          = 11;
input int      NYPMStart        = 13;
input int      NYPMEnd          = 17;

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
input int      SLDelayMin       = 7;
input int      SLDelayMax       = 13;
input double   LargeCandleATR   = 3.0;

input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips = 500;
input int      TrailBEPipsMin   = 33;
input int      TrailBEPipsMax   = 38;

input group "=== OPCE POSTAVKE ==="
input ulong    MagicNumber      = 123456;
input int      Slippage         = 30;
input bool     TradeOnNewBar    = true;

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo { bool active; ulong ticket; double intendedSL; double stealthTP; double entryPrice; datetime openTime; int delaySeconds; int randomBEPips; int trailLevel; int barsInTrade; };

//--- Global variables
CTrade         trade;
int            atrHandle;
int            rsiHandle;
double         alphaLine[];
double         trailingStop[];
int            alphaTrend[];
int            utPosition[];
datetime       lastBarTime;

PendingTradeInfo g_pendingTrade;
StealthPosInfo   g_positions[];
int              g_posCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, AlphaPeriod, PRICE_CLOSE);

    if(atrHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
    {
        Print("Greska pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    ArraySetAsSeries(alphaLine, true);
    ArraySetAsSeries(trailingStop, true);
    ArraySetAsSeries(alphaTrend, true);
    ArraySetAsSeries(utPosition, true);

    ArrayResize(alphaLine, 3);
    ArrayResize(trailingStop, 3);
    ArrayResize(alphaTrend, 3);
    ArrayResize(utPosition, 3);

    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0);
    g_posCount = 0;

    Print("=== CALF EA v2.0 STEALTH MODE ===");
    Print("AlphaTrend(", AlphaPeriod, ",", AlphaCoeff, ") + UT Bot(", UTKey, ",", UTAtrPeriod, ")");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
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
    if(currentBarTime != lastBarTime) { lastBarTime = currentBarTime; return true; }
    return false;
}

//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    if(hour >= LondonStart && hour < LondonEnd) return true;
    if(hour >= NYAMStart && hour < NYAMEnd) return true;
    if(hour >= NYPMStart && hour < NYPMEnd) return true;
    return false;
}

//+------------------------------------------------------------------+
void CalculateAlphaTrend(int shift)
{
    double close[], high[], low[], atr[], rsi[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(atr, true);
    ArraySetAsSeries(rsi, true);

    int bars = AlphaPeriod + 10;
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);

    double sumTR = 0;
    for(int i = 1; i <= AlphaPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double alphaATR = sumTR / AlphaPeriod;

    double rsiBuffer[];
    ArraySetAsSeries(rsiBuffer, true);
    CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer);

    for(int s = 2; s >= 0; s--)
    {
        double up = close[s] - AlphaCoeff * alphaATR;
        double dn = close[s] + AlphaCoeff * alphaATR;
        double prevAlpha = (s < 2) ? alphaLine[s+1] : close[s];
        if(rsiBuffer[s] >= 50) { alphaLine[s] = MathMax(up, prevAlpha); alphaTrend[s] = 1; }
        else { alphaLine[s] = MathMin(dn, prevAlpha); alphaTrend[s] = -1; }
    }
}

//+------------------------------------------------------------------+
void CalculateUTBot(int shift)
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    int bars = UTAtrPeriod + 10;
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);

    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double utATR = sumTR / UTAtrPeriod;
    double nLoss = UTKey * utATR;

    for(int s = 2; s >= 0; s--)
    {
        double src = close[s];
        double srcPrev = close[s+1];
        double prevTS = (s < 2) ? trailingStop[s+1] : close[s];
        if(src > prevTS && srcPrev > prevTS) trailingStop[s] = MathMax(prevTS, src - nLoss);
        else if(src < prevTS && srcPrev < prevTS) trailingStop[s] = MathMin(prevTS, src + nLoss);
        else if(src > prevTS) trailingStop[s] = src - nLoss;
        else trailingStop[s] = src + nLoss;

        if(srcPrev < prevTS && src > prevTS) utPosition[s] = 1;
        else if(srcPrev > prevTS && src < prevTS) utPosition[s] = -1;
        else utPosition[s] = (s < 2) ? utPosition[s+1] : 0;
    }
}

//+------------------------------------------------------------------+
double GetATR(int shift = 1)
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, shift, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
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
    double atr = GetATR(1);
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
        Print("CALF: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
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
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF");
    else
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF SELL");

    if(ok && UseStealthMode)
    {
        ulong ticket = trade.ResultOrder();
        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = sl;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
        g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
        g_positions[g_posCount].trailLevel = 0;
        g_positions[g_posCount].barsInTrade = 0;
        g_posCount++;
        Print("CALF STEALTH: Opened #", ticket, ", SL delay ", g_positions[g_posCount-1].delaySeconds, "s");
    }
    else if(ok) Print("CALF ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), ": ", lot, " @ ", price);
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
void ManageStealthPositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;
        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Delayed SL
        if(currentSL == 0 && g_positions[i].intendedSL != 0 && TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds)
        {
            if(trade.PositionModify(ticket, NormalizeDouble(g_positions[i].intendedSL, digits), 0))
                Print("CALF STEALTH: SL set #", ticket);
        }

        // Stealth TP
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit) { trade.PositionClose(ticket); Print("CALF STEALTH: TP hit #", ticket); g_positions[i].active = false; continue; }
        }

        // Time exit
        if(g_positions[i].barsInTrade >= MaxBarsInTrade)
        {
            trade.PositionClose(ticket);
            Print("CALF: Time exit #", ticket);
            g_positions[i].active = false;
            continue;
        }

        // Trailing to BE
        if(g_positions[i].trailLevel < 1 && currentSL > 0)
        {
            double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - g_positions[i].entryPrice) / point : (g_positions[i].entryPrice - currentPrice) / point;
            if(profitPips >= TrailActivatePips)
            {
                double newSL = (posType == POSITION_TYPE_BUY) ? g_positions[i].entryPrice + g_positions[i].randomBEPips * point : g_positions[i].entryPrice - g_positions[i].randomBEPips * point;
                newSL = NormalizeDouble(newSL, digits);
                bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL);
                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 1;
                    Print("CALF STEALTH: Trail BE+", g_positions[i].randomBEPips, " #", ticket);
                }
            }
        }
    }
    CleanupPositions();
}

//+------------------------------------------------------------------+
void CleanupPositions()
{
    int newCount = 0;
    for(int i = 0; i < g_posCount; i++)
    {
        if(g_positions[i].active) { if(i != newCount) g_positions[newCount] = g_positions[i]; newCount++; }
    }
    if(newCount != g_posCount) { g_posCount = newCount; ArrayResize(g_positions, g_posCount); }
}

//+------------------------------------------------------------------+
void IncrementBarsInTrade()
{
    for(int i = 0; i < g_posCount; i++)
    {
        if(g_positions[i].active) g_positions[i].barsInTrade++;
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPositions();

    if(TradeOnNewBar && !IsNewBar()) return;

    // Increment bars counter for stealth positions
    if(UseStealthMode) IncrementBarsInTrade();

    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(!IsGoodSession()) return;
    if(g_pendingTrade.active) return;

    CalculateAlphaTrend(1);
    CalculateUTBot(1);

    int alphaTrendDir = alphaTrend[1];
    bool utCrossUp = (utPosition[1] == 1 && utPosition[2] == -1);
    bool utCrossDown = (utPosition[1] == -1 && utPosition[2] == 1);

    bool buySignal = utCrossUp && (alphaTrendDir == 1);
    bool sellSignal = utCrossDown && (alphaTrendDir == -1);

    if(buySignal)
    {
        Print("CALF BUY SIGNAL");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(sellSignal)
    {
        Print("CALF SELL SIGNAL");
        QueueTrade(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double profit = TesterStatistics(STAT_PROFIT);
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    double winRate = TesterStatistics(STAT_TRADES) > 0 ? TesterStatistics(STAT_PROFIT_TRADES) / TesterStatistics(STAT_TRADES) * 100 : 0;
    if(trades < 100) return 0;
    return profitFactor * MathSqrt(trades);
}
//+------------------------------------------------------------------+
