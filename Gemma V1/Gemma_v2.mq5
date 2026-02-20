//+------------------------------------------------------------------+
//|                                                    Gemma_v2.mq5  |
//|              *** GEMMA AI TRADING EA v2.0 ***                    |
//|              AI-Powered Trading with Claude API                  |
//|              + Stealth Mode v2.0 + Trailing Stop                 |
//|              + Session Filter + Daily DD Protection              |
//|              Date: 2026-02-20                                    |
//+------------------------------------------------------------------+
#property copyright "Gemma v2.0 - AI Trading EA (2026-02-20)"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//--- Trade data structure for position management
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
};

//================ INPUT PARAMETERS =================//

input group "=== AI BRIDGE SETTINGS ==="
input int      InpDecisionWaitSec  = 5;       // Seconds to wait for AI decision
input bool     InpRequireAI        = true;    // Require AI decision (false = use EMA only)

input group "=== RISK MANAGEMENT ==="
input double   InpRiskPercent      = 1.0;     // Risk % per trade
input int      InpAtrPeriod        = 14;      // ATR period
input double   InpSLMultiplier     = 1.5;     // SL = ATR * multiplier
input double   InpTPMultiplier     = 2.5;     // TP = ATR * multiplier
input int      InpMaxSpread        = 20;      // Max spread (points)
input double   InpMaxDailyDD       = 3.0;     // Max daily drawdown %
input int      InpMaxOpenTrades    = 1;       // Max open trades

input group "=== EMA SETTINGS ==="
input int      InpEmaFast          = 9;       // Fast EMA period
input int      InpEmaSlow          = 21;      // Slow EMA period
input int      InpHullPeriod       = 20;      // Hull MA period for trend

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter    = true;    // Use trading session filter
input int      InpSessionStart     = 8;       // Session start hour (broker time)
input int      InpSessionEnd       = 18;      // Session end hour
input bool     UseWeekendPause     = true;    // Pause on weekends
input int      WeekendStartDay     = 5;       // Weekend start (5=Friday)
input int      WeekendStartHour    = 22;      // Friday close hour
input int      WeekendEndDay       = 0;       // Weekend end (0=Sunday)
input int      WeekendEndHour      = 22;      // Sunday open hour

input group "=== STEALTH MODE ==="
input bool     UseStealthMode      = true;    // Enable stealth mode
input int      OpenDelayMin        = 0;       // Min delay before opening (sec)
input int      OpenDelayMax        = 4;       // Max delay before opening
input int      SLDelayMin          = 5;       // Min SL delay (sec)
input int      SLDelayMax          = 12;      // Max SL delay
input double   LargeCandleATR      = 2.5;     // Skip large candles (ATR mult)

input group "=== TRAILING STOP ==="
input bool     UseTrailing         = true;    // Enable trailing stop
input int      TrailActivatePips   = 300;     // Pips to activate BE
input int      TrailBEPipsMin      = 20;      // Min pips above BE
input int      TrailBEPipsMax      = 35;      // Max pips above BE
input int      TrailLevel2Pips     = 600;     // Level 2 activation pips
input int      TrailLevel2SLMin    = 100;     // Min pips to lock at L2
input int      TrailLevel2SLMax    = 150;     // Max pips to lock at L2

input group "=== BLACKOUT PERIODS ==="
input bool     UseBlackout         = true;    // Avoid news/volatile times
input int      BlackoutStart1      = 930;     // Blackout 1 start (HHMM format)
input int      BlackoutEnd1        = 1030;    // Blackout 1 end
input int      BlackoutStart2      = 1430;    // Blackout 2 start (US open)
input int      BlackoutEnd2        = 1530;    // Blackout 2 end

input group "=== GENERAL ==="
input ulong    MagicNumber         = 20260220; // EA Magic Number
input int      Slippage            = 30;      // Max slippage (points)

//================ GLOBAL VARIABLES =================//

int atrHandle      = INVALID_HANDLE;
int emaFastHandle  = INVALID_HANDLE;
int emaSlowHandle  = INVALID_HANDLE;

double g_dailyStartBalance = 0.0;
int    g_currentDay = -1;
bool   g_dailyHardStop = false;

datetime g_lastStateWrite = 0;
bool     g_waitingForDecision = false;

TradeData g_trades[];
int       g_tradesCount = 0;

