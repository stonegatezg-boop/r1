//+------------------------------------------------------------------+
//|                                                   CLAMA_M_v2.mq5 |
//|                        *** CLAMA M v2.0 ***                      |
//|                   MACD + Hull MA Trend-Continuation Strategy     |
//|                   + Market Structure + Compression Filter        |
//|                   + Inside Candle + Early/Time Failure Exits     |
//|                   + 3-Level Trailing System                      |
//|                   Created: 04.03.2026 (Zagreb)                   |
//+------------------------------------------------------------------+
#property copyright "CLAMA M v2.0 - Trend Continuation (2026-03-04)"
#property version   "2.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje svakog tradea
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    datetime openTime;
    int      trailLevel;           // 0=none, 1=L1, 2=L2, 3=L3
    int      barsInTrade;
    double   maxProfitPips;        // MFE tracking
};

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 8;        // Fast EMA
input int      SlowEMA          = 17;       // Slow EMA
input int      SignalSMA        = 9;        // Signal SMA

input group "=== TREND FILTER (Hull MA) ==="
input int      HullPeriod       = 20;       // Hull MA Period

input group "=== ATR POSTAVKE ==="
input int      ATRPeriod        = 20;       // ATR Period

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;      // Stop Loss (x ATR) - ODMAH na entry
input double   RiskPercent      = 1.0;      // Risk % od Balance-a
input int      MaxOpenTrades    = 5;        // Max otvorenih tradeova

input group "=== ENTRY FILTERS ==="
input double   LargeCandleATR   = 3.0;      // Large Candle Filter (> 3x ATR)
input double   CompressionATR   = 1.5;      // Compression Filter (< 1.5x ATR)
input int      CompressionBars  = 5;        // Broj barova za kompresiju

input group "=== EARLY/TIME FAILURE ==="
input int      EarlyFailurePips = 800;      // Early failure exit (pips against)
input int      TimeFailureBars  = 3;        // Time failure check (3 bars = 15 min)
input int      TimeFailureMinProfit = 20;   // Min profit za time check (pips)

input group "=== TRAILING STOP ==="
input int      Level1_ActivatePips = 300;   // L1: Aktivacija (pips profit)
input int      Level1_BEPips       = 20;    // L1: BE + pips
input int      Level2_ActivatePips = 700;   // L2: Aktivacija (pips profit)
input int      Level2_LockPips     = 150;   // L2: Lock profit (pips)
input int      Level3_ActivatePips = 1200;  // L3: Aktivacija (pips profit)
input int      Level3_TrailPips    = 200;   // L3: Trail distance (pips)

input group "=== MAX DURATION ==="
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu (~4 sata)

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter       = true;  // Koristi News Filter
input int      NewsImportance      = 2;     // Min važnost (2=Medium, 3=High)
input int      NewsMinutesBefore   = 30;    // Minuta prije vijesti
input int      NewsMinutesAfter    = 30;    // Minuta nakon vijesti

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter     = true;  // Koristi Spread Filter
input int      MaxSpreadPoints     = 50;    // Max spread (points)

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;    // Min barova između tradeova

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 334568;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
TradeData      trades[];
int            tradesCount = 0;

// Swing point struktura
struct SwingPoint { double price; int barIndex; bool isHigh; };
SwingPoint     swingHighs[10];
SwingPoint     swingLows[10];
int            swingHighCount = 0;
int            swingLowCount = 0;

// Statistika filtera
int            newsBlockedCount = 0;
int            spreadBlockedCount = 0;
int            structureBlockedCount = 0;
int            compressionBlockedCount = 0;
int            insideCandleBlockedCount = 0;

