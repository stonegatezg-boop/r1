//+------------------------------------------------------------------+
//|                                           Vikas_SQZMOM_Cla.mq5  |
//|                   *** Vikas SQZMOM Cla v1.1 ***                  |
//|         SuperTrend + Squeeze Momentum + GAN Targets + TSL       |
//|                   + STEALTH EXECUTION (TP/SL)                   |
//|                   + NEWS FILTER & SPREAD FILTER                 |
//|                   + HUMAN-LIKE TRAILING                         |
//|                   Based on TradingView Strategy                 |
//|                   Date: 2026-02-24                              |
//+------------------------------------------------------------------+
#property copyright "Vikas SQZMOM Cla v1.1 (2026-02-24)"
#property version   "1.10"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje tradea s više targeta + stealth
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;          // Pravi SL (delayed)
    double   stealthTP;           // Interni TP (nikad ne šalje brokeru)
    double   target1;
    double   target2;
    double   target3;
    double   tsl1Level;           // TSL nakon TARGET1
    double   tsl2Level;           // TSL nakon TARGET2
    datetime openTime;
    int      slDelaySeconds;      // Random 7-13s
    int      direction;           // 1=LONG, -1=SHORT
    bool     slPlaced;            // Je li SL već postavljen
    bool     target1Hit;
    bool     target2Hit;
    bool     target3Hit;
    int      remainingQty;        // 3->2->1->0
    int      barsInTrade;

    // Trailing varijable (per-trade)
    int      trailLevel;          // 0=none, 1=BE activated
    int      randomBEPips;        // Random 38-43 (generira se jednom)
};

//--- Input parameters
input group "=== SUPERTREND POSTAVKE ==="
input int      ATR_Period       = 28;       // ATR Period
input double   ATR_Multiplier   = 5.0;      // ATR Multiplier
input bool     ChangeATRMethod  = true;     // Koristi pravi ATR (ne SMA)

input group "=== SQUEEZE MOMENTUM POSTAVKE ==="
input int      BB_Length        = 20;       // Bollinger Bands Period
input double   BB_MultFactor    = 2.0;      // BB Standardna Devijacija
input int      KC_Length        = 20;       // Keltner Channel Period
input double   KC_MultFactor    = 1.5;      // KC Multiplikator
input bool     UseTrueRange     = true;     // Koristi True Range za KC

input group "=== SIGNAL POTVRDA ==="
input bool     RequireSQZMConfirm = true;   // Zahtijevaj SQZM potvrdu
input bool     RequireBullBearCandle = true; // Zahtijevaj bull/bear svijeću

input group "=== GAN TARGETS ==="
input double   Target1_Multiplier = 1.7;    // Target 1 (x range)
input double   Target2_Multiplier = 2.5;    // Target 2 (x range)
input double   Target3_Multiplier = 3.0;    // Target 3 (x range)
input bool     UseGannLevels    = true;     // Koristi Gann Square of 9

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent      = 1.0;      // Risk % od Balance-a
input int      MaxOpenTrades    = 3;        // Max otvorenih pozicija
input int      MaxBarsInTrade   = 100;      // Max barova u tradeu

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin       = 7;        // Min delay za SL (sekunde)
input int      SLDelayMax       = 13;       // Max delay za SL (sekunde)

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR   = 3.0;      // Filter svijeća > X * ATR

input group "=== TRAILING STOP (HUMAN-LIKE) ==="
input int      TrailActivatePips   = 500;   // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin      = 38;    // BE + min pips
input int      TrailBEPipsMax      = 43;    // BE + max pips

input group "=== TSL SUSTAV (TARGET BASED) ==="
input bool     UseTSL           = true;     // Koristi TSL sustav
// TSL1 = (Entry + TARGET1) / 2 nakon TARGET1
// TSL2 = (TSL1 + TARGET2) / 2 nakon TARGET2

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter       = true;  // Koristi News Filter
input int      NewsImportance      = 2;     // Min važnost (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore   = 30;    // Minuta prije vijesti
input int      NewsMinutesAfter    = 30;    // Minuta nakon vijesti

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter     = true;  // Koristi Spread Filter
input int      MaxSpreadPoints     = 50;    // Max spread u points

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 445566;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
TradeData      trades[];
int            tradesCount = 0;

