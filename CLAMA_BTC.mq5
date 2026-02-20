//+------------------------------------------------------------------+
//|                                                   CLAMA_BTC.mq5  |
//|                        *** CLAMA BTC v1.0 ***                    |
//|                   MACD + Hull MA Strategy for BTCUSD M5          |
//|                   + Trailing Stop + Stealth Mode v2.0            |
//|                   + MULTIPLE TRADES (no limit)                   |
//|                   + 24/7 Crypto Trading Support                  |
//|                   Based on CLAMA_X - Adapted for Bitcoin         |
//|                   Date: 2026-02-20 (Zagreb, CET)                 |
//+------------------------------------------------------------------+
#property copyright "CLAMA BTC v1.0 - Multi-Trade Stealth (2026-02-20)"
#property version   "1.00"
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
    int      trailLevel;
    int      randomBEPips;
    int      randomLevel2Pips;
    int      barsInTrade;
};

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 12;       // Fast EMA (BTC: slightly slower)
input int      SlowEMA          = 26;       // Slow EMA
input int      SignalSMA        = 9;        // Signal SMA
input bool     UseHistogramFilter = true;   // Require histogram momentum

input group "=== TREND FILTER (Hull MA) ==="
input bool     UseTrendFilter   = true;     // Use Hull MA filter
input int      HullPeriod       = 20;       // Hull MA period
input bool     StrictHullFilter = true;     // Strict trend matching

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 1.5;      // SL = ATR * multiplier (BTC: tighter)
input double   TPMultiplier     = 2.5;      // TP = ATR * multiplier
input int      ATRPeriod        = 14;       // ATR period
input double   MinATR           = 50.0;     // Minimum ATR to trade (BTC in USD)
input double   MaxATR           = 2000.0;   // Maximum ATR (avoid extreme volatility)
input int      MaxBarsInTrade   = 96;       // Max bars before time exit (8 hours on M5)
input double   RiskPercent      = 0.5;      // Risk % per trade (BTC: conservative)
input int      MaxOpenTrades    = 5;        // Max concurrent trades

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;     // Enable stealth mode
input int      OpenDelayMin     = 0;        // Min delay before opening (seconds)
input int      OpenDelayMax     = 5;        // Max delay before opening
input int      SLDelayMin       = 5;        // Min SL delay (seconds)
input int      SLDelayMax       = 15;       // Max SL delay
input double   LargeCandleATR   = 2.5;      // Skip large candles (ATR multiplier)

input group "=== TRAILING STOP ==="
input int      TrailActivatePips   = 3000;  // Level 1: Pips to activate BE (BTC scale)
input int      TrailBEPipsMin      = 200;   // Min pips above BE
input int      TrailBEPipsMax      = 350;   // Max pips above BE
input int      TrailLevel2Pips     = 6000;  // Level 2: Pips for stronger lock
input int      TrailLevel2SLMin    = 1000;  // Min pips to lock at L2
input int      TrailLevel2SLMax    = 1500;  // Max pips to lock at L2

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 4;    // Min bars between new trades

input group "=== SESSION FILTER (Optional for crypto) ==="
input bool     UseSessionFilter = false;    // Use session filter (OFF for 24/7)
input int      AsiaStart        = 0;        // Asia session start (UTC)
input int      AsiaEnd          = 8;        // Asia session end
input int      LondonStart      = 8;        // London session start
input int      LondonEnd        = 16;       // London session end
input int      NYStart          = 13;       // NY session start
input int      NYEnd            = 22;       // NY session end

input group "=== VOLATILITY FILTER ==="
input bool     UseVolatilityFilter = true;  // Filter extreme volatility
input int      VolatilityLookback  = 24;    // Bars to check volatility

input group "=== OPCE POSTAVKE ==="
input ulong    MagicNumber      = 778899;   // Unique magic number for BTCUSD
input int      Slippage         = 100;      // Slippage in points (BTC: higher)

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;

