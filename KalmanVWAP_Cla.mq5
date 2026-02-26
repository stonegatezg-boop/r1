//+------------------------------------------------------------------+
//|                                              KalmanVWAP_Cla.mq5 |
//|                   *** Kalman VWAP Cla v1.0 ***                   |
//|         Kalman Filter + VWAP Fusion Strategy                    |
//|                   + STEALTH EXECUTION (TP/SL)                   |
//|                   + NEWS FILTER & SPREAD FILTER                 |
//|                   + HUMAN-LIKE TRAILING                         |
//|                   Based on BackQuant TradingView Indicator      |
//|                   Optimized for XAUUSD                          |
//|                   Date: 2026-02-24                              |
//+------------------------------------------------------------------+
#property copyright "KalmanVWAP Cla v1.0 (2026-02-24)"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje tradea + stealth
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;          // Pravi SL (delayed)
    double   stealthTP;           // Interni TP (nikad ne šalje brokeru)
    datetime openTime;
    int      slDelaySeconds;      // Random 7-13s
    int      direction;           // 1=LONG, -1=SHORT
    bool     slPlaced;            // Je li SL već postavljen
    int      barsInTrade;

    // Trailing varijable (per-trade)
    int      trailLevel;          // 0=none, 1=BE activated
    int      randomBEPips;        // Random 38-43 (generira se jednom)
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
input int      MaxBarsInTrade    = 100;     // Max barova u tradeu

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin        = 7;       // Min delay za SL (sekunde)
input int      SLDelayMax        = 13;      // Max delay za SL (sekunde)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR    = 3.0;     // Filter svijeća > X * ATR
input int      ATR_Period        = 14;      // ATR Period

input group "=== TRAILING STOP (HUMAN-LIKE) ==="
input int      TrailActivatePips = 500;     // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin    = 38;      // BE + min pips
input int      TrailBEPipsMax    = 43;      // BE + max pips

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

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║        KALMAN VWAP CLA v1.0 - STEALTH EDITION                 ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ Kalman: ProcessNoise=", ProcessNoise, " MeasurementNoise=", MeasurementNoise);
    Print("║ Filter Order: ", FilterOrder, " | VWAP Length: ", VWAP_Length);
    Print("║ VWAP Weight: ", VWAP_Weight, " | R:R = 1:", RiskRewardRatio);
    Print("║ STEALTH: SL delay ", SLDelayMin, "-", SLDelayMax, "s | TP hidden");
    Print("║ TRAILING: ", TrailActivatePips, " pips -> BE+", TrailBEPipsMin, "-", TrailBEPipsMax);
    Print("║ NEWS FILTER: ", UseNewsFilter ? "ON" : "OFF");
    Print("║ SPREAD FILTER: ", UseSpreadFilter ? "ON" : "OFF", " (Max ", MaxSpreadPoints, ")");
    Print("║ Trading: Sunday 00:01 - Friday 11:30 (Server Time)");
    Print("╚═══════════════════════════════════════════════════════════════╝");

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
//| TRADING WINDOW - Sunday 00:01 to Friday 11:30 (Server Time)      |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
        return true;

    if(dt.day_of_week == 5)
        return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));

    return false;
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
void AddTrade(ulong ticket, double entry, double sl, double tp, int dir, int slDelay, int bePips)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = sl;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = slDelay;
    trades[tradesCount].direction = dir;
    trades[tradesCount].slPlaced = false;
    trades[tradesCount].barsInTrade = 0;
    trades[tradesCount].trailLevel = 0;
    trades[tradesCount].randomBEPips = bePips;
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
//| Get Profit in Pips                                                |
//+------------------------------------------------------------------+
double GetProfitPips(ulong ticket, double entryPrice, int dir)
{
    if(!PositionSelectByTicket(ticket)) return 0;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double currentPrice;

    if(dir == 1)
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (currentPrice - entryPrice) / point;
    }
    else
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        return (entryPrice - currentPrice) / point;
    }
}

//+------------------------------------------------------------------+
//| Manage All Positions - STEALTH + TRAILING                         |
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

        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice;

        if(trades[i].direction == 1)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        else
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        //=== 1. DELAYED SL PLACEMENT (Stealth) ===
        if(!trades[i].slPlaced && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                double sl = NormalizeDouble(trades[i].intendedSL, digits);
                if(trade.PositionModify(ticket, sl, 0))
                {
                    trades[i].slPlaced = true;
                    Print("KVWAP STEALTH [", ticket, "]: SL postavljen na ", sl, " (delay ", trades[i].slDelaySeconds, "s)");
                }
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

        //=== 3. HUMAN-LIKE TRAILING ===
        if(trades[i].slPlaced && trades[i].trailLevel == 0)
        {
            double profitPips = GetProfitPips(ticket, trades[i].entryPrice, trades[i].direction);

            if(profitPips >= TrailActivatePips)
            {
                double newSL;
                if(trades[i].direction == 1)
                {
                    newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("KVWAP TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips");
                        }
                    }
                }
                else
                {
                    newSL = trades[i].entryPrice - trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL || currentSL == 0)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("KVWAP TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips");
                        }
                    }
                }
            }
        }

        //=== 4. CHECK SL (internal) ===
        if(!trades[i].slPlaced)
        {
            double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
            double low = iLow(_Symbol, PERIOD_CURRENT, 0);

            bool slHit = false;
            if(trades[i].direction == 1 && low <= trades[i].intendedSL)
                slHit = true;
            else if(trades[i].direction == -1 && high >= trades[i].intendedSL)
                slHit = true;

            if(slHit)
            {
                ClosePosition(ticket, "STEALTH SL HIT @ " + DoubleToString(trades[i].intendedSL, digits));
                continue;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check Time Exits                                                  |
//+------------------------------------------------------------------+
void CheckTimeExits()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        trades[i].barsInTrade++;
        if(trades[i].barsInTrade >= MaxBarsInTrade)
        {
            ClosePosition(trades[i].ticket, "TIME EXIT - " + IntegerToString(trades[i].barsInTrade) + " bars");
        }
    }
}

//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
void OpenBuy(double kalmanLevel)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // SL just below Kalman VWAP line
    double atr = GetATR(1);
    double sl = kalmanLevel - atr * 0.5;  // Half ATR below Kalman line

    if(sl >= price)
    {
        sl = price - atr;  // Fallback
    }

    double slDistance = price - sl;
    if(slDistance <= 0) return;

    // TP based on R:R ratio
    double stealthTP = price + slDistance * RiskRewardRatio;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    if(trade.Buy(lots, _Symbol, price, 0, 0, "KVWAP BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, 1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ KALMAN VWAP STEALTH BUY                      ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ Kalman VWAP: ", DoubleToString(kalmanLevel, digits));
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips");
        Print("╚════════════════════════════════════════════════╝");

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

    // SL just above Kalman VWAP line
    double atr = GetATR(1);
    double sl = kalmanLevel + atr * 0.5;  // Half ATR above Kalman line

    if(sl <= price)
    {
        sl = price + atr;  // Fallback
    }

    double slDistance = sl - price;
    if(slDistance <= 0) return;

    // TP based on R:R ratio
    double stealthTP = price - slDistance * RiskRewardRatio;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    if(trade.Sell(lots, _Symbol, price, 0, 0, "KVWAP SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, -1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ KALMAN VWAP STEALTH SELL                     ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ Kalman VWAP: ", DoubleToString(kalmanLevel, digits));
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips");
        Print("╚════════════════════════════════════════════════╝");

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

    // Time exit check
    CheckTimeExits();
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