// SuperTrend varijable
double         superTrendUp[];
double         superTrendDn[];
int            superTrendDir[];  // 1=UP, -1=DOWN

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

    // SuperTrend arrays
    ArrayResize(superTrendUp, 3);
    ArrayResize(superTrendDn, 3);
    ArrayResize(superTrendDir, 3);
    ArrayInitialize(superTrendUp, 0);
    ArrayInitialize(superTrendDn, 0);
    ArrayInitialize(superTrendDir, 1);

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║        VIKAS SQZMOM CLA v1.1 - STEALTH EDITION                ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ SuperTrend: ATR(", ATR_Period, ") x ", ATR_Multiplier);
    Print("║ Squeeze Momentum: BB(", BB_Length, ") + KC(", KC_Length, ")");
    Print("║ Targets: ", Target1_Multiplier, "x / ", Target2_Multiplier, "x / ", Target3_Multiplier, "x range");
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
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

    Print("═══════════════════════════════════════════════════");
    Print("     VIKAS SQZMOM CLA - ZAVRŠNA STATISTIKA");
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
//| NO intraday restrictions - trades all hours within these days    |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);  // Server time

    // Sunday (day 0): from 00:01 onwards
    if(dt.day_of_week == 0)
    {
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));
    }

    // Monday to Thursday (days 1-4): all day allowed
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
    {
        return true;
    }

    // Friday (day 5): until 11:30
    if(dt.day_of_week == 5)
    {
        return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));
    }

    // Saturday: no trading
    return false;
}

double GetATR(int shift = 1)
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, shift, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| SUPERTREND CALCULATION                                            |
//+------------------------------------------------------------------+
void CalculateSuperTrend(int &direction, double &upLine, double &dnLine)
{
    double high[], low[], close[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, ATR_Period + 5, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, ATR_Period + 5, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, ATR_Period + 5, close) <= 0) return;

    double atr = GetATR(1);
    if(atr <= 0) return;

    // Source = HL2 (High + Low) / 2
    double src = (high[1] + low[1]) / 2.0;

    // Calculate bands
    double up = src - ATR_Multiplier * atr;
    double dn = src + ATR_Multiplier * atr;

    // Previous values
    double up1 = superTrendUp[1];
    double dn1 = superTrendDn[1];
    int trend1 = superTrendDir[1];

    // Adjust up band
    if(close[2] > up1)
        up = MathMax(up, up1);

    // Adjust down band
    if(close[2] < dn1)
        dn = MathMin(dn, dn1);

    // Determine trend
    int trend = trend1;
    if(trend1 == -1 && close[1] > dn1)
        trend = 1;
    else if(trend1 == 1 && close[1] < up1)
        trend = -1;

    // Shift arrays
    superTrendUp[2] = superTrendUp[1];
    superTrendUp[1] = superTrendUp[0];
    superTrendUp[0] = up;

    superTrendDn[2] = superTrendDn[1];
    superTrendDn[1] = superTrendDn[0];
    superTrendDn[0] = dn;

    superTrendDir[2] = superTrendDir[1];
    superTrendDir[1] = superTrendDir[0];
    superTrendDir[0] = trend;

    direction = trend;
    upLine = up;
    dnLine = dn;
}

