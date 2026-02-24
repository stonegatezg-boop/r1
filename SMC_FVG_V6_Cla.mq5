//+------------------------------------------------------------------+
//|                                              SMC_FVG_V6_Cla.mq5 |
//|                   *** SMC FVG V6 - IMPROVED EDITION ***          |
//|         Fair Value Gap Strategy with Full Confirmation          |
//|                   + REJECTION CANDLE CONFIRMATION                |
//|                   + EMA TREND FILTER                             |
//|                   + ATR-BASED STOP LOSS                          |
//|                   + EDGE-OF-ZONE ENTRY                           |
//|                   + STEALTH EXECUTION                            |
//|                   + NEWS & SPREAD FILTER                         |
//|                   Date: 2026-02-24                               |
//+------------------------------------------------------------------+
#property copyright "SMC FVG V6 Cla (2026-02-24)"
#property version   "6.00"
#property strict
#include <Trade\Trade.mqh>

//--- FVG Structure
struct SFVG
{
    datetime timeCreated;
    double   top;           // Upper boundary of gap
    double   bottom;        // Lower boundary of gap
    double   midPoint;      // Middle of the zone
    int      type;          // 1=BULLISH, -1=BEARISH
    double   slPrice;       // Original SL level (will be adjusted)
    bool     active;
    int      touchCount;    // How many times price entered zone
};

//--- Trade tracking structure
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
    bool     slPlaced;
    int      barsInTrade;
};

//--- Input parameters
input group "=== FVG DETECTION ==="
input int      MinFvgPoints     = 150;      // Min FVG veličina (points) - 15 pips
input int      MaxFvgAgeBars    = 30;       // Max starost FVG-a u barovima
input bool     RequireCleanFVG  = true;     // Zahtijevaj čisti FVG (bez prethodnog testa)

input group "=== ENTRY CONFIRMATION ==="
input bool     RequireRejection = true;     // Zahtijevaj rejection candle
input bool     EntryAtEdge      = true;     // Ulaz na rubu zone (ne sredini)
input int      EdgeBuffer       = 30;       // Buffer od ruba zone (points)

input group "=== TREND FILTER (EMA) ==="
input bool     UseTrendFilter   = true;     // Koristi EMA trend filter
input int      EMA_Fast         = 20;       // Fast EMA period
input int      EMA_Slow         = 50;       // Slow EMA period

input group "=== STOP LOSS (ATR-BASED) ==="
input double   SL_ATR_Multi     = 1.5;      // SL = ATR * multiplier
input int      ATR_Period       = 14;       // ATR period
input int      MinSLPoints      = 200;      // Min SL udaljenost (points)

input group "=== TAKE PROFIT ==="
input double   RiskReward       = 2.0;      // R:R ratio za TP

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent      = 1.0;      // Risk % od Balance-a
input int      MaxOpenTrades    = 1;        // Max otvorenih pozicija
input int      MaxBarsInTrade   = 100;      // Max barova u tradeu

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin       = 7;        // Min delay za SL (sekunde)
input int      SLDelayMax       = 13;       // Max delay za SL (sekunde)

input group "=== TRAILING STOP ==="
input int      TrailActivatePips = 500;     // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin    = 38;      // BE + min pips
input int      TrailBEPipsMax    = 43;      // BE + max pips

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR   = 3.0;      // Filter svijeća > X * ATR

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter    = true;     // Koristi News Filter
input int      NewsImportance   = 2;        // Min važnost (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore = 30;      // Minuta prije vijesti
input int      NewsMinutesAfter  = 30;      // Minuta nakon vijesti

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter  = true;     // Koristi Spread Filter
input int      MaxSpreadPoints  = 50;       // Max spread u points

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 778899;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            atrHandle;
int            emaFastHandle;
int            emaSlowHandle;
datetime       lastBarTime;
SFVG           fvgs[];
TradeData      trades[];
int            tradesCount = 0;