// 1 pip XAUUSD = 0.01 = 1 point (za XAUUSD digits=2)
double         pipValue;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
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
    ArrayResize(trades, 0);
    tradesCount = 0;

    // XAUUSD: 1 pip = 0.01
    pipValue = 0.01;

    Print("======================================================");
    Print("     CLAMA M v2.0 - TREND CONTINUATION EDITION        ");
    Print("======================================================");
    Print("MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("SL: ", SLMultiplier, "x ATR (ODMAH na entry)");
    Print("Filters: Structure + Compression + Inside Candle");
    Print("Exit: Early(-", EarlyFailurePips, " pips), Time(", TimeFailureBars, " bars/<", TimeFailureMinProfit, " pips)");
    Print("Trail: L1(+", Level1_ActivatePips, "->BE+", Level1_BEPips, "), L2(+", Level2_ActivatePips, "->+", Level2_LockPips, "), L3(+", Level3_ActivatePips, "->trail ", Level3_TrailPips, ")");
    Print("NEWS: ", UseNewsFilter ? "ON" : "OFF", " | SPREAD: ", UseSpreadFilter ? "ON" : "OFF", " (", MaxSpreadPoints, "pt)");
    Print("Max Trades: ", MaxOpenTrades);
    Print("======================================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

    Print("=== CLAMA M v2 STATISTIKA ===");
    Print("Blokirano NEWS: ", newsBlockedCount);
    Print("Blokirano SPREAD: ", spreadBlockedCount);
    Print("Blokirano STRUCTURE: ", structureBlockedCount);
    Print("Blokirano COMPRESSION: ", compressionBlockedCount);
    Print("Blokirano INSIDE CANDLE: ", insideCandleBlockedCount);
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                       |
//+------------------------------------------------------------------+
bool HasActiveNews()
{
    if(!UseNewsFilter) return false;

    string symbol = _Symbol;
    string currency1 = StringSubstr(symbol, 0, 3);
    string currency2 = StringSubstr(symbol, 3, 3);

    if(HasCurrencyNews(currency1)) return true;
    if(HasCurrencyNews(currency2)) return true;

    return false;
}

bool HasCurrencyNews(string currency)
{
    datetime currentTime = TimeTradeServer();
    datetime checkFrom = currentTime - NewsMinutesBefore * 60;
    datetime checkTo = currentTime + NewsMinutesAfter * 60;

    MqlCalendarValue values[];
    int count = CalendarValueHistory(values, checkFrom, checkTo, NULL, currency);

    if(count <= 0) return false;

    for(int i = 0; i < count; i++)
    {
        MqlCalendarEvent event;
        if(!CalendarEventById(values[i].event_id, event)) continue;

        if(event.importance >= NewsImportance)
        {
            datetime eventTime = values[i].time;
            datetime blockStart = eventTime - NewsMinutesBefore * 60;
            datetime blockEnd = eventTime + NewsMinutesAfter * 60;

            if(currentTime >= blockStart && currentTime <= blockEnd)
            {
                return true;
            }
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| SPREAD FILTER                                                     |
//+------------------------------------------------------------------+
bool IsSpreadTooHigh()
{
    if(!UseSpreadFilter || MaxSpreadPoints <= 0) return false;

    int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (currentSpread > MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Helper functions                                                 |
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
//| Trading Window: 00:05-23:55, block 09:30-11:30, Fri after 11:30  |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    int minutes = dt.hour * 60 + dt.min;

    // Osnovni prozor: 00:05 - 23:55
    if(minutes < 5 || minutes > 1435) return false;

    // Blok 1: 09:30 - 11:30 (570 - 690 minuta)
    if(minutes >= 570 && minutes <= 690) return false;

    // Blok 2: Petak nakon 11:30
    if(dt.day_of_week == 5 && minutes > 690) return false;

    // Nedjelja - od 00:05
    if(dt.day_of_week == 0) return (minutes >= 5);

    return true;
}

//+------------------------------------------------------------------+
//| LARGE CANDLE FILTER                                               |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    double atr = GetATR();
    if(atr <= 0) return false;

    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);

    return ((high - low) > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| GET ATR                                                           |
//+------------------------------------------------------------------+
double GetATR()
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| HULL MA Direction: Hull[0] vs Hull[2]                             |
//+------------------------------------------------------------------+
int GetHullDirection()
{
    double close[];
    ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2 + 10;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close) < bars) return 0;

    int halfPeriod = HullPeriod / 2;
    int sqrtPeriod = (int)MathSqrt(HullPeriod);

    // Izračunaj Hull[0] i Hull[2]
    double hull0 = CalculateHullValue(close, 0, halfPeriod, HullPeriod, sqrtPeriod);
    double hull2 = CalculateHullValue(close, 2, halfPeriod, HullPeriod, sqrtPeriod);

    if(hull0 > hull2) return 1;   // BUY trend
    if(hull0 < hull2) return -1;  // SELL trend
    return 0;
}

double CalculateHullValue(double &close[], int shift, int halfPeriod, int fullPeriod, int sqrtPeriod)
{
    // WMA(halfPeriod)
    double wmaHalf = 0, sumW = 0;
    for(int i = 0; i < halfPeriod; i++)
    {
        double w = (double)(halfPeriod - i);
        wmaHalf += close[shift + i] * w;
        sumW += w;
    }
    if(sumW > 0) wmaHalf /= sumW;

    // WMA(fullPeriod)
    double wmaFull = 0; sumW = 0;
    for(int i = 0; i < fullPeriod; i++)
    {
        double w = (double)(fullPeriod - i);
        wmaFull += close[shift + i] * w;
        sumW += w;
    }
    if(sumW > 0) wmaFull /= sumW;

    // Hull = 2 * WMA(half) - WMA(full)
    return 2.0 * wmaHalf - wmaFull;
}

//+------------------------------------------------------------------+
//| MARKET STRUCTURE FILTER - Swing High/Low analiza                  |
//+------------------------------------------------------------------+
void FindSwingPoints()
{
    double high[], low[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    int barsNeeded = 50;
    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, high) < barsNeeded) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, low) < barsNeeded) return;

    swingHighCount = 0;
    swingLowCount = 0;

    // Tražimo swing točke s 2 bara lijevo i 2 bara desno
    for(int i = 3; i < barsNeeded - 2; i++)
    {
        // Swing High: high[i] > high[i-1], high[i-2] i high[i+1], high[i+2]
        if(high[i] > high[i-1] && high[i] > high[i-2] &&
           high[i] > high[i+1] && high[i] > high[i+2])
        {
            if(swingHighCount < 10)
            {
                swingHighs[swingHighCount].price = high[i];
                swingHighs[swingHighCount].barIndex = i;
                swingHighs[swingHighCount].isHigh = true;
                swingHighCount++;
            }
        }

        // Swing Low: low[i] < low[i-1], low[i-2] i low[i+1], low[i+2]
        if(low[i] < low[i-1] && low[i] < low[i-2] &&
           low[i] < low[i+1] && low[i] < low[i+2])
        {
            if(swingLowCount < 10)
            {
                swingLows[swingLowCount].price = low[i];
                swingLows[swingLowCount].barIndex = i;
                swingLows[swingLowCount].isHigh = false;
                swingLowCount++;
            }
        }
    }
}

bool IsMarketStructureBullish()
{
    if(swingHighCount < 2 || swingLowCount < 2) return false;

    // BUY struktura: zadnji SH > prethodni SH i zadnji SL > prethodni SL
    bool higherHigh = swingHighs[0].price > swingHighs[1].price;
    bool higherLow = swingLows[0].price > swingLows[1].price;

    return (higherHigh && higherLow);
}

bool IsMarketStructureBearish()
{
    if(swingHighCount < 2 || swingLowCount < 2) return false;

    // SELL struktura: zadnji SL < prethodni SL i zadnji SH < prethodni SH
    bool lowerLow = swingLows[0].price < swingLows[1].price;
    bool lowerHigh = swingHighs[0].price < swingHighs[1].price;

    return (lowerLow && lowerHigh);
}

//+------------------------------------------------------------------+
//| COMPRESSION FILTER                                                |
//+------------------------------------------------------------------+
bool IsCompressed()
{
    double high[], low[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, CompressionBars, high) < CompressionBars) return false;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 1, CompressionBars, low) < CompressionBars) return false;

    double highest = high[ArrayMaximum(high, 0, CompressionBars)];
    double lowest = low[ArrayMinimum(low, 0, CompressionBars)];
    double range = highest - lowest;

    double atr = GetATR();
    if(atr <= 0) return false;

    // Kompresija: range < 1.5 * ATR
    return (range < CompressionATR * atr);
}

