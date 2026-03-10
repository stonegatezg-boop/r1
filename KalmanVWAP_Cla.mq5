//+------------------------------------------------------------------+
//|                                              KalmanVWAP_Cla.mq5 |
//|                   *** Kalman VWAP Cla v3.0 ***                   |
//|         Fixed: 10.03.2026 (Zagreb) - CLAUDE.md standard         |
//|         - Random SL 988-1054 pips ODMAH                         |
//|         - BE+ at 1000 pips, trail 1000                          |
//|         - Maknut Time Failure Exit                              |
//|         - Radno vrijeme 0-24, Friday 11:00                      |
//|         Kalman Filter + VWAP Fusion Strategy                    |
//|                   + STEALTH EXECUTION (TP/SL)                   |
//|                   + NEWS FILTER & SPREAD FILTER                 |
//|                   + HUMAN-LIKE TRAILING                         |
//|                   Based on BackQuant TradingView Indicator      |
//|                   Optimized for XAUUSD                          |
//|                   Date: 2026-02-24                              |
//+------------------------------------------------------------------+
#property copyright "KalmanVWAP Cla v3.0 (2026-03-10)"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje tradea + stealth
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;          // Pravi SL (ODMAH postavljen)
    double   stealthTP;           // Interni TP (nikad ne šalje brokeru)
    datetime openTime;
    int      direction;           // 1=LONG, -1=SHORT
    bool     slPlaced;            // Je li SL već postavljen

    // Trailing varijable (CLAUDE.md standard)
    bool     beActivated;         // BE+ aktiviran
    int      randomBEOffset;      // Random 41-46 pips
    double   highestProfit;       // Za trailing
};

//--- Input parameters
input group "=== KALMAN FILTER SETTINGS ==="
input double   ProcessNoise      = 0.02;    // Process Noise (Gold: 0.02)
input double   MeasurementNoise  = 5.0;     // Measurement Noise (Gold: 5.0)
input int      FilterOrder       = 5;       // Filter Order (parallel states)
input ENUM_APPLIED_PRICE PriceSource = PRICE_CLOSE; // Price Source

input group "=== VWAP SETTINGS ==="
input int      VWAP_Length       = 50;      // Rolling VWAP Length
input double   VWAP_Weight       = 0.35;    // VWAP Weight (0=price only, 1=VWAP only)

input group "=== SIGNAL SETTINGS ==="
input bool     UseSlopeSignal    = true;    // Signal na slope promjenu
input bool     UseCrossoverSignal = true;   // Signal na price crossover
input bool     RequireCandleConfirm = true; // Zahtijevaj bull/bear svijeću

input group "=== TRADE MANAGEMENT ==="
input double   RiskRewardRatio   = 1.5;     // Risk:Reward Ratio
input double   RiskPercent       = 1.0;     // Risk % od Balance-a
input int      MaxOpenTrades     = 3;       // Max otvorenih pozicija

input group "=== RANDOM SL (CLAUDE.md) ==="
input int      InitialSL_Min     = 988;     // SL min pips (random)
input int      InitialSL_Max     = 1054;    // SL max pips (random)

// STEALTH: SL ODMAH, TP stealth (nikad ne šalje brokeru)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR    = 3.0;     // Filter svijeća > X * ATR
input int      ATR_Period        = 14;      // ATR Period

input group "=== TRAILING STOP (CLAUDE.md STANDARD) ==="
input int      TrailingStartBE   = 1000;    // BE+ aktivacija (pips)
input int      BEOffset_Min      = 41;      // BE+ offset min pips
input int      BEOffset_Max      = 46;      // BE+ offset max pips
input int      TrailingDistance  = 1000;    // Trailing udaljenost (pips)

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter     = true;    // Koristi News Filter
input int      NewsImportance    = 2;       // Min važnost (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore = 30;      // Minuta prije vijesti
input int      NewsMinutesAfter  = 30;      // Minuta nakon vijesti

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter   = true;    // Koristi Spread Filter
input int      MaxSpreadPoints   = 50;      // Max spread u points

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber       = 667788;  // Magic Number
input int      Slippage          = 30;      // Slippage (points)

//--- Global variables
CTrade         trade;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
TradeData      trades[];
int            tradesCount = 0;

// Kalman Filter varijable
double         stateEstimate[];      // N parallel states
double         errorCovariance[];    // N error covariances
double         kalmanVWAP[];         // Historical values for slope detection
bool           kalmanInitialized = false;