//+------------------------------------------------------------------+
//| SQUEEZE MOMENTUM CALCULATION                                      |
//+------------------------------------------------------------------+
double CalculateSqueezeMomentum(int &momentumDir)
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    int barsNeeded = MathMax(BB_Length, KC_Length) + 5;

    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, close) <= 0) return 0;
    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded, high) <= 0) return 0;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, barsNeeded, low) <= 0) return 0;

    // Calculate Bollinger Bands basis (SMA)
    double sumBB = 0;
    for(int i = 1; i <= BB_Length; i++)
        sumBB += close[i];
    double basisBB = sumBB / BB_Length;

    // Calculate Standard Deviation for BB
    double sumSqDiff = 0;
    for(int i = 1; i <= BB_Length; i++)
    {
        double diff = close[i] - basisBB;
        sumSqDiff += diff * diff;
    }
    double stdev = MathSqrt(sumSqDiff / BB_Length);

    // Calculate Keltner Channel
    double sumKC = 0;
    for(int i = 1; i <= KC_Length; i++)
        sumKC += close[i];
    double maKC = sumKC / KC_Length;

    // Calculate range (True Range or High-Low)
    double sumRange = 0;
    for(int i = 1; i <= KC_Length; i++)
    {
        double range;
        if(UseTrueRange)
        {
            double tr1 = high[i] - low[i];
            double tr2 = MathAbs(high[i] - close[i+1]);
            double tr3 = MathAbs(low[i] - close[i+1]);
            range = MathMax(tr1, MathMax(tr2, tr3));
        }
        else
        {
            range = high[i] - low[i];
        }
        sumRange += range;
    }
    double rangeMA = sumRange / KC_Length;

    // Find highest high and lowest low
    double highestHigh = high[1];
    double lowestLow = low[1];
    for(int i = 1; i <= KC_Length; i++)
    {
        if(high[i] > highestHigh) highestHigh = high[i];
        if(low[i] < lowestLow) lowestLow = low[i];
    }

    double avgHL = (highestHigh + lowestLow) / 2.0;
    double avgAll = (avgHL + maKC) / 2.0;

    // Calculate momentum values
    double vals[2];
    for(int idx = 0; idx < 2; idx++)
    {
        double hh = high[idx+1];
        double ll = low[idx+1];
        for(int j = idx+1; j <= idx + KC_Length && j < barsNeeded; j++)
        {
            if(high[j] > hh) hh = high[j];
            if(low[j] < ll) ll = low[j];
        }
        double avgHLi = (hh + ll) / 2.0;

        double sumClose = 0;
        int count = 0;
        for(int j = idx+1; j <= idx + KC_Length && j < barsNeeded; j++)
        {
            sumClose += close[j];
            count++;
        }
        double smaI = (count > 0) ? sumClose / count : close[idx+1];

        double avgAllI = (avgHLi + smaI) / 2.0;
        vals[idx] = close[idx+1] - avgAllI;
    }

    double val = vals[0];
    double valPrev = vals[1];

    // Determine momentum direction
    if(val > valPrev)
        momentumDir = 1;   // Growing
    else
        momentumDir = -1;  // Falling

    return val;
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
//| GANN SQUARE OF 9 TARGETS                                          |
//+------------------------------------------------------------------+
void CalculateGannTargets(double price, int direction, double &t1, double &t2, double &t3)
{
    if(!UseGannLevels) return;

    double sqrtPrice = MathFloor(MathSqrt(price));

    double upperGann1 = (sqrtPrice + 1) * (sqrtPrice + 1);
    double upperGann2 = (sqrtPrice + 2) * (sqrtPrice + 2);
    double zeroGann = sqrtPrice * sqrtPrice;
    double lowerGann1 = (sqrtPrice - 1) * (sqrtPrice - 1);
    double lowerGann2 = (sqrtPrice - 2) * (sqrtPrice - 2);

    if(direction == 1) // LONG
    {
        if(price > upperGann1 && price < upperGann2)
        {
            t1 = upperGann2;
        }
        else if(price > zeroGann && price < upperGann1)
        {
            t1 = upperGann1;
            t2 = (upperGann1 + upperGann2) / 2.0;
            t3 = upperGann2;
        }
        else if(price > lowerGann1 && price < zeroGann)
        {
            t1 = zeroGann;
            t2 = (zeroGann + upperGann1) / 2.0;
            t3 = upperGann1;
        }
    }
    else // SHORT
    {
        if(price < lowerGann1 && price > lowerGann2)
        {
            t1 = lowerGann2;
        }
        else if(price < zeroGann && price > lowerGann1)
        {
            t1 = lowerGann1;
            t2 = (lowerGann1 + lowerGann2) / 2.0;
            t3 = lowerGann2;
        }
        else if(price < upperGann1 && price > zeroGann)
        {
            t1 = zeroGann;
            t2 = (zeroGann + lowerGann1) / 2.0;
            t3 = lowerGann1;
        }
    }
}