TradeData      trades[];
int            tradesCount = 0;
PendingTradeInfo g_pendingTrade;

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
        Print("Error creating indicators!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = MinBarsBetweenTrades + 1;
    ArrayResize(trades, 0);
    tradesCount = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;

    Print("=== CLAMA BTC v1.0 STEALTH MODE initialized ===");
    Print("Symbol: ", _Symbol, " | Point: ", SymbolInfoDouble(_Symbol, SYMBOL_POINT));
    Print("MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("ATR Range: ", MinATR, " - ", MaxATR, " USD");
    Print("*** MULTI-TRADE MODE: Max ", MaxOpenTrades == 0 ? "UNLIMITED" : IntegerToString(MaxOpenTrades), " trades ***");
    Print("*** 24/7 CRYPTO TRADING ", UseSessionFilter ? "with Session Filter" : "ENABLED", " ***");

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
// Crypto trades 24/7 - this is optional but can help avoid low liquidity periods
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    // Crypto markets trade 24/7 - always return true for BTC
    // You can add exchange maintenance windows here if needed
    return true;
}

//+------------------------------------------------------------------+
bool IsBlackoutPeriod()
{
    if(!UseStealthMode) return false;

    // Optional: Avoid specific high-volatility news times
    // For BTC, major moves often happen around US market open/close
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int minutes = dt.hour * 60 + dt.min;

    // Optional blackout around US stock market open (14:30-15:30 UTC)
    // BTC often reacts to stock market
    // return (minutes >= 14*60+30 && minutes < 15*60+30);

    return false;  // No blackout for crypto by default
}

//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    if(!UseStealthMode) return false;
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    double candleRange = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleRange > LargeCandleATR * atr[0]);
}

//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
    if(!UseVolatilityFilter) return true;

    double atr = GetATR();
    if(atr < MinATR || atr > MaxATR) return false;

    // Check for recent extreme moves
    double high[], low[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, VolatilityLookback, high) <= 0) return true;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 1, VolatilityLookback, low) <= 0) return true;

    double maxHigh = high[ArrayMaximum(high)];
    double minLow = low[ArrayMinimum(low)];
    double range = maxHigh - minLow;

    // If recent range is more than 5x ATR, market is too volatile
    if(range > atr * 5.0) return false;

    return true;
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
    if(!UseSessionFilter) return true;  // 24/7 trading if session filter off

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    // Allow trading in any major session
    if(hour >= AsiaStart && hour < AsiaEnd) return true;
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

    if(forBuy)
        return (hist1 > hist2 && hist2 > hist3);
    else
        return (hist1 < hist2 && hist2 < hist3);
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
    double wmaHalf = 0.0, wmaFull = 0.0, sumWeightsHalf = 0.0, sumWeightsFull = 0.0;

    // Current Hull
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

    // Previous Hull
    wmaHalf = 0.0;
    wmaFull = 0.0;
    sumWeightsHalf = 0.0;
    sumWeightsFull = 0.0;

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
    double threshold = GetATR() * 0.05;  // BTC: smaller threshold relative to ATR

    if(diff > threshold) return 1;   // Bullish
    if(diff < -threshold) return -1; // Bearish
    return 0;  // Neutral
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
    if(atr < MinATR || atr > MaxATR) return;

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
        {
            if(IsHistogramGrowing(true))
                buySignal = true;
        }
    }

    if(macdCrossDown)
    {
        if(!UseTrendFilter || (StrictHullFilter ? hullDir == -1 : hullDir <= 0))
        {
            if(IsHistogramGrowing(false))
                sellSignal = true;
        }
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

    // Calculate lot size based on risk
    double slPoints = slDistance / point;
    double lotSize = riskAmount / (slPoints * tickValue / tickSize);

    // Round to lot step
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return NormalizeDouble(lotSize, 8);  // BTC: more decimal places
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
int FindTradeIndex(ulong ticket)
{
    for(int i = 0; i < tradesCount; i++)
        if(trades[i].ticket == ticket) return i;
    return -1;
}

//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double sl, double tp, int bePips, int l2Pips, int slDelay)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = sl;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = slDelay;
    trades[tradesCount].trailLevel = 0;
    trades[tradesCount].randomBEPips = bePips;
    trades[tradesCount].randomLevel2Pips = l2Pips;
    trades[tradesCount].barsInTrade = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
        Print("CLAMA BTC CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
double GetProfitPips(ulong ticket, double entryPrice)
{
    if(!PositionSelectByTicket(ticket)) return 0;

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double currentPrice = (posType == POSITION_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if(posType == POSITION_TYPE_BUY)
        return (currentPrice - entryPrice) / point;
    else
        return (entryPrice - currentPrice) / point;
}

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
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
            SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double profitPips = GetProfitPips(ticket, trades[i].entryPrice);

        // Delayed SL placement (stealth)
        if(UseStealthMode && currentSL == 0 && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                if(trade.PositionModify(ticket, NormalizeDouble(trades[i].intendedSL, digits), 0))
                    Print("CLAMA BTC STEALTH: SL set #", ticket, " @ ", trades[i].intendedSL);
            }
        }

        // Check Stealth TP
        if(trades[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= trades[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= trades[i].stealthTP);
            if(tpHit)
            {
                ClosePosition(ticket, "Stealth TP HIT @ " + DoubleToString(currentPrice, digits));
                continue;
            }
        }

        // Level 2 Trailing (stronger profit lock)
        if(trades[i].trailLevel < 2 && profitPips >= TrailLevel2Pips && currentSL > 0)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = trades[i].entryPrice + trades[i].randomLevel2Pips * point;
            else
                newSL = trades[i].entryPrice - trades[i].randomLevel2Pips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                trades[i].trailLevel = 2;
                Print("CLAMA BTC [", ticket, "] TRAIL L2: SL -> +", trades[i].randomLevel2Pips, " pips ($",
                      DoubleToString(trades[i].randomLevel2Pips * point, 2), ")");
            }
            continue;
        }

        // Level 1 Breakeven
        if(trades[i].trailLevel < 1 && profitPips >= TrailActivatePips && currentSL > 0)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
            else
                newSL = trades[i].entryPrice - trades[i].randomBEPips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                trades[i].trailLevel = 1;
                Print("CLAMA BTC [", ticket, "] TRAIL BE: SL -> BE+", trades[i].randomBEPips, " pips ($",
                      DoubleToString(trades[i].randomBEPips * point, 2), ")");
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
        {
            ClosePosition(trades[i].ticket, "Time exit - " + IntegerToString(trades[i].barsInTrade) + " bars");
        }
    }
}