// Statistika
int            newsBlockedCount = 0;
int            spreadBlockedCount = 0;
int            largeCandleBlockedCount = 0;
int            noConfirmationCount = 0;
int            trendBlockedCount = 0;
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
    emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

    if(atrHandle == INVALID_HANDLE || emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    ArrayResize(fvgs, 0);
    ArrayResize(trades, 0);
    tradesCount = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║        SMC FVG V6 CLA - IMPROVED EDITION                      ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ FVG Min Size: ", MinFvgPoints, " points (", MinFvgPoints/10, " pips)");
    Print("║ Confirmation: ", RequireRejection ? "Rejection Candle" : "None");
    Print("║ Entry: ", EntryAtEdge ? "Edge of Zone" : "Anywhere in Zone");
    Print("║ Trend Filter: ", UseTrendFilter ? "EMA(" + IntegerToString(EMA_Fast) + "/" + IntegerToString(EMA_Slow) + ")" : "OFF");
    Print("║ SL: ATR x ", SL_ATR_Multi, " (min ", MinSLPoints, " pts)");
    Print("║ R:R = 1:", RiskReward);
    Print("║ STEALTH: SL delay ", SLDelayMin, "-", SLDelayMax, "s | TP hidden");
    Print("║ NEWS FILTER: ", UseNewsFilter ? "ON" : "OFF");
    Print("╚═══════════════════════════════════════════════════════════════╝");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);

    Print("═══════════════════════════════════════════════════");
    Print("        SMC FVG V6 - ZAVRŠNA STATISTIKA");
    Print("═══════════════════════════════════════════════════");
    Print("Total BUY: ", totalBuys, " | Total SELL: ", totalSells);
    Print("Blokirano - NEWS: ", newsBlockedCount);
    Print("Blokirano - SPREAD: ", spreadBlockedCount);
    Print("Blokirano - LARGE CANDLE: ", largeCandleBlockedCount);
    Print("Blokirano - TREND: ", trendBlockedCount);
    Print("Blokirano - NO CONFIRMATION: ", noConfirmationCount);
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
//| LARGE CANDLE FILTER                                               |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    double atr = GetATR(1);
    if(atr <= 0) return false;

    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);
    double candleRange = high - low;

    return (candleRange > LargeCandleATR * atr);
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
        return true;
    }
    return false;
}

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

double GetEMAFast(int shift = 1)
{
    double buffer[];
    ArraySetAsSeries(buffer, true);
    if(CopyBuffer(emaFastHandle, 0, shift, 1, buffer) <= 0) return 0;
    return buffer[0];
}

double GetEMASlow(int shift = 1)
{
    double buffer[];
    ArraySetAsSeries(buffer, true);
    if(CopyBuffer(emaSlowHandle, 0, shift, 1, buffer) <= 0) return 0;
    return buffer[0];
}

//+------------------------------------------------------------------+
//| TREND FILTER - EMA based                                          |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
    if(!UseTrendFilter) return 0;  // No filter, allow all

    double emaFast = GetEMAFast(1);
    double emaSlow = GetEMASlow(1);

    if(emaFast > emaSlow) return 1;   // Uptrend
    if(emaFast < emaSlow) return -1;  // Downtrend

    return 0;  // Neutral
}

//+------------------------------------------------------------------+
//| REJECTION CANDLE DETECTION                                        |
//+------------------------------------------------------------------+
bool IsBullishRejection(double zoneTop, double zoneBottom)
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low = iLow(_Symbol, PERIOD_CURRENT, 1);

    // Bullish rejection: wick into zone, close above zone
    // Low enters zone, close is above zone top or at least above zone middle

    bool wickIntoZone = (low <= zoneTop && low >= zoneBottom);
    bool closeAboveZone = (close > zoneTop) || (close > (zoneTop + zoneBottom) / 2.0);
    bool isBullish = (close > open);

    // Additional: wick should be significant (at least 50% of candle body)
    double body = MathAbs(close - open);
    double lowerWick = MathMin(open, close) - low;

    bool significantWick = (lowerWick >= body * 0.5);

    return (wickIntoZone && closeAboveZone && isBullish && significantWick);
}