// Pending trade for stealth delay
struct PendingTrade
{
    bool           active;
    ENUM_ORDER_TYPE type;
    double         lot;
    double         intendedSL;
    double         intendedTP;
    datetime       signalTime;
    int            delaySeconds;
};
PendingTrade g_pendingTrade;

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    // Create indicator handles
    atrHandle     = iATR(_Symbol, _Period, InpAtrPeriod);
    emaFastHandle = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

    if(atrHandle == INVALID_HANDLE || emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicator handles");
        return INIT_FAILED;
    }

    // Setup trade object
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Initialize arrays
    ArrayResize(g_trades, 0);
    g_tradesCount = 0;
    g_pendingTrade.active = false;

    // Initialize random seed
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    // Clear old decision file
    if(FileIsExist("decision.csv"))
        FileDelete("decision.csv");

    Print("==============================================");
    Print("     GEMMA AI TRADING EA v2.0 INITIALIZED");
    Print("==============================================");
    Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(_Period));
    Print("Stealth Mode: ", UseStealthMode ? "ON" : "OFF");
    Print("Trailing Stop: ", UseTrailing ? "ON" : "OFF");
    Print("Session Filter: ", UseSessionFilter ? "ON" : "OFF");
    Print("AI Decision Wait: ", InpDecisionWaitSec, " seconds");
    Print("==============================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle     != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+

int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

double GetATR()
{
    double atr[1];
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) != 1) return 0;
    return atr[0];
}

//+------------------------------------------------------------------+
//| TIME FILTERS                                                      |
//+------------------------------------------------------------------+

bool IsNewBar()
{
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, _Period, 0);
    if(currentBar != lastBar)
    {
        lastBar = currentBar;
        return true;
    }
    return false;
}

bool IsTradingSession()
{
    if(!UseSessionFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Check trading hours
    if(dt.hour < InpSessionStart || dt.hour >= InpSessionEnd)
        return false;

    return true;
}

bool IsWeekendPause()
{
    if(!UseWeekendPause) return false;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Friday after close
    if(dt.day_of_week == WeekendStartDay && dt.hour >= WeekendStartHour)
        return true;

    // Saturday
    if(dt.day_of_week == 6)
        return true;

    // Sunday before open
    if(dt.day_of_week == WeekendEndDay && dt.hour < WeekendEndHour)
        return true;

    return false;
}

bool IsBlackoutPeriod()
{
    if(!UseBlackout) return false;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hhmm = dt.hour * 100 + dt.min;

    // Blackout period 1
    if(hhmm >= BlackoutStart1 && hhmm < BlackoutEnd1)
        return true;

    // Blackout period 2
    if(hhmm >= BlackoutStart2 && hhmm < BlackoutEnd2)
        return true;

    return false;
}

bool IsLargeCandle()
{
    if(!UseStealthMode) return false;

    double atr = GetATR();
    if(atr <= 0) return false;

    double candleRange = iHigh(_Symbol, _Period, 1) - iLow(_Symbol, _Period, 1);
    return (candleRange > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT                                               |
//+------------------------------------------------------------------+

bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
        }
    }
    return false;
}

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

void SyncTradesArray()
{
    for(int i = g_tradesCount - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(g_trades[i].ticket))
        {
            for(int j = i; j < g_tradesCount - 1; j++)
                g_trades[j] = g_trades[j + 1];
            g_tradesCount--;
            ArrayResize(g_trades, g_tradesCount);
        }
    }
}

int FindTradeIndex(ulong ticket)
{
    for(int i = 0; i < g_tradesCount; i++)
        if(g_trades[i].ticket == ticket) return i;
    return -1;
}

void AddTrade(ulong ticket, double entry, double sl, double tp, int bePips, int l2Pips, int slDelay)
{
    ArrayResize(g_trades, g_tradesCount + 1);
    g_trades[g_tradesCount].ticket = ticket;
    g_trades[g_tradesCount].entryPrice = entry;
    g_trades[g_tradesCount].intendedSL = sl;
    g_trades[g_tradesCount].stealthTP = tp;
    g_trades[g_tradesCount].openTime = TimeCurrent();
    g_trades[g_tradesCount].slDelaySeconds = slDelay;
    g_trades[g_tradesCount].trailLevel = 0;
    g_trades[g_tradesCount].randomBEPips = bePips;
    g_trades[g_tradesCount].randomLevel2Pips = l2Pips;
    g_tradesCount++;
}