// Statistika
int            newsBlockedCount = 0;
int            spreadBlockedCount = 0;
int            largeCandleBlockedCount = 0;
int            totalBuys = 0;
int            totalSells = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

    if(atrHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju ATR indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = 10;
    ArrayResize(trades, 0);
    tradesCount = 0;

    // Initialize Kalman arrays
    ArrayResize(stateEstimate, FilterOrder);
    ArrayResize(errorCovariance, FilterOrder);
    ArrayResize(kalmanVWAP, 5);

    ArrayInitialize(stateEstimate, 0);
    ArrayInitialize(errorCovariance, 100.0);
    ArrayInitialize(kalmanVWAP, 0);
    kalmanInitialized = false;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("=== KALMAN VWAP CLA v3.0 (CLAUDE.md) ===");
    Print("SL: Random ", InitialSL_Min, "-", InitialSL_Max, " pips (ODMAH!)");
    Print("TP: Stealth (R:R 1:", RiskRewardRatio, ")");
    Print("BE+: ", BEOffset_Min, "-", BEOffset_Max, " pips @ ", TrailingStartBE, " pips profit");
    Print("Trail: ", TrailingDistance, " pips distance");
    Print("Vrijeme: 0-24, petak stop 11:00");
    Print("NEWS: ", UseNewsFilter ? "ON" : "OFF", " | SPREAD: ", UseSpreadFilter ? "ON" : "OFF", " (", MaxSpreadPoints, ")");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

    Print("═══════════════════════════════════════════════════");
    Print("      KALMAN VWAP CLA - ZAVRŠNA STATISTIKA");
    Print("═══════════════════════════════════════════════════");
    Print("Total BUY signala: ", totalBuys);
    Print("Total SELL signala: ", totalSells);
    Print("Blokirano zbog NEWS: ", newsBlockedCount);
    Print("Blokirano zbog SPREAD: ", spreadBlockedCount);
    Print("Blokirano zbog LARGE CANDLE: ", largeCandleBlockedCount);
    Print("═══════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Random Range Helper                                               |
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
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
                PrintFormat("⚠ NEWS BLOCK: %s (%s) @ %s", event.name, currency, TimeToString(eventTime));
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

    if(currentSpread > MaxSpreadPoints)
    {
        PrintFormat("⚠ SPREAD BLOCK: %d > %d points", currentSpread, MaxSpreadPoints);
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| LARGE CANDLE FILTER                                               |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    double atr = GetATR(1);
    if(atr <= 0) return false;

    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);
    double candleRange = high - low;

    if(candleRange > LargeCandleATR * atr)
    {
        PrintFormat("⚠ LARGE CANDLE BLOCK: Range %.2f > %.2f (%.1fx ATR)",
                   candleRange, LargeCandleATR * atr, candleRange / atr);
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Helper functions                                                  |
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
//| TRADING WINDOW - 0-24, Friday close 11:00 (CLAUDE.md)            |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Vikend - ne trejdaj
    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));  // Nedjelja od 00:01
    if(dt.day_of_week == 6)
        return false;  // Subota

    // Petak - stop novih trejdova u 11:00
    if(dt.day_of_week == 5)
        return (dt.hour < 11);

    // Pon-Čet: 0-24
    return true;
}

double GetATR(int shift = 1)
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, shift, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

double GetPrice(int shift = 1)
{
    double price = 0;

    switch(PriceSource)
    {
        case PRICE_CLOSE:
            price = iClose(_Symbol, PERIOD_CURRENT, shift);
            break;
        case PRICE_OPEN:
            price = iOpen(_Symbol, PERIOD_CURRENT, shift);
            break;
        case PRICE_HIGH:
            price = iHigh(_Symbol, PERIOD_CURRENT, shift);
            break;
        case PRICE_LOW:
            price = iLow(_Symbol, PERIOD_CURRENT, shift);
            break;
        case PRICE_MEDIAN:
            price = (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift)) / 2.0;
            break;
        case PRICE_TYPICAL:
            price = (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift) + iClose(_Symbol, PERIOD_CURRENT, shift)) / 3.0;
            break;
        case PRICE_WEIGHTED:
            price = (iHigh(_Symbol, PERIOD_CURRENT, shift) + iLow(_Symbol, PERIOD_CURRENT, shift) + 2*iClose(_Symbol, PERIOD_CURRENT, shift)) / 4.0;
            break;
        default:
            price = iClose(_Symbol, PERIOD_CURRENT, shift);
    }

    return price;
}

