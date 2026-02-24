//+------------------------------------------------------------------+
//|                                      DynamicFlowRibbons_Cla.mq5 |
//|                *** Dynamic Flow Ribbons Cla v1.0 ***             |
//|       Dynamic Flow Ribbons + RSI Oscillator (50 Level)          |
//|                   + STEALTH EXECUTION (TP/SL)                   |
//|                   + NEWS FILTER & SPREAD FILTER                 |
//|                   + HUMAN-LIKE TRAILING                         |
//|                   Based on BigBeluga TradingView Strategy       |
//|                   Optimized for XAUUSD M5                       |
//|                   Date: 2026-02-24                              |
//+------------------------------------------------------------------+
#property copyright "DynamicFlowRibbons Cla v1.0 (2026-02-24)"
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
input group "=== DYNAMIC FLOW RIBBONS ==="
input double   RibbonFactor     = 3.0;      // Ribbon Length Factor
input int      EMA_Period       = 15;       // EMA Period za ribbon
input int      DistanceSMA      = 200;      // SMA period za distance izračun

input group "=== OSCILLATOR FILTER ==="
input ENUM_APPLIED_PRICE OscPrice = PRICE_CLOSE;  // Oscillator Price
input int      RSI_Period       = 14;       // RSI Period
input int      OscLevel         = 50;       // Oscillator Level (50)

input group "=== SIGNAL POTVRDA ==="
input bool     RequireCandleConfirm = true; // Zahtijevaj bull/bear svijeću

input group "=== TRADE MANAGEMENT ==="
input double   RiskRewardRatio  = 1.5;      // Risk:Reward Ratio (1:1.5)
input double   RiskPercent      = 1.0;      // Risk % od Balance-a
input int      MaxOpenTrades    = 3;        // Max otvorenih pozicija
input int      MaxBarsInTrade   = 100;      // Max barova u tradeu

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin       = 7;        // Min delay za SL (sekunde)
input int      SLDelayMax       = 13;       // Max delay za SL (sekunde)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR   = 3.0;      // Filter svijeća > X * ATR
input int      ATR_Period       = 14;       // ATR Period

input group "=== TRAILING STOP (HUMAN-LIKE) ==="
input int      TrailActivatePips   = 500;   // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin      = 38;    // BE + min pips
input int      TrailBEPipsMax      = 43;    // BE + max pips

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter       = true;  // Koristi News Filter
input int      NewsImportance      = 2;     // Min važnost (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore   = 30;    // Minuta prije vijesti
input int      NewsMinutesAfter    = 30;    // Minuta nakon vijesti

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter     = true;  // Koristi Spread Filter
input int      MaxSpreadPoints     = 50;    // Max spread u points

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 556677;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            rsiHandle;
int            atrHandle;
int            emaHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
TradeData      trades[];
int            tradesCount = 0;

// Dynamic Flow Ribbons varijable
double         ribbonUpperBand[];
double         ribbonLowerBand[];
double         ribbonLine[];
int            ribbonDirection[];  // 1=DOWN (bearish), -1=UP (bullish)

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

    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, OscPrice);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_TYPICAL);

    if(rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = 10;
    ArrayResize(trades, 0);
    tradesCount = 0;

    // Ribbon arrays
    ArrayResize(ribbonUpperBand, 3);
    ArrayResize(ribbonLowerBand, 3);
    ArrayResize(ribbonLine, 3);
    ArrayResize(ribbonDirection, 3);
    ArrayInitialize(ribbonUpperBand, 0);
    ArrayInitialize(ribbonLowerBand, 0);
    ArrayInitialize(ribbonLine, 0);
    ArrayInitialize(ribbonDirection, 1);

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     DYNAMIC FLOW RIBBONS CLA v1.0 - STEALTH EDITION          ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ Ribbons: Factor=", RibbonFactor, " EMA=", EMA_Period, " Dist=", DistanceSMA);
    Print("║ Oscillator: RSI(", RSI_Period, ") Level=", OscLevel);
    Print("║ R:R = 1:", RiskRewardRatio);
    Print("║ STEALTH: SL delay ", SLDelayMin, "-", SLDelayMax, "s | TP hidden");
    Print("║ TRAILING: ", TrailActivatePips, " pips -> BE+", TrailBEPipsMin, "-", TrailBEPipsMax);
    Print("║ Large Candle Filter: > ", LargeCandleATR, "x ATR");
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
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);

    Print("═══════════════════════════════════════════════════");
    Print("  DYNAMIC FLOW RIBBONS CLA - ZAVRŠNA STATISTIKA");
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