//+------------------------------------------------------------------+
//| HULL MA TREND                                                     |
//+------------------------------------------------------------------+

int GetHullDirection()
{
    double close[];
    ArraySetAsSeries(close, true);
    int bars = InpHullPeriod * 2 + 5;

    if(CopyClose(_Symbol, _Period, 0, bars, close) <= 0) return 0;

    int halfPeriod = InpHullPeriod / 2;
    double wmaHalf = 0.0, wmaFull = 0.0, sumWeightsHalf = 0.0, sumWeightsFull = 0.0;

    // Current Hull
    for(int i = 0; i < halfPeriod; i++)
    {
        double w = (double)(halfPeriod - i);
        wmaHalf += close[i+1] * w;
        sumWeightsHalf += w;
    }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;

    for(int i = 0; i < InpHullPeriod; i++)
    {
        double w = (double)(InpHullPeriod - i);
        wmaFull += close[i+1] * w;
        sumWeightsFull += w;
    }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;

    double hullCurrent = 2.0 * wmaHalf - wmaFull;

    // Previous Hull
    wmaHalf = 0.0; wmaFull = 0.0;
    sumWeightsHalf = 0.0; sumWeightsFull = 0.0;

    for(int i = 0; i < halfPeriod; i++)
    {
        double w = (double)(halfPeriod - i);
        wmaHalf += close[i+3] * w;
        sumWeightsHalf += w;
    }
    if(sumWeightsHalf > 0) wmaHalf /= sumWeightsHalf;

    for(int i = 0; i < InpHullPeriod; i++)
    {
        double w = (double)(InpHullPeriod - i);
        wmaFull += close[i+3] * w;
        sumWeightsFull += w;
    }
    if(sumWeightsFull > 0) wmaFull /= sumWeightsFull;

    double hullPrev = 2.0 * wmaHalf - wmaFull;

    double diff = hullCurrent - hullPrev;
    double atr = GetATR();
    double threshold = atr * 0.1;

    if(diff > threshold) return 1;   // Bullish
    if(diff < -threshold) return -1; // Bearish
    return 0;
}

//+------------------------------------------------------------------+
//| DAILY DRAWDOWN PROTECTION                                         |
//+------------------------------------------------------------------+

void CheckNewDayReset()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.day_of_year != g_currentDay)
    {
        g_currentDay = dt.day_of_year;
        g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        g_dailyHardStop = false;
        g_waitingForDecision = false;
        Print("=== New trading day: ", dt.day, "/", dt.mon, "/", dt.year, " ===");
        Print("Starting balance: ", DoubleToString(g_dailyStartBalance, 2));
    }

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double dd = ((g_dailyStartBalance - equity) / g_dailyStartBalance) * 100.0;

    if(dd >= InpMaxDailyDD && !g_dailyHardStop)
    {
        g_dailyHardStop = true;
        Print("!!! DAILY HARD STOP: DD ", DoubleToString(dd, 2), "% >= ", InpMaxDailyDD, "% !!!");
    }
}

//+------------------------------------------------------------------+
//| PRE-TRADE FILTERS                                                 |
//+------------------------------------------------------------------+

bool PassesPreTradeFilters()
{
    // Spread check
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > InpMaxSpread)
    {
        Print("FILTER: Spread too high (", spread, " > ", InpMaxSpread, ")");
        return false;
    }

    // Session check
    if(!IsTradingSession())
        return false;

    // Weekend pause
    if(IsWeekendPause())
        return false;

    // Blackout period
    if(IsBlackoutPeriod())
        return false;

    // Large candle
    if(IsLargeCandle())
    {
        Print("FILTER: Large candle detected - skipping");
        return false;
    }

    // Max trades
    if(CountOpenPositions() >= InpMaxOpenTrades)
        return false;

    return true;
}

//+------------------------------------------------------------------+
//| CSV COMMUNICATION                                                 |
//+------------------------------------------------------------------+