//+------------------------------------------------------------------+
//| GET SIGNALS                                                       |
//+------------------------------------------------------------------+
void GetSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;

    // Calculate SuperTrend
    int direction;
    double upLine, dnLine;
    CalculateSuperTrend(direction, upLine, dnLine);

    // Provjeri promjenu trenda
    bool trendChangeUp = (superTrendDir[0] == 1 && superTrendDir[1] == -1);
    bool trendChangeDn = (superTrendDir[0] == -1 && superTrendDir[1] == 1);

    if(!trendChangeUp && !trendChangeDn) return;

    // Squeeze Momentum potvrda
    if(RequireSQZMConfirm)
    {
        int momentumDir;
        double sqzmVal = CalculateSqueezeMomentum(momentumDir);

        if(trendChangeUp)
        {
            // Za BUY: SQZM mora biti bullish (>0) i rasti
            if(sqzmVal <= 0 || momentumDir != 1)
            {
                Print("BUY blokiran: SQZM=", DoubleToString(sqzmVal, 2), " Dir=", momentumDir);
                return;
            }
        }
        else if(trendChangeDn)
        {
            // Za SELL: SQZM mora biti bearish (<0) i padati
            if(sqzmVal >= 0 || momentumDir != -1)
            {
                Print("SELL blokiran: SQZM=", DoubleToString(sqzmVal, 2), " Dir=", momentumDir);
                return;
            }
        }
    }

    // Candle potvrda
    if(RequireBullBearCandle)
    {
        if(trendChangeUp && !IsBullishCandle(1))
        {
            Print("BUY blokiran: Nije bullish svijeća");
            return;
        }
        if(trendChangeDn && !IsBearishCandle(1))
        {
            Print("SELL blokiran: Nije bearish svijeća");
            return;
        }
    }

    buySignal = trendChangeUp;
    sellSignal = trendChangeDn;
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
void AddTrade(ulong ticket, double entry, double sl, double tp, double t1, double t2, double t3, int dir, int slDelay, int bePips)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = sl;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].target1 = t1;
    trades[tradesCount].target2 = t2;
    trades[tradesCount].target3 = t3;
    trades[tradesCount].tsl1Level = 0;
    trades[tradesCount].tsl2Level = 0;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = slDelay;
    trades[tradesCount].direction = dir;
    trades[tradesCount].slPlaced = false;
    trades[tradesCount].target1Hit = false;
    trades[tradesCount].target2Hit = false;
    trades[tradesCount].target3Hit = false;
    trades[tradesCount].remainingQty = 3;
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
        Print("VIKAS CLOSE [", ticket, "]: ", reason);
    }
}

//+------------------------------------------------------------------+
//| Partial Close Position                                            |
//+------------------------------------------------------------------+
void PartialClose(ulong ticket, double portion, string reason)
{
    if(!PositionSelectByTicket(ticket)) return;

    double volume = PositionGetDouble(POSITION_VOLUME);
    double closeVolume = NormalizeDouble(volume * portion, 2);

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(closeVolume < minLot) closeVolume = minLot;

    if(closeVolume >= volume)
    {
        ClosePosition(ticket, reason);
        return;
    }

    if(trade.PositionClosePartial(ticket, closeVolume))
    {
        Print("VIKAS PARTIAL [", ticket, "]: ", reason, " (", closeVolume, " lots)");
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

    if(dir == 1)  // LONG
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (currentPrice - entryPrice) / point;
    }
    else  // SHORT
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        return (entryPrice - currentPrice) / point;
    }
}