//+------------------------------------------------------------------+
//| Calculate Rolling VWAP                                            |
//+------------------------------------------------------------------+
double GetRollingVWAP(int shift = 1)
{
    double sumPV = 0;
    double sumV = 0;

    for(int i = shift; i < shift + VWAP_Length; i++)
    {
        double hlc3 = (iHigh(_Symbol, PERIOD_CURRENT, i) +
                       iLow(_Symbol, PERIOD_CURRENT, i) +
                       iClose(_Symbol, PERIOD_CURRENT, i)) / 3.0;

        long volLong = iVolume(_Symbol, PERIOD_CURRENT, i);
        if(volLong <= 0) volLong = 1;  // Avoid division by zero
        double vol = (double)volLong;  // Explicit cast to avoid warning

        sumPV += hlc3 * vol;
        sumV += vol;
    }

    if(sumV <= 0) return GetPrice(shift);

    return sumPV / sumV;
}

//+------------------------------------------------------------------+
//| Initialize Kalman Filter                                          |
//+------------------------------------------------------------------+
void InitializeKalman(double initialValue)
{
    for(int i = 0; i < FilterOrder; i++)
    {
        stateEstimate[i] = initialValue;
        errorCovariance[i] = 1.0;
    }
    kalmanInitialized = true;
}

//+------------------------------------------------------------------+
//| Kalman Filter Update                                              |
//+------------------------------------------------------------------+
double UpdateKalman(double measurement)
{
    if(!kalmanInitialized)
    {
        InitializeKalman(measurement);
        return measurement;
    }

    // Prediction step
    double predictedState[];
    double predictedError[];
    ArrayResize(predictedState, FilterOrder);
    ArrayResize(predictedError, FilterOrder);

    for(int i = 0; i < FilterOrder; i++)
    {
        predictedState[i] = stateEstimate[i];
        predictedError[i] = errorCovariance[i] + ProcessNoise;
    }

    // Update step
    for(int i = 0; i < FilterOrder; i++)
    {
        double p = predictedError[i];
        double kalmanGain = p / (p + MeasurementNoise);
        double xh = predictedState[i];

        stateEstimate[i] = xh + kalmanGain * (measurement - xh);
        errorCovariance[i] = (1.0 - kalmanGain) * p;
    }

    return stateEstimate[0];
}

//+------------------------------------------------------------------+
//| Calculate Kalman VWAP                                             |
//+------------------------------------------------------------------+
double CalculateKalmanVWAP()
{
    // Get price source
    double price = GetPrice(1);

    // Get rolling VWAP
    double vwap = GetRollingVWAP(1);

    // Blend measurement: (1 - weight) * price + weight * VWAP
    double measurement = (1.0 - VWAP_Weight) * price + VWAP_Weight * vwap;

    // Apply Kalman filter
    double kalmanValue = UpdateKalman(measurement);

    // Shift history
    for(int i = 4; i > 0; i--)
    {
        kalmanVWAP[i] = kalmanVWAP[i-1];
    }
    kalmanVWAP[0] = kalmanValue;

    return kalmanValue;
}

//+------------------------------------------------------------------+
//| Check if candle is bullish or bearish                            |
//+------------------------------------------------------------------+
bool IsBullishCandle(int shift = 1)
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    return close > open;
}

bool IsBearishCandle(int shift = 1)
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    return close < open;
}