void WriteStateCSV()
{
    double atr[1], emaFast[1], emaSlow[1];
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) != 1) return;
    if(CopyBuffer(emaFastHandle, 0, 1, 1, emaFast) != 1) return;
    if(CopyBuffer(emaSlowHandle, 0, 1, 1, emaSlow) != 1) return;

    string emaAlignment = (emaFast[0] > emaSlow[0]) ? "bullish" : "bearish";

    // Hull trend
    int hullDir = GetHullDirection();
    string hullTrend = (hullDir > 0) ? "up" : (hullDir < 0) ? "down" : "neutral";

    // Detect impulse candle
    double candleRange = iHigh(_Symbol, _Period, 1) - iLow(_Symbol, _Period, 1);
    bool impulseCandle = (candleRange > atr[0] * 2.0);

    // Detect momentum exhaustion (small body, large wicks)
    double body = MathAbs(iClose(_Symbol, _Period, 1) - iOpen(_Symbol, _Period, 1));
    bool exhaustion = (body < candleRange * 0.3);

    // Volatility extreme
    bool volExtreme = (atr[0] > GetATR() * 3.0);  // Current ATR vs average

    int file = FileOpen("state.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
    if(file == INVALID_HANDLE)
    {
        Print("ERROR: Cannot open state.csv for writing");
        return;
    }

    // Header row
    FileWrite(file, "close", "atr", "ema_alignment", "hull_trend",
              "impulse_candle", "momentum_exhaustion", "volatility_extreme");

    // Data row
    FileWrite(file,
              DoubleToString(iClose(_Symbol, _Period, 1), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
              DoubleToString(atr[0], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
              emaAlignment,
              hullTrend,
              impulseCandle ? "true" : "false",
              exhaustion ? "true" : "false",
              volExtreme ? "true" : "false");

    FileClose(file);
    Print("State written: EMA=", emaAlignment, ", Hull=", hullTrend,
          ", Impulse=", impulseCandle, ", Exhaustion=", exhaustion);
}

string ReadDecisionCSV()
{
    if(!FileIsExist("decision.csv"))
        return "WAITING";

    int file = FileOpen("decision.csv", FILE_READ | FILE_TXT | FILE_ANSI);
    if(file == INVALID_HANDLE)
        return "WAITING";

    string decision = FileReadString(file);
    FileClose(file);

    StringTrimLeft(decision);
    StringTrimRight(decision);
    StringToUpper(decision);

    if(decision == "BUY" || decision == "SELL" || decision == "HOLD")
        return decision;

    return "WAITING";
}

//+------------------------------------------------------------------+
//| FALLBACK DECISION (when AI not available)                         |
//+------------------------------------------------------------------+

string GetFallbackDecision()
{
    double emaFast[1], emaSlow[1];
    if(CopyBuffer(emaFastHandle, 0, 1, 1, emaFast) != 1) return "HOLD";
    if(CopyBuffer(emaSlowHandle, 0, 1, 1, emaSlow) != 1) return "HOLD";

    int hullDir = GetHullDirection();

    // Simple EMA + Hull logic
    if(emaFast[0] > emaSlow[0] && hullDir >= 0)
        return "BUY";
    if(emaFast[0] < emaSlow[0] && hullDir <= 0)
        return "SELL";

    return "HOLD";
}

//+------------------------------------------------------------------+
//| LOT SIZE CALCULATION                                              |
//+------------------------------------------------------------------+

double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskMoney = balance * InpRiskPercent / 100.0;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    double slPoints = slDistance / point;
    double lot = riskMoney / (slPoints * tickValue / tickSize);

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));

    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION                                                   |
//+------------------------------------------------------------------+

void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDist = atr * InpSLMultiplier;
    double tpDist = atr * InpTPMultiplier;

    double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
    double tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;

    double lots = CalculateLotSize(slDist);
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
        Print("STEALTH: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp);
    }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int l2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    bool ok;
    if(UseStealthMode)
    {
        // Open without SL/TP
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, 0, 0, "Gemma AI") :
            trade.Sell(lot, _Symbol, price, 0, 0, "Gemma AI");
    }
    else
    {
        ok = (type == ORDER_TYPE_BUY) ?
            trade.Buy(lot, _Symbol, price, sl, tp, "Gemma AI BUY") :
            trade.Sell(lot, _Symbol, price, sl, tp, "Gemma AI SELL");
    }

    if(ok)
    {
        ulong ticket = trade.ResultOrder();

        if(UseStealthMode)
        {
            AddTrade(ticket, price, sl, tp, bePips, l2Pips, slDelay);
            Print("STEALTH: Opened #", ticket, ", SL delay ", slDelay, "s");
        }
        else
        {
            AddTrade(ticket, price, sl, 0, bePips, l2Pips, 0);
        }

        Print("TRADE ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", ticket,
              ": ", lot, " lots @ ", DoubleToString(price, digits));
        Print("SL: ", DoubleToString(sl, digits), " | TP: ", DoubleToString(tp, digits));
    }
    else
    {
        Print("TRADE FAILED: ", GetLastError());
    }
}

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
//| PROFIT PIPS CALCULATION                                           |
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
//| POSITION MANAGEMENT (STEALTH + TRAILING)                          |
//+------------------------------------------------------------------+

