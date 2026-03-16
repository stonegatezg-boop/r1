//+------------------------------------------------------------------+
//|                                      DynamicFlowRibbons_Cla.mq5 |
//|                *** Dynamic Flow Ribbons Cla v2.2 ***             |
//|       Dynamic Flow Ribbons + RSI Oscillator (50 Level)          |
//|                   + STEALTH EXECUTION (TP only)                 |
//|                   + NEWS FILTER & SPREAD FILTER                 |
//|                   + 3-LEVEL TRAILING + MFE                      |
//|                   Based on BigBeluga TradingView Strategy       |
//|                   Optimized for XAUUSD M5                       |
//|                   Fixed: 04.03.2026 - SL ODMAH, 3-level trail   |
//+------------------------------------------------------------------+
#property copyright "DynamicFlowRibbons Cla v2.2 (2026-03-04)"
#property version   "2.22"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje tradea + stealth
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   stealthTP;           // Interni TP (nikad ne šalje brokeru)
    datetime openTime;
    int      direction;           // 1=LONG, -1=SHORT
    int      barsInTrade;
    int      trailLevel;          // 0=none, 1=L1, 2=L2, 3=L3
    double   maxProfitPips;       // MFE tracking
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

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR   = 3.0;      // Filter svijeća > X * ATR
input int      ATR_Period       = 14;       // ATR Period

input group "=== TRAILING POSTAVKE (3 LEVEL + MFE) ==="
input int      TrailLevel1_Pips = 500;      // Level 1: aktivacija (pips)
input int      TrailLevel1_BE   = 40;       // Level 1: BE + pips
input int      TrailLevel2_Pips = 800;      // Level 2: aktivacija (pips)
input int      TrailLevel2_Lock = 150;      // Level 2: lock profit pips
input int      TrailLevel3_Pips = 1200;     // Level 3: aktivacija (pips)
input int      TrailLevel3_Lock = 200;      // Level 3: lock profit pips
input int      MFE_ActivatePips = 1500;     // MFE trailing aktivacija
input int      MFE_TrailDistance = 500;     // MFE udaljenost od vrha

input group "=== FAILURE EXIT POSTAVKE ==="
input int      EarlyFailurePips = 800;      // Rani izlaz ako gubitak > X pips
input int      TimeFailureMinPips = 20;     // Min profit za ostanak nakon MaxBarsInTrade

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

double         pipValue = 0.01; // XAUUSD: 1 pip = 0.01

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

    // pipValue za XAUUSD
    pipValue = 0.01;
    if(StringFind(_Symbol, "JPY") >= 0) pipValue = 0.01;
    else if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) pipValue = 0.01;
    else if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5) pipValue = 0.0001;

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     DYNAMIC FLOW RIBBONS CLA v2.2 - SL ODMAH                 ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ Ribbons: Factor=", RibbonFactor, " EMA=", EMA_Period, " Dist=", DistanceSMA);
    Print("║ Oscillator: RSI(", RSI_Period, ") Level=", OscLevel);
    Print("║ R:R = 1:", RiskRewardRatio, " | SL: PRAVI SL ODMAH");
    Print("║ Trail L1: ", TrailLevel1_Pips, " pips -> BE+", TrailLevel1_BE);
    Print("║ Trail L2: ", TrailLevel2_Pips, " pips -> Lock+", TrailLevel2_Lock);
    Print("║ Trail L3: ", TrailLevel3_Pips, " pips -> Lock+", TrailLevel3_Lock);
    Print("║ MFE: ", MFE_ActivatePips, " pips -> Trail ", MFE_TrailDistance);
    Print("║ Failure: Early -", EarlyFailurePips, " | Time ", MaxBarsInTrade, " bars <", TimeFailureMinPips, " pips");
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
void AddTrade(ulong ticket, double entry, double tp, int dir)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].direction = dir;
    trades[tradesCount].barsInTrade = 0;
    trades[tradesCount].trailLevel = 0;
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
        Print("DFR CLOSE [", ticket, "]: ", reason);
    }
}