//+------------------------------------------------------------------+
//| GET SIGNALS                                                       |
//+------------------------------------------------------------------+
void GetSignals(bool &buySignal, bool &sellSignal, double &currentKalman)
{
    buySignal = false;
    sellSignal = false;

    // Calculate current Kalman VWAP
    currentKalman = CalculateKalmanVWAP();

    // Need at least 3 values for slope detection
    if(kalmanVWAP[2] == 0) return;

    double price = GetPrice(1);

    // Slope detection
    bool slopeUp = kalmanVWAP[0] > kalmanVWAP[1];
    bool slopeDn = kalmanVWAP[0] < kalmanVWAP[1];

    // Slope change detection (crossover/crossunder of slope)
    bool slopeWasUp = kalmanVWAP[1] > kalmanVWAP[2];
    bool slopeWasDn = kalmanVWAP[1] < kalmanVWAP[2];

    bool slopeChangeUp = slopeUp && slopeWasDn;  // Slope turned positive
    bool slopeChangeDn = slopeDn && slopeWasUp;  // Slope turned negative

    // Price position relative to Kalman VWAP
    bool priceAbove = price > currentKalman;
    bool priceBelow = price < currentKalman;

    // Price crossover detection
    double prevPrice = GetPrice(2);
    bool priceCrossAbove = price > currentKalman && prevPrice <= kalmanVWAP[1];
    bool priceCrossBelow = price < currentKalman && prevPrice >= kalmanVWAP[1];

    // BUY Signal:
    // 1. Slope turns positive (slope change up) OR
    // 2. Price crosses above Kalman VWAP with positive slope
    // + Bullish candle confirmation (optional)
    bool buyCondition = false;

    if(UseSlopeSignal && slopeChangeUp && priceAbove)
        buyCondition = true;

    if(UseCrossoverSignal && priceCrossAbove && slopeUp)
        buyCondition = true;

    if(buyCondition)
    {
        if(!RequireCandleConfirm || IsBullishCandle(1))
        {
            buySignal = true;
            Print("BUY Signal: Kalman=", DoubleToString(currentKalman, 2),
                  " Price=", DoubleToString(price, 2),
                  " Slope=", slopeUp ? "UP" : "DOWN");
        }
    }

    // SELL Signal:
    // 1. Slope turns negative (slope change down) OR
    // 2. Price crosses below Kalman VWAP with negative slope
    // + Bearish candle confirmation (optional)
    bool sellCondition = false;

    if(UseSlopeSignal && slopeChangeDn && priceBelow)
        sellCondition = true;

    if(UseCrossoverSignal && priceCrossBelow && slopeDn)
        sellCondition = true;

    if(sellCondition)
    {
        if(!RequireCandleConfirm || IsBearishCandle(1))
        {
            sellSignal = true;
            Print("SELL Signal: Kalman=", DoubleToString(currentKalman, 2),
                  " Price=", DoubleToString(price, 2),
                  " Slope=", slopeUp ? "UP" : "DOWN");
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                                |
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
//| Add Trade to tracking                                             |
//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry, double sl, double tp, int dir, int beOffset)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = sl;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].direction = dir;
    trades[tradesCount].slPlaced = true;  // SL ODMAH postavljen
    trades[tradesCount].beActivated = false;
    trades[tradesCount].randomBEOffset = beOffset;
    trades[tradesCount].highestProfit = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
//| Close Position                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
    {
        Print("KVWAP CLOSE [", ticket, "]: ", reason);
    }
}

//+------------------------------------------------------------------+
//| Manage All Positions - STEALTH + TRAILING (CLAUDE.md)            |
//+------------------------------------------------------------------+
void ManageAllPositions()
{
    SyncTradesArray();

    double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice;

        if(trades[i].direction == 1)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        else
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        //=== 1. BACKUP SL CHECK (ako SL nije postavljen) ===
        if(!trades[i].slPlaced && trades[i].intendedSL != 0)
        {
            double sl = NormalizeDouble(trades[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
            {
                trades[i].slPlaced = true;
                Print("KVWAP BACKUP [", ticket, "]: SL postavljen na ", sl);
            }
        }

        //=== 2. CHECK STEALTH TP ===
        if(trades[i].stealthTP > 0)
        {
            bool tpHit = false;
            if(trades[i].direction == 1 && currentPrice >= trades[i].stealthTP)
                tpHit = true;
            else if(trades[i].direction == -1 && currentPrice <= trades[i].stealthTP)
                tpHit = true;

            if(tpHit)
            {
                ClosePosition(ticket, "STEALTH TP HIT @ " + DoubleToString(currentPrice, digits));
                continue;
            }
        }

        //=== 3. CLAUDE.md TRAILING: BE+ at 1000 pips, trail 1000 ===
        double profitPips = 0;
        if(trades[i].direction == 1)
            profitPips = (currentPrice - trades[i].entryPrice) / pipValue;
        else
            profitPips = (trades[i].entryPrice - currentPrice) / pipValue;

        // Update highest profit
        if(profitPips > trades[i].highestProfit)
            trades[i].highestProfit = profitPips;

        // BE+ aktivacija na 1000 pips
        if(!trades[i].beActivated && profitPips >= TrailingStartBE)
        {
            double newSL;
            if(trades[i].direction == 1)
            {
                newSL = trades[i].entryPrice + trades[i].randomBEOffset * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].beActivated = true;
                        Print("KVWAP BE+ [", ticket, "]: SL na BE+", trades[i].randomBEOffset, " pips");
                    }
                }
            }
            else
            {
                newSL = trades[i].entryPrice - trades[i].randomBEOffset * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        trades[i].beActivated = true;
                        Print("KVWAP BE+ [", ticket, "]: SL na BE+", trades[i].randomBEOffset, " pips");
                    }
                }
            }
        }
        // Trailing nakon BE+ - prati na 1000 pips udaljenosti
        else if(trades[i].beActivated && profitPips >= TrailingStartBE)
        {
            double trailPips = trades[i].highestProfit - TrailingDistance;
            if(trailPips > trades[i].randomBEOffset)  // Samo ako je bolji od BE+
            {
                double newSL;
                if(trades[i].direction == 1)
                {
                    newSL = trades[i].entryPrice + trailPips * pipValue;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                            Print("KVWAP TRAIL [", ticket, "]: SL na +", (int)trailPips, " pips (high: ", (int)trades[i].highestProfit, ")");
                    }
                }
                else
                {
                    newSL = trades[i].entryPrice - trailPips * pipValue;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL || currentSL == 0)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                            Print("KVWAP TRAIL [", ticket, "]: SL na +", (int)trailPips, " pips (high: ", (int)trades[i].highestProfit, ")");
                    }
                }
            }
        }
    }
}