void ManageAllPositions()
{
    SyncTradesArray();

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = g_tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = g_trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
            SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double profitPips = GetProfitPips(ticket, g_trades[i].entryPrice);

        // === STEALTH: Delayed SL placement ===
        if(UseStealthMode && currentSL == 0 && g_trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= g_trades[i].openTime + g_trades[i].slDelaySeconds)
            {
                if(trade.PositionModify(ticket, NormalizeDouble(g_trades[i].intendedSL, digits), 0))
                    Print("STEALTH: SL set #", ticket, " @ ", g_trades[i].intendedSL);
            }
        }

        // === STEALTH: Hidden TP check ===
        if(g_trades[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_trades[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_trades[i].stealthTP);
            if(tpHit)
            {
                if(trade.PositionClose(ticket))
                    Print("STEALTH: TP hit #", ticket, " @ ", DoubleToString(currentPrice, digits));
                continue;
            }
        }

        // === TRAILING: Level 2 (strong lock) ===
        if(UseTrailing && g_trades[i].trailLevel < 2 && profitPips >= TrailLevel2Pips && currentSL > 0)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = g_trades[i].entryPrice + g_trades[i].randomLevel2Pips * point;
            else
                newSL = g_trades[i].entryPrice - g_trades[i].randomLevel2Pips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_trades[i].trailLevel = 2;
                Print("TRAIL L2 #", ticket, ": SL -> +", g_trades[i].randomLevel2Pips, " pips");
            }
            continue;
        }

        // === TRAILING: Level 1 (breakeven+) ===
        if(UseTrailing && g_trades[i].trailLevel < 1 && profitPips >= TrailActivatePips && currentSL > 0)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = g_trades[i].entryPrice + g_trades[i].randomBEPips * point;
            else
                newSL = g_trades[i].entryPrice - g_trades[i].randomBEPips * point;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_trades[i].trailLevel = 1;
                Print("TRAIL BE #", ticket, ": SL -> BE+", g_trades[i].randomBEPips, " pips");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                 |
//+------------------------------------------------------------------+

void OnTick()
{
    // Process pending stealth trade
    ProcessPendingTrade();

    // Manage existing positions (stealth SL/TP + trailing)
    ManageAllPositions();

    // Daily reset and DD check
    CheckNewDayReset();
    if(g_dailyHardStop) return;

    // === WAITING FOR AI DECISION ===
    if(g_waitingForDecision)
    {
        if(TimeCurrent() >= g_lastStateWrite + InpDecisionWaitSec)
        {
            string decision = ReadDecisionCSV();

            if(decision == "WAITING")
            {
                // Timeout - use fallback or skip
                if(!InpRequireAI)
                {
                    decision = GetFallbackDecision();
                    Print("AI timeout - using fallback: ", decision);
                }
                else
                {
                    Print("AI timeout - no trade");
                    decision = "HOLD";
                }
            }

            Print("Decision: ", decision);

            if(decision == "BUY")
                QueueTrade(ORDER_TYPE_BUY);
            else if(decision == "SELL")
                QueueTrade(ORDER_TYPE_SELL);

            g_waitingForDecision = false;
            FileDelete("decision.csv");
        }
        return;
    }

    // === NEW BAR CHECK ===
    if(!IsNewBar()) return;

    // === PRE-TRADE FILTERS ===
    if(!PassesPreTradeFilters()) return;
    if(HasOpenPosition()) return;
    if(g_pendingTrade.active) return;

    // === REQUEST AI DECISION ===
    WriteStateCSV();
    g_lastStateWrite = TimeCurrent();
    g_waitingForDecision = true;
    Print("State written - waiting for AI decision...");
}

//+------------------------------------------------------------------+
//| TESTER OPTIMIZATION                                               |
//+------------------------------------------------------------------+

double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades_count = TesterStatistics(STAT_TRADES);
    if(trades_count < 30) return 0;
    return profitFactor * MathSqrt(trades_count);
}
//+------------------------------------------------------------------+