bool IsBearishRejection(double zoneTop, double zoneBottom)
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low = iLow(_Symbol, PERIOD_CURRENT, 1);

    // Bearish rejection: wick into zone, close below zone
    // High enters zone, close is below zone bottom or at least below zone middle

    bool wickIntoZone = (high >= zoneBottom && high <= zoneTop);
    bool closeBelowZone = (close < zoneBottom) || (close < (zoneTop + zoneBottom) / 2.0);
    bool isBearish = (close < open);

    // Additional: wick should be significant
    double body = MathAbs(close - open);
    double upperWick = high - MathMax(open, close);

    bool significantWick = (upperWick >= body * 0.5);

    return (wickIntoZone && closeBelowZone && isBearish && significantWick);
}

//+------------------------------------------------------------------+
//| DETECT NEW FVG                                                    |
//+------------------------------------------------------------------+
void DetectNewFVG()
{
    // FVG detection: candles 1, 2, 3 (1 is most recent closed)
    double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low1  = iLow(_Symbol, PERIOD_CURRENT, 1);
    double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double low2  = iLow(_Symbol, PERIOD_CURRENT, 2);
    double high3 = iHigh(_Symbol, PERIOD_CURRENT, 3);
    double low3  = iLow(_Symbol, PERIOD_CURRENT, 3);

    double minGap = MinFvgPoints * _Point;

    // BULLISH FVG: Gap between candle 3 high and candle 1 low
    // Candle 2 is the impulse candle that creates the gap
    if(low1 > high3 && (low1 - high3) >= minGap)
    {
        int size = ArraySize(fvgs);
        ArrayResize(fvgs, size + 1);

        fvgs[size].type = 1;  // BULLISH
        fvgs[size].top = low1;         // Upper boundary (candle 1 low)
        fvgs[size].bottom = high3;     // Lower boundary (candle 3 high)
        fvgs[size].midPoint = (low1 + high3) / 2.0;
        fvgs[size].timeCreated = iTime(_Symbol, PERIOD_CURRENT, 1);
        fvgs[size].active = true;
        fvgs[size].touchCount = 0;

        // SL based on ATR, placed below zone
        double atr = GetATR(1);
        double slDistance = MathMax(atr * SL_ATR_Multi, MinSLPoints * _Point);
        fvgs[size].slPrice = fvgs[size].bottom - slDistance;

        Print("✓ BULLISH FVG detected: ", fvgs[size].bottom, " - ", fvgs[size].top,
              " (", (int)((fvgs[size].top - fvgs[size].bottom) / _Point), " pts)");
    }

    // BEARISH FVG: Gap between candle 3 low and candle 1 high
    else if(high1 < low3 && (low3 - high1) >= minGap)
    {
        int size = ArraySize(fvgs);
        ArrayResize(fvgs, size + 1);

        fvgs[size].type = -1;  // BEARISH
        fvgs[size].top = low3;         // Upper boundary (candle 3 low)
        fvgs[size].bottom = high1;     // Lower boundary (candle 1 high)
        fvgs[size].midPoint = (low3 + high1) / 2.0;
        fvgs[size].timeCreated = iTime(_Symbol, PERIOD_CURRENT, 1);
        fvgs[size].active = true;
        fvgs[size].touchCount = 0;

        // SL based on ATR, placed above zone
        double atr = GetATR(1);
        double slDistance = MathMax(atr * SL_ATR_Multi, MinSLPoints * _Point);
        fvgs[size].slPrice = fvgs[size].top + slDistance;

        Print("✓ BEARISH FVG detected: ", fvgs[size].bottom, " - ", fvgs[size].top,
              " (", (int)((fvgs[size].top - fvgs[size].bottom) / _Point), " pts)");
    }
}