//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
void OpenBuy(double kalmanLevel)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // RANDOM SL (CLAUDE.md standard: 988-1054 pips)
    int slPips = RandomRange(InitialSL_Min, InitialSL_Max);
    double slDistance = slPips * pipValue;
    double sl = price - slDistance;
    sl = NormalizeDouble(sl, digits);

    // STEALTH TP based on R:R ratio
    double stealthTP = price + slDistance * RiskRewardRatio;
    stealthTP = NormalizeDouble(stealthTP, digits);

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    // Random BE+ offset (41-46 pips)
    int beOffset = RandomRange(BEOffset_Min, BEOffset_Max);

    // SL ODMAH - postavlja se odmah pri otvaranju trejda
    if(trade.Buy(lots, _Symbol, price, sl, 0, "KVWAP BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, 1, beOffset);

        Print("=== KALMAN VWAP BUY (SL ODMAH) ===");
        Print("Entry: ", price, " | Lots: ", lots);
        Print("SL: ", sl, " (", slPips, " pips ODMAH!)");
        Print("TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ") STEALTH");
        Print("Trail: BE+", beOffset, " @ ", TrailingStartBE, " pips, trail ", TrailingDistance);

        totalBuys++;
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
void OpenSell(double kalmanLevel)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // RANDOM SL (CLAUDE.md standard: 988-1054 pips)
    int slPips = RandomRange(InitialSL_Min, InitialSL_Max);
    double slDistance = slPips * pipValue;
    double sl = price + slDistance;
    sl = NormalizeDouble(sl, digits);

    // STEALTH TP based on R:R ratio
    double stealthTP = price - slDistance * RiskRewardRatio;
    stealthTP = NormalizeDouble(stealthTP, digits);

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    // Random BE+ offset (41-46 pips)
    int beOffset = RandomRange(BEOffset_Min, BEOffset_Max);

    // SL ODMAH - postavlja se odmah pri otvaranju trejda
    if(trade.Sell(lots, _Symbol, price, sl, 0, "KVWAP SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, -1, beOffset);

        Print("=== KALMAN VWAP SELL (SL ODMAH) ===");
        Print("Entry: ", price, " | Lots: ", lots);
        Print("SL: ", sl, " (", slPips, " pips ODMAH!)");
        Print("TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ") STEALTH");
        Print("Trail: BE+", beOffset, " @ ", TrailingStartBE, " pips, trail ", TrailingDistance);

        totalSells++;
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    // UVIJEK upravljaj pozicijama
    ManageAllPositions();

    if(!IsNewBar()) return;

    SyncTradesArray();

    // Trading window check
    if(!IsTradingWindow()) return;

    // Max positions check
    if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;

    // LARGE CANDLE FILTER
    if(IsLargeCandle())
    {
        largeCandleBlockedCount++;
        return;
    }

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

    // SIGNAL LOGIC
    bool buySignal, sellSignal;
    double currentKalman;
    GetSignals(buySignal, sellSignal, currentKalman);

    if(buySignal)
    {
        Print("═══ KALMAN VWAP BUY SIGNAL ═══");
        OpenBuy(currentKalman);
    }
    else if(sellSignal)
    {
        Print("═══ KALMAN VWAP SELL SIGNAL ═══");
        OpenSell(currentKalman);
    }
}

//+------------------------------------------------------------------+
//| Tester function                                                   |
//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades_total = TesterStatistics(STAT_TRADES);
    if(trades_total < 30) return 0;
    return profitFactor * MathSqrt(trades_total);
}
//+------------------------------------------------------------------+