//+------------------------------------------------------------------+
//| Manage All Positions - STEALTH + TSL Logic                        |
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

        double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
        double low = iLow(_Symbol, PERIOD_CURRENT, 0);

        //=== 1. DELAYED SL PLACEMENT (Stealth) ===
        if(!trades[i].slPlaced && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                double sl = NormalizeDouble(trades[i].intendedSL, digits);
                if(trade.PositionModify(ticket, sl, 0))
                {
                    trades[i].slPlaced = true;
                    Print("VIKAS STEALTH [", ticket, "]: SL postavljen na ", sl, " (delay ", trades[i].slDelaySeconds, "s)");
                }
            }
        }

        //=== 2. CHECK STEALTH TP (Target3 or main TP) ===
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
                if(trades[i].direction == 1)  // LONG
                {
                    newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("VIKAS TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips (SL=", newSL, ")");
                        }
                    }
                }
                else  // SHORT
                {
                    newSL = trades[i].entryPrice - trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL || currentSL == 0)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("VIKAS TRAIL [", ticket, "]: BE+", trades[i].randomBEPips, " pips (SL=", newSL, ")");
                        }
                    }
                }
            }
        }

        //=== 4. CHECK TARGET1 ===
        if(!trades[i].target1Hit)
        {
            bool t1Hit = false;
            if(trades[i].direction == 1 && high >= trades[i].target1)
                t1Hit = true;
            else if(trades[i].direction == -1 && low <= trades[i].target1)
                t1Hit = true;

            if(t1Hit)
            {
                trades[i].target1Hit = true;
                trades[i].tsl1Level = (trades[i].entryPrice + trades[i].target1) / 2.0;
                trades[i].remainingQty = 2;

                PartialClose(ticket, 0.33, "TARGET1 HIT @ " + DoubleToString(trades[i].target1, digits));
                Print("✓ TARGET1 HIT! TSL1 = ", DoubleToString(trades[i].tsl1Level, digits));
            }
        }

        //=== 5. CHECK TARGET2 ===
        if(trades[i].target1Hit && !trades[i].target2Hit)
        {
            bool t2Hit = false;
            if(trades[i].direction == 1 && high >= trades[i].target2)
                t2Hit = true;
            else if(trades[i].direction == -1 && low <= trades[i].target2)
                t2Hit = true;

            if(t2Hit)
            {
                trades[i].target2Hit = true;
                trades[i].tsl2Level = (trades[i].tsl1Level + trades[i].target2) / 2.0;
                trades[i].remainingQty = 1;

                PartialClose(ticket, 0.5, "TARGET2 HIT @ " + DoubleToString(trades[i].target2, digits));
                Print("✓ TARGET2 HIT! TSL2 = ", DoubleToString(trades[i].tsl2Level, digits));
            }
        }

        //=== 6. CHECK TARGET3 ===
        if(trades[i].target2Hit && !trades[i].target3Hit)
        {
            bool t3Hit = false;
            if(trades[i].direction == 1 && high >= trades[i].target3)
                t3Hit = true;
            else if(trades[i].direction == -1 && low <= trades[i].target3)
                t3Hit = true;

            if(t3Hit)
            {
                trades[i].target3Hit = true;
                trades[i].remainingQty = 0;
                ClosePosition(ticket, "TARGET3 - FULL PROFIT @ " + DoubleToString(trades[i].target3, digits));
                continue;
            }
        }

        //=== 7. CHECK TSL HITS (if UseTSL) ===
        if(UseTSL)
        {
            // TSL2 check (after TARGET2)
            if(trades[i].target2Hit && trades[i].tsl2Level > 0)
            {
                bool tsl2Hit = false;
                if(trades[i].direction == 1 && low <= trades[i].tsl2Level)
                    tsl2Hit = true;
                else if(trades[i].direction == -1 && high >= trades[i].tsl2Level)
                    tsl2Hit = true;

                if(tsl2Hit)
                {
                    ClosePosition(ticket, "TSL2 HIT @ " + DoubleToString(trades[i].tsl2Level, digits));
                    continue;
                }
            }
            // TSL1 check (after TARGET1, before TARGET2)
            else if(trades[i].target1Hit && !trades[i].target2Hit && trades[i].tsl1Level > 0)
            {
                bool tsl1Hit = false;
                if(trades[i].direction == 1 && low <= trades[i].tsl1Level)
                    tsl1Hit = true;
                else if(trades[i].direction == -1 && high >= trades[i].tsl1Level)
                    tsl1Hit = true;

                if(tsl1Hit)
                {
                    ClosePosition(ticket, "TSL1 HIT @ " + DoubleToString(trades[i].tsl1Level, digits));
                    continue;
                }
            }
        }

        //=== 8. CHECK SL (internal, before broker SL is placed) ===
        if(!trades[i].target1Hit && !trades[i].slPlaced)
        {
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
    double sl = superTrendUp[0];  // SuperTrend UP line as SL

    if(sl <= 0 || sl >= price)
    {
        Print("BUY cancelled: Invalid SL (", sl, ")");
        return;
    }

    double range_val = MathAbs(price - sl);

    // Calculate targets
    double t1 = price + range_val * Target1_Multiplier;
    double t2 = price + range_val * Target2_Multiplier;
    double t3 = price + range_val * Target3_Multiplier;

    // Apply Gann adjustments
    CalculateGannTargets(price, 1, t1, t2, t3);

    // Stealth TP = Target3
    double stealthTP = t3;

    double lots = CalculateLotSize(range_val);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    t1 = NormalizeDouble(t1, digits);
    t2 = NormalizeDouble(t2, digits);
    t3 = NormalizeDouble(t3, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    // Generate random values for this trade
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Open BEZ SL i TP (stealth mode)
    if(trade.Buy(lots, _Symbol, price, 0, 0, "VIKAS BUY"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, t1, t2, t3, 1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ VIKAS STEALTH BUY                            ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
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
    double sl = superTrendDn[0];  // SuperTrend DOWN line as SL

    if(sl <= 0 || sl <= price)
    {
        Print("SELL cancelled: Invalid SL (", sl, ")");
        return;
    }

    double range_val = MathAbs(sl - price);

    // Calculate targets
    double t1 = price - range_val * Target1_Multiplier;
    double t2 = price - range_val * Target2_Multiplier;
    double t3 = price - range_val * Target3_Multiplier;

    // Apply Gann adjustments
    CalculateGannTargets(price, -1, t1, t2, t3);

    // Stealth TP = Target3
    double stealthTP = t3;

    double lots = CalculateLotSize(range_val);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    t1 = NormalizeDouble(t1, digits);
    t2 = NormalizeDouble(t2, digits);
    t3 = NormalizeDouble(t3, digits);
    stealthTP = NormalizeDouble(stealthTP, digits);

    // Generate random values for this trade
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);

    // Open BEZ SL i TP (stealth mode)
    if(trade.Sell(lots, _Symbol, price, 0, 0, "VIKAS SELL"))
    {
        ulong ticket = trade.ResultOrder();
        AddTrade(ticket, price, sl, stealthTP, t1, t2, t3, -1, slDelay, bePips);

        Print("╔════════════════════════════════════════════════╗");
        Print("║ ✓ VIKAS STEALTH SELL                           ║");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", price, " | Lots: ", lots);
        Print("║ SL: ", sl, " (delay ", slDelay, "s)");
        Print("║ T1: ", t1, " | T2: ", t2, " | T3: ", t3);
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
        Print("═══ VIKAS BUY SIGNAL ═══");
        OpenBuy();
    }
    else if(sellSignal)
    {
        Print("═══ VIKAS SELL SIGNAL ═══");
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