double GetRSI(int shift = 1)
{
    double rsiBuffer[];
    ArraySetAsSeries(rsiBuffer, true);
    if(CopyBuffer(rsiHandle, 0, shift, 1, rsiBuffer) <= 0) return 50;
    return rsiBuffer[0];
}

double GetEMA(int shift = 1)
{
    double emaBuffer[];
    ArraySetAsSeries(emaBuffer, true);
    if(CopyBuffer(emaHandle, 0, shift, 1, emaBuffer) <= 0) return 0;
    return emaBuffer[0];
}

//+------------------------------------------------------------------+
//| Calculate Distance (SMA of High-Low range)                        |
//+------------------------------------------------------------------+
double GetDistance()
{
    double high[], low[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, DistanceSMA + 1, high) <= 0) return 0;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, DistanceSMA + 1, low) <= 0) return 0;

    double sum = 0;
    for(int i = 1; i <= DistanceSMA; i++)
    {
        sum += (high[i] - low[i]);
    }

    return sum / DistanceSMA;
}

//+------------------------------------------------------------------+
//| DYNAMIC FLOW RIBBONS CALCULATION                                  |
//+------------------------------------------------------------------+
void CalculateDynamicFlowRibbons(int &direction, double &upperBand, double &lowerBand, double &trendLine)
{
    double high[], low[], close[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, 10, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, 10, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 10, close) <= 0) return;

    double dist = GetDistance();
    if(dist <= 0) return;

    // Source = HLC3 (typical price)
    double src = (high[1] + low[1] + close[1]) / 3.0;
    double srcPrev = (high[2] + low[2] + close[2]) / 3.0;

    // Get EMA of HLC3
    double ema = GetEMA(1);
    if(ema <= 0) ema = src;

    // Calculate bands
    double newUpperBand = ema + RibbonFactor * dist;
    double newLowerBand = ema - RibbonFactor * dist;

    // Previous values
    double prevUpperBand = ribbonUpperBand[1];
    double prevLowerBand = ribbonLowerBand[1];
    int prevDirection = ribbonDirection[1];

    // Adjust lower band (ratchet up in uptrend)
    if(newLowerBand > prevLowerBand || srcPrev < prevLowerBand)
        lowerBand = newLowerBand;
    else
        lowerBand = prevLowerBand;

    // Adjust upper band (ratchet down in downtrend)
    if(newUpperBand < prevUpperBand || srcPrev > prevUpperBand)
        upperBand = newUpperBand;
    else
        upperBand = prevUpperBand;

    // Determine direction
    if(prevDirection == 1)  // Was bearish
    {
        if(src > prevUpperBand)
            direction = -1;  // Switch to bullish
        else
            direction = 1;   // Stay bearish
    }
    else  // Was bullish
    {
        if(src < prevLowerBand)
            direction = 1;   // Switch to bearish
        else
            direction = -1;  // Stay bullish
    }

    // Trend line is upper band if bearish, lower band if bullish
    trendLine = (direction == 1) ? upperBand : lowerBand;

    // Shift arrays
    ribbonUpperBand[2] = ribbonUpperBand[1];
    ribbonUpperBand[1] = ribbonUpperBand[0];
    ribbonUpperBand[0] = upperBand;

    ribbonLowerBand[2] = ribbonLowerBand[1];
    ribbonLowerBand[1] = ribbonLowerBand[0];
    ribbonLowerBand[0] = lowerBand;

    ribbonLine[2] = ribbonLine[1];
    ribbonLine[1] = ribbonLine[0];
    ribbonLine[0] = trendLine;

    ribbonDirection[2] = ribbonDirection[1];
    ribbonDirection[1] = ribbonDirection[0];
    ribbonDirection[0] = direction;
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
void GetSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;

    // Calculate Dynamic Flow Ribbons
    int direction;
    double upperBand, lowerBand, trendLine;
    CalculateDynamicFlowRibbons(direction, upperBand, lowerBand, trendLine);

    // Check for direction change (signal)
    bool trendChangeUp = (ribbonDirection[0] == -1 && ribbonDirection[1] == 1);   // Bearish to Bullish
    bool trendChangeDn = (ribbonDirection[0] == 1 && ribbonDirection[1] == -1);   // Bullish to Bearish

    // Also check for continuation in direction
    bool isUptrend = (ribbonDirection[0] == -1);  // -1 = bullish (green)
    bool isDowntrend = (ribbonDirection[0] == 1); // 1 = bearish (orange)

    // Get RSI
    double rsi = GetRSI(1);

    // BUY conditions:
    // 1. Dynamic Flow Ribbons = UPTREND (direction == -1)
    // 2. RSI > 50
    // 3. Bullish candle (optional)
    if(isUptrend && rsi > OscLevel)
    {
        if(!RequireCandleConfirm || IsBullishCandle(1))
        {
            // Only signal on direction change or first bar after change
            if(trendChangeUp || (ribbonDirection[1] == -1 && ribbonDirection[2] == 1))
            {
                buySignal = true;
                Print("BUY Signal: Ribbon=UPTREND, RSI=", DoubleToString(rsi, 2));
            }
        }
    }

    // SELL conditions:
    // 1. Dynamic Flow Ribbons = DOWNTREND (direction == 1)
    // 2. RSI < 50
    // 3. Bearish candle (optional)
    if(isDowntrend && rsi < OscLevel)
    {
        if(!RequireCandleConfirm || IsBearishCandle(1))
        {
            // Only signal on direction change or first bar after change
            if(trendChangeDn || (ribbonDirection[1] == 1 && ribbonDirection[2] == -1))
            {
                sellSignal = true;
                Print("SELL Signal: Ribbon=DOWNTREND, RSI=", DoubleToString(rsi, 2));
            }
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
        Print("DFR CLOSE [", ticket, "]: ", reason);
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
                    Print("DFR STEALTH [", ticket, "]: SL postavljen na ", sl, " (delay ", trades[i].slDelaySeconds, "s)");
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

        //=== 3. HUMAN-LIKE TRAILING (500 pips -> BE + random 38-43) ===
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
                            Print("DFR TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips (SL=", newSL, ")");
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
                            Print("DFR TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips (SL=", newSL, ")");
                        }
                    }
                }
            }
        }

        //=== 4. CHECK SL (internal, before broker SL is placed) ===
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
void OpenBuy()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // SL = current market lower level (ribbon lower band or recent low)
    double recentLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    double sl = MathMin(ribbonLowerBand[0], recentLow);

    if(sl <= 0 || sl >= price)
    {
        // Fallback: use ATR-based SL
        double atr = GetATR(1);
        sl = price - 2.0 * atr;
    }

    double slDistance = price - sl;
    if(slDistance <= 0) return;

    // TP based on R:R ratio (1:1.5)
    double stealthTP = price + slDistance * RiskRewardRatio;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Open BEZ SL i TP (stealth mode)
    if(trade.Buy(lots, _Symbol, price, 0, 0, "DFR BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, 1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ DFR STEALTH BUY                              ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips profit");
        Print("╚════════════════════════════════════════════════╝");

        totalBuys++;
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
void OpenSell()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // SL = current market higher level (ribbon upper band or recent high)
    double recentHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double sl = MathMax(ribbonUpperBand[0], recentHigh);

    if(sl <= 0 || sl <= price)
    {
        // Fallback: use ATR-based SL
        double atr = GetATR(1);
        sl = price + 2.0 * atr;
    }

    double slDistance = sl - price;
    if(slDistance <= 0) return;

    // TP based on R:R ratio (1:1.5)
    double stealthTP = price - slDistance * RiskRewardRatio;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Open BEZ SL i TP (stealth mode)
    if(trade.Sell(lots, _Symbol, price, 0, 0, "DFR SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, -1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ DFR STEALTH SELL                             ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ TP: ", stealthTP, " (R:R 1:", RiskRewardRatio, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips profit");
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
    // UVIJEK upravljaj pozicijama (čak i izvan trading window-a)
    ManageAllPositions();

    if(!IsNewBar()) return;

    // Time exit check
    CheckTimeExits();
    SyncTradesArray();

    // Trading window check (samo za NOVE tradeove)
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
    GetSignals(buySignal, sellSignal);

    if(buySignal)
    {
        Print("═══ DFR BUY SIGNAL ═══");
        OpenBuy();
    }
    else if(sellSignal)
    {
        Print("═══ DFR SELL SIGNAL ═══");
        OpenSell();
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