//+------------------------------------------------------------------+
//| Get Profit in Pips                                                |
//+------------------------------------------------------------------+
double GetProfitPips(ulong ticket, double entryPrice, int dir)
{
    if(!PositionSelectByTicket(ticket)) return 0;

    double currentPrice;

    if(dir == 1)
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
//| Manage All Positions - 3 LEVEL TRAILING + MFE                     |
//+------------------------------------------------------------------+
void ManageAllPositions()
{
    SyncTradesArray();

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

        double profitPips = GetProfitPips(ticket, trades[i].entryPrice, trades[i].direction);

        // Update MFE
        if(profitPips > trades[i].maxProfitPips)
            trades[i].maxProfitPips = profitPips;

        //=== 0. EARLY FAILURE EXIT ===
        if(profitPips <= -EarlyFailurePips)
        {
            ClosePosition(ticket, "EARLY FAILURE @ " + DoubleToString(profitPips, 0) + " pips");
            continue;
        }

        //=== 1. CHECK STEALTH TP ===
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

        //=== 2. 3-LEVEL TRAILING + MFE ===
        if(currentSL > 0)
        {
            double newSL = currentSL;
            bool shouldModify = false;

            // Level 1: 500 pips -> BE + 40 pips
            if(trades[i].trailLevel < 1 && profitPips >= TrailLevel1_Pips)
            {
                if(trades[i].direction == 1)
                    newSL = trades[i].entryPrice + TrailLevel1_BE * pipValue;
                else
                    newSL = trades[i].entryPrice - TrailLevel1_BE * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (trades[i].direction == 1 && newSL > currentSL) ||
                              (trades[i].direction == -1 && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    trades[i].trailLevel = 1;
                    Print("DFR Trail L1 #", ticket, ": BE+", TrailLevel1_BE, " pips");
                }
            }

            // Level 2: 800 pips -> Lock 150 pips
            if(trades[i].trailLevel < 2 && profitPips >= TrailLevel2_Pips)
            {
                if(trades[i].direction == 1)
                    newSL = trades[i].entryPrice + TrailLevel2_Lock * pipValue;
                else
                    newSL = trades[i].entryPrice - TrailLevel2_Lock * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (trades[i].direction == 1 && newSL > currentSL) ||
                              (trades[i].direction == -1 && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    trades[i].trailLevel = 2;
                    Print("DFR Trail L2 #", ticket, ": Lock+", TrailLevel2_Lock, " pips");
                }
            }

            // Level 3: 1200 pips -> Lock 200 pips
            if(trades[i].trailLevel < 3 && profitPips >= TrailLevel3_Pips)
            {
                if(trades[i].direction == 1)
                    newSL = trades[i].entryPrice + TrailLevel3_Lock * pipValue;
                else
                    newSL = trades[i].entryPrice - TrailLevel3_Lock * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (trades[i].direction == 1 && newSL > currentSL) ||
                              (trades[i].direction == -1 && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    trades[i].trailLevel = 3;
                    Print("DFR Trail L3 #", ticket, ": Lock+", TrailLevel3_Lock, " pips");
                }
            }

            // MFE Trailing: aktivacija 1500 pips, trail 500 pips od vrha
            if(trades[i].maxProfitPips >= MFE_ActivatePips)
            {
                double mfeSL;
                if(trades[i].direction == 1)
                    mfeSL = trades[i].entryPrice + (trades[i].maxProfitPips - MFE_TrailDistance) * pipValue;
                else
                    mfeSL = trades[i].entryPrice - (trades[i].maxProfitPips - MFE_TrailDistance) * pipValue;

                mfeSL = NormalizeDouble(mfeSL, digits);
                shouldModify = (trades[i].direction == 1 && mfeSL > currentSL) ||
                              (trades[i].direction == -1 && mfeSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, mfeSL, 0))
                {
                    Print("DFR MFE Trail #", ticket, ": Lock MFE-", MFE_TrailDistance, " (MFE: ", DoubleToString(trades[i].maxProfitPips, 0), " pips)");
                }
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
            double profitPips = GetProfitPips(trades[i].ticket, trades[i].entryPrice, trades[i].direction);

            // Time failure: ako je profit manji od minimuma
            if(profitPips < TimeFailureMinPips)
            {
                ClosePosition(trades[i].ticket, "TIME EXIT - " + IntegerToString(trades[i].barsInTrade) + " bars, profit: " + DoubleToString(profitPips, 0) + " pips");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Open BUY - SL ODMAH                                               |
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

    // SL ODMAH - pravi SL se postavlja odmah, TP ostaje stealth (0)
    if(trade.Buy(lots, _Symbol, price, sl, 0, "DFR BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, stealthTP, 1);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ DFR BUY #", ticket, " | SL ODMAH                 ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", DoubleToString(price, digits), " | Lots: ", DoubleToString(lots, 2));
        Print("║ SL: ", DoubleToString(sl, digits), " (PRAVI SL)");
        Print("║ TP: ", DoubleToString(stealthTP, digits), " (stealth R:R 1:", RiskRewardRatio, ")");
        Print("╚════════════════════════════════════════════════╝");

        totalBuys++;
        barsSinceLastTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Open SELL - SL ODMAH                                              |
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

    // SL ODMAH - pravi SL se postavlja odmah, TP ostaje stealth (0)
    if(trade.Sell(lots, _Symbol, price, sl, 0, "DFR SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, stealthTP, -1);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ DFR SELL #", ticket, " | SL ODMAH                ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", DoubleToString(price, digits), " | Lots: ", DoubleToString(lots, 2));
        Print("║ SL: ", DoubleToString(sl, digits), " (PRAVI SL)");
        Print("║ TP: ", DoubleToString(stealthTP, digits), " (stealth R:R 1:", RiskRewardRatio, ")");
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