//+------------------------------------------------------------------+
//| INSIDE CANDLE FILTER                                              |
//+------------------------------------------------------------------+
bool IsInsideCandle()
{
    double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
    double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double low2 = iLow(_Symbol, PERIOD_CURRENT, 2);

    // Inside candle: High[1] <= High[2] i Low[1] >= Low[2]
    return (high1 <= high2 && low1 >= low2);
}

//+------------------------------------------------------------------+
//| DIRECTION CANDLE FILTER                                           |
//+------------------------------------------------------------------+
bool IsBullishCandle()
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    return (close > open);
}

bool IsBearishCandle()
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    return (close < open);
}

//+------------------------------------------------------------------+
//| MACD SIGNAL with Histogram Confirmation                           |
//+------------------------------------------------------------------+
void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;

    if(barsSinceLastTrade < MinBarsBetweenTrades) return;

    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);

    if(CopyBuffer(macdHandle, 0, 0, 4, macdMain) < 4) return;
    if(CopyBuffer(macdHandle, 1, 0, 4, macdSignal) < 4) return;

    // Histogram
    double hist1 = macdMain[1] - macdSignal[1];
    double hist2 = macdMain[2] - macdSignal[2];
    double hist3 = macdMain[3] - macdSignal[3];

    // Crossover
    bool macdCrossUp = (macdMain[1] > macdSignal[1]) && (macdMain[2] < macdSignal[2]);
    bool macdCrossDown = (macdMain[1] < macdSignal[1]) && (macdMain[2] > macdSignal[2]);

    // BUY: crossover up + histogram raste
    if(macdCrossUp && hist1 > hist2 && hist2 > hist3)
    {
        buySignal = true;
    }

    // SELL: crossover down + histogram pada
    if(macdCrossDown && hist1 < hist2 && hist2 < hist3)
    {
        sellSignal = true;
    }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on risk                                  |
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
//| Count Open Positions                                              |
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
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Sync Trades Array                                                 |
//+------------------------------------------------------------------+
void SyncTradesArray()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(trades[i].ticket))
        {
            for(int j = i; j < tradesCount - 1; j++)
            {
                trades[j] = trades[j + 1];
            }
            tradesCount--;
            ArrayResize(trades, tradesCount);
        }
    }
}