//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDistance = SLMultiplier * atr;
    double tpDistance = TPMultiplier * atr;

    double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    double tp = (type == ORDER_TYPE_BUY) ? price + tpDistance : price - tpDistance;

    double lots = CalculateLotSize(slDistance);
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
        Print("CLAMA BTC: Trade queued, delay ", g_pendingTrade.delaySeconds, "s, ATR=",
              DoubleToString(atr, 2), ", SL=$", DoubleToString(slDistance, 2));
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp);
    }
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    bool ok;
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int l2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    if(UseStealthMode)
    {
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, 0, 0, "CLAMA BTC") :
            trade.Sell(lot, _Symbol, price, 0, 0, "CLAMA BTC");
    }
    else
    {
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, sl, tp, "CLAMA BTC BUY") :
            trade.Sell(lot, _Symbol, price, sl, tp, "CLAMA BTC SELL");
    }

    if(ok)
    {
        ulong ticket = trade.ResultOrder();

        if(UseStealthMode)
        {
            AddTrade(ticket, price, sl, tp, bePips, l2Pips, slDelay);
            Print("CLAMA BTC STEALTH: Opened #", ticket, ", SL delay ", slDelay, "s");
        }
        else
        {
            AddTrade(ticket, price, sl, 0, bePips, l2Pips, 0);
        }

        Print("CLAMA BTC ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " [", ticket, "]: ",
              DoubleToString(lot, 8), " @ $", DoubleToString(price, digits));
        Print("SL: $", DoubleToString(sl, digits), " | TP: $", DoubleToString(tp, digits));
        Print("Random Trail: BE+", bePips, " pips, L2+", l2Pips, " pips");

        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;

    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                     g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
        g_pendingTrade.active = false;
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ProcessPendingTrade();
    ManageAllPositions();

    if(!IsNewBar()) return;

    CheckTimeExits();
    SyncTradesArray();

    // Filters
    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(!IsGoodSession()) return;
    if(!IsVolatilityOK()) return;
    if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;
    if(g_pendingTrade.active) return;

    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    if(buySignal)
    {
        Print("CLAMA BTC BUY SIGNAL (Hull=", GetHullDirection(), ", ATR=$",
              DoubleToString(GetATR(), 2), ", Open=", CountOpenPositions(), ")");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(sellSignal)
    {
        Print("CLAMA BTC SELL SIGNAL (Hull=", GetHullDirection(), ", ATR=$",
              DoubleToString(GetATR(), 2), ", Open=", CountOpenPositions(), ")");
        QueueTrade(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades_count = TesterStatistics(STAT_TRADES);
    if(trades_count < 30) return 0;  // BTC: fewer trades expected
    return profitFactor * MathSqrt(trades_count);
}
//+------------------------------------------------------------------+