//+------------------------------------------------------------------+
//| CHECK FVG ENTRIES                                                 |
//+------------------------------------------------------------------+
void CheckFVGEntries()
{
    if(!IsTradingWindow()) return;
    if(CountOpenPositions() >= MaxOpenTrades) return;

    // Filters
    if(IsSpreadTooHigh())
    {
        spreadBlockedCount++;
        return;
    }

    if(IsLargeCandle())
    {
        largeCandleBlockedCount++;
        return;
    }

    if(HasActiveNews())
    {
        newsBlockedCount++;
        return;
    }

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);

    // Get trend direction
    int trend = GetTrendDirection();

    for(int i = 0; i < ArraySize(fvgs); i++)
    {
        if(!fvgs[i].active) continue;

        // Check age
        if(currentTime - fvgs[i].timeCreated > MaxFvgAgeBars * PeriodSeconds(PERIOD_CURRENT))
        {
            fvgs[i].active = false;
            continue;
        }

        // BULLISH FVG Entry
        if(fvgs[i].type == 1)
        {
            // Trend filter: only bullish FVG in uptrend
            if(UseTrendFilter && trend == -1)
            {
                trendBlockedCount++;
                continue;
            }

            // Check if price is at edge of zone (or anywhere if EntryAtEdge is false)
            bool priceAtEntry = false;

            if(EntryAtEdge)
            {
                // Entry at bottom edge of zone (better entry)
                priceAtEntry = (ask >= fvgs[i].bottom && ask <= fvgs[i].bottom + EdgeBuffer * _Point);
            }
            else
            {
                // Entry anywhere in zone
                priceAtEntry = (ask >= fvgs[i].bottom && ask <= fvgs[i].top);
            }

            if(priceAtEntry)
            {
                // Check for rejection candle confirmation
                if(RequireRejection)
                {
                    if(!IsBullishRejection(fvgs[i].top, fvgs[i].bottom))
                    {
                        fvgs[i].touchCount++;
                        // Invalidate after too many touches without confirmation
                        if(fvgs[i].touchCount > 3)
                        {
                            fvgs[i].active = false;
                        }
                        noConfirmationCount++;
                        continue;
                    }
                }

                // Execute trade
                ExecuteBuy(fvgs[i].slPrice, fvgs[i].top, fvgs[i].bottom);
                fvgs[i].active = false;
                return;
            }
        }

        // BEARISH FVG Entry
        else if(fvgs[i].type == -1)
        {
            // Trend filter: only bearish FVG in downtrend
            if(UseTrendFilter && trend == 1)
            {
                trendBlockedCount++;
                continue;
            }

            // Check if price is at edge of zone
            bool priceAtEntry = false;

            if(EntryAtEdge)
            {
                // Entry at top edge of zone (better entry)
                priceAtEntry = (bid <= fvgs[i].top && bid >= fvgs[i].top - EdgeBuffer * _Point);
            }
            else
            {
                // Entry anywhere in zone
                priceAtEntry = (bid >= fvgs[i].bottom && bid <= fvgs[i].top);
            }

            if(priceAtEntry)
            {
                // Check for rejection candle confirmation
                if(RequireRejection)
                {
                    if(!IsBearishRejection(fvgs[i].top, fvgs[i].bottom))
                    {
                        fvgs[i].touchCount++;
                        if(fvgs[i].touchCount > 3)
                        {
                            fvgs[i].active = false;
                        }
                        noConfirmationCount++;
                        continue;
                    }
                }

                // Execute trade
                ExecuteSell(fvgs[i].slPrice, fvgs[i].top, fvgs[i].bottom);
                fvgs[i].active = false;
                return;
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
void AddTrade(ulong ticket, double entry, double sl, double tp, int slDelay, int bePips)
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
    trades[tradesCount].slPlaced = false;
    trades[tradesCount].barsInTrade = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
//| Close Position                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
    {
        Print("FVG CLOSE [", ticket, "]: ", reason);
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
//| Execute BUY                                                       |
//+------------------------------------------------------------------+
void ExecuteBuy(double slPrice, double zoneTop, double zoneBottom)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double slDistance = price - slPrice;
    if(slDistance <= 0) return;

    double tp = price + slDistance * RiskReward;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    slPrice = NormalizeDouble(slPrice, digits);
    tp = NormalizeDouble(tp, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Stealth entry (no SL/TP)
    if(trade.Buy(lots, _Symbol, price, 0, 0, "FVG V6 BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, slPrice, tp, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ FVG V6 STEALTH BUY                           ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ FVG Zone: ", zoneBottom, " - ", zoneTop);
        Print("║ SL: ", slPrice, " (delay ", slDelay, "s)");
        Print("║ TP: ", tp, " (R:R 1:", RiskReward, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips");
        Print("╚════════════════════════════════════════════════╝");

        totalBuys++;
    }
}

//+------------------------------------------------------------------+
//| Execute SELL                                                      |
//+------------------------------------------------------------------+
void ExecuteSell(double slPrice, double zoneTop, double zoneBottom)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double slDistance = slPrice - price;
    if(slDistance <= 0) return;

    double tp = price - slDistance * RiskReward;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    slPrice = NormalizeDouble(slPrice, digits);
    tp = NormalizeDouble(tp, digits);

    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Stealth entry (no SL/TP)
    if(trade.Sell(lots, _Symbol, price, 0, 0, "FVG V6 SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, slPrice, tp, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ FVG V6 STEALTH SELL                          ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ FVG Zone: ", zoneBottom, " - ", zoneTop);
        Print("║ SL: ", slPrice, " (delay ", slDelay, "s)");
        Print("║ TP: ", tp, " (R:R 1:", RiskReward, ")");
        Print("║ Trail: BE+", bePips, " pips @ ", TrailActivatePips, " pips");
        Print("╚════════════════════════════════════════════════╝");

        totalSells++;
    }
}

//+------------------------------------------------------------------+
//| Manage Stealth Positions                                          |
//+------------------------------------------------------------------+
void ManageStealthPositions()
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
        double currentPrice;

        if(posType == POSITION_TYPE_BUY)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        else
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        int dir = (posType == POSITION_TYPE_BUY) ? 1 : -1;

        //=== 1. DELAYED SL PLACEMENT ===
        if(!trades[i].slPlaced && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                double sl = NormalizeDouble(trades[i].intendedSL, digits);
                if(trade.PositionModify(ticket, sl, 0))
                {
                    trades[i].slPlaced = true;
                    Print("FVG STEALTH [", ticket, "]: SL postavljen na ", sl);
                }
            }
        }

        //=== 2. CHECK STEALTH TP ===
        if(trades[i].stealthTP > 0)
        {
            bool tpHit = false;
            if(dir == 1 && currentPrice >= trades[i].stealthTP)
                tpHit = true;
            else if(dir == -1 && currentPrice <= trades[i].stealthTP)
                tpHit = true;

            if(tpHit)
            {
                ClosePosition(ticket, "STEALTH TP HIT @ " + DoubleToString(currentPrice, digits));
                continue;
            }
        }

        //=== 3. TRAILING STOP ===
        if(trades[i].slPlaced && trades[i].trailLevel == 0)
        {
            double profitPips = GetProfitPips(ticket, trades[i].entryPrice, dir);

            if(profitPips >= TrailActivatePips * 10)  // Convert to points
            {
                double newSL;
                if(dir == 1)
                {
                    newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("FVG TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips");
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
                            Print("FVG TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips");
                        }
                    }
                }
            }
        }

        //=== 4. INTERNAL SL CHECK (before broker SL is placed) ===
        if(!trades[i].slPlaced)
        {
            double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
            double low = iLow(_Symbol, PERIOD_CURRENT, 0);

            bool slHit = false;
            if(dir == 1 && low <= trades[i].intendedSL)
                slHit = true;
            else if(dir == -1 && high >= trades[i].intendedSL)
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
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    // Always manage positions
    ManageStealthPositions();

    // Check for FVG entries
    CheckFVGEntries();

    // On new bar
    if(IsNewBar())
    {
        CheckTimeExits();
        DetectNewFVG();
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