//+------------------------------------------------------------------+
//| Add Trade to Array                                                |
//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].trailLevel = 0;
    trades[tradesCount].barsInTrade = 0;
    trades[tradesCount].maxProfitPips = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
//| Close Position                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
    {
        Print("CLAMA M v2 CLOSE [", ticket, "]: ", reason);
    }
}

//+------------------------------------------------------------------+
//| Get Profit in Pips                                                |
//+------------------------------------------------------------------+
double GetProfitPips(ulong ticket, double entryPrice)
{
    if(!PositionSelectByTicket(ticket)) return 0;

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentPrice;

    if(posType == POSITION_TYPE_BUY)
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (currentPrice - entryPrice) / pipValue;
    }
    else
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        return (entryPrice - currentPrice) / pipValue;
    }
}

//+------------------------------------------------------------------+
//| Manage All Positions - Trailing + Exits                           |
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
        double currentSL = PositionGetDouble(POSITION_SL);
        double profitPips = GetProfitPips(ticket, trades[i].entryPrice);

        // Update MFE
        if(profitPips > trades[i].maxProfitPips)
            trades[i].maxProfitPips = profitPips;

        //=== 1. EARLY FAILURE EXIT: -80 pips ===
        if(profitPips <= -EarlyFailurePips)
        {
            ClosePosition(ticket, "Early Failure @ " + DoubleToString(profitPips, 1) + " pips");
            continue;
        }

        //=== 2. LEVEL 3 TRAILING: >= 1200 pips, trail at 200 pips ===
        if(trades[i].trailLevel >= 2 && profitPips >= Level3_ActivatePips)
        {
            double trailSL;
            double currentPrice = (posType == POSITION_TYPE_BUY) ?
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            if(posType == POSITION_TYPE_BUY)
            {
                trailSL = currentPrice - Level3_TrailPips * pipValue;
                trailSL = NormalizeDouble(trailSL, digits);
                if(trailSL > currentSL)
                {
                    if(trade.PositionModify(ticket, trailSL, 0))
                    {
                        trades[i].trailLevel = 3;
                        Print("CLAMA M v2 [", ticket, "] L3 TRAIL: SL -> ", trailSL, " (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
            else
            {
                trailSL = currentPrice + Level3_TrailPips * pipValue;
                trailSL = NormalizeDouble(trailSL, digits);
                if(trailSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, trailSL, 0))
                    {
                        trades[i].trailLevel = 3;
                        Print("CLAMA M v2 [", ticket, "] L3 TRAIL: SL -> ", trailSL, " (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
            continue;
        }

        //=== 3. LEVEL 2: >= 700 pips, lock 150 pips profit ===
        if(trades[i].trailLevel < 2 && profitPips >= Level2_ActivatePips)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
            {
                newSL = trades[i].entryPrice + Level2_LockPips * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].trailLevel = 2;
                        Print("CLAMA M v2 [", ticket, "] L2: Lock +", Level2_LockPips, " pips (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
            else
            {
                newSL = trades[i].entryPrice - Level2_LockPips * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].trailLevel = 2;
                        Print("CLAMA M v2 [", ticket, "] L2: Lock +", Level2_LockPips, " pips (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
            continue;
        }

        //=== 4. LEVEL 1: >= 300 pips, BE + 20 pips ===
        if(trades[i].trailLevel < 1 && profitPips >= Level1_ActivatePips)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
            {
                newSL = trades[i].entryPrice + Level1_BEPips * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].trailLevel = 1;
                        Print("CLAMA M v2 [", ticket, "] L1: BE+", Level1_BEPips, " pips (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
            else
            {
                newSL = trades[i].entryPrice - Level1_BEPips * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].trailLevel = 1;
                        Print("CLAMA M v2 [", ticket, "] L1: BE+", Level1_BEPips, " pips (profit: ", DoubleToString(profitPips, 1), " pips)");
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check Time-based Exits (New Bar)                                  |
//+------------------------------------------------------------------+
void CheckTimeExits()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        trades[i].barsInTrade++;

        double profitPips = GetProfitPips(trades[i].ticket, trades[i].entryPrice);

        //=== TIME FAILURE EXIT: 3 bars (15 min) i profit < 20 pips ===
        if(trades[i].barsInTrade == TimeFailureBars && profitPips < TimeFailureMinProfit)
        {
            ClosePosition(trades[i].ticket, "Time Failure @ " + IntegerToString(trades[i].barsInTrade) + " bars, profit: " + DoubleToString(profitPips, 1) + " pips");
            continue;
        }

        //=== MAX DURATION EXIT: 48 bars (~4 sata) ===
        if(trades[i].barsInTrade >= MaxBarsInTrade)
        {
            ClosePosition(trades[i].ticket, "Max Duration @ " + IntegerToString(trades[i].barsInTrade) + " bars");
        }
    }
}

//+------------------------------------------------------------------+
//| Open Buy                                                          |
//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double slDistance = SLMultiplier * atr;
    double sl = price - slDistance;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    // PRAVI SL ODMAH na entry (prema CLAUDE.md standardu)
    if(trade.Buy(lots, _Symbol, price, sl, 0, "CLAMA_M_v2 BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price);
        Print("CLAMA M v2 BUY [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " (", DoubleToString(slDistance / pipValue, 0), " pips)");
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Open Sell                                                         |
//+------------------------------------------------------------------+
void OpenSell()
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double slDistance = SLMultiplier * atr;
    double sl = price + slDistance;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    // PRAVI SL ODMAH na entry (prema CLAUDE.md standardu)
    if(trade.Sell(lots, _Symbol, price, sl, 0, "CLAMA_M_v2 SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price);
        Print("CLAMA M v2 SELL [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " (", DoubleToString(slDistance / pipValue, 0), " pips)");
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Uvijek upravljaj pozicijama
    ManageAllPositions();

    if(!IsNewBar()) return;

    // Time exit check
    CheckTimeExits();
    SyncTradesArray();

    // Trading window check
    if(!IsTradingWindow()) return;

    // Large candle filter
    if(IsLargeCandle()) return;

    // Max positions check
    if(CountOpenPositions() >= MaxOpenTrades) return;

    //=== FILTERI ===

    // NEWS FILTER
    if(HasActiveNews())
    {
        newsBlockedCount++;
        return;
    }

    // SPREAD FILTER
    if(IsSpreadTooHigh())
    {
        spreadBlockedCount++;
        return;
    }

    // COMPRESSION FILTER - mora biti kompresija
    if(!IsCompressed())
    {
        compressionBlockedCount++;
        return;
    }

    // INSIDE CANDLE FILTER - prethodna svijeca mora biti inside
    if(!IsInsideCandle())
    {
        insideCandleBlockedCount++;
        return;
    }

    // Update swing points za market structure
    FindSwingPoints();

    //=== SIGNAL LOGIC ===
    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    int hullDir = GetHullDirection();

    if(buySignal)
    {
        // Hull trend = BUY
        if(hullDir != 1) return;

        // Market structure = bullish
        if(!IsMarketStructureBullish())
        {
            structureBlockedCount++;
            return;
        }

        // Direction candle = bullish
        if(!IsBullishCandle()) return;

        Print("CLAMA M v2 BUY SIGNAL (Hull=", hullDir, ", Structure=BULL, Compressed, Inside)");
        OpenBuy();
    }
    else if(sellSignal)
    {
        // Hull trend = SELL
        if(hullDir != -1) return;

        // Market structure = bearish
        if(!IsMarketStructureBearish())
        {
            structureBlockedCount++;
            return;
        }

        // Direction candle = bearish
        if(!IsBearishCandle()) return;

        Print("CLAMA M v2 SELL SIGNAL (Hull=", hullDir, ", Structure=BEAR, Compressed, Inside)");
        OpenSell();
    }
}

//+------------------------------------------------------------------+
//| Tester function                                                  |
//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades_count = TesterStatistics(STAT_TRADES);
    if(trades_count < 30) return 0;
    return profitFactor * MathSqrt(trades_count);
}
//+------------------------------------------------------------------+
