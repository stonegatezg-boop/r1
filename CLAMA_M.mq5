//+------------------------------------------------------------------+
//|                                                      CLAMA_M.mq5 |
//|                        *** CLAMA M v1.0 ***                      |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   + Stealth Execution & Trailing Upgrade         |
//|                   + NEWS FILTER & SPREAD FILTER                  |
//|                   + MULTIPLE TRADES (no limit)                   |
//|                   Based on CLAMA_X with Market Protection        |
//|                   Date: 2026-02-23                               |
//+------------------------------------------------------------------+
#property copyright "CLAMA M v1.0 - Market Protected Edition (2026-02-23)"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura za praćenje svakog tradea
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   intendedSL;
    datetime openTime;
    int      slDelaySeconds;
    double   stealthTP;
    int      trailLevel;        // 0=none, 1=BE, 2=L2
    int      randomBEPips;
    int      randomLevel2Pips;
    int      barsInTrade;
};

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 8;        // Fast EMA
input int      SlowEMA          = 17;       // Slow EMA
input int      SignalSMA        = 9;        // Signal SMA
input bool     UseHistogramFilter = true;   // Histogram mora rasti

input group "=== TREND FILTER (Hull MA) ==="
input bool     UseTrendFilter   = true;     // Koristi Hull MA filter
input int      HullPeriod       = 20;       // Hull MA Period
input bool     StrictHullFilter = true;     // Striktni filter (ne dopušta neutral)

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;      // Stop Loss (x ATR)
input double   TPMultiplier     = 3.0;      // Take Profit (x ATR) - STEALTH
input int      ATRPeriod        = 20;       // ATR Period za SL/TP
input double   MinATR           = 1.0;      // Min ATR za trade
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu
input double   RiskPercent      = 1.0;      // Risk % od Balance-a
input int      MaxOpenTrades    = 10;       // Max otvorenih tradeova (0 = bez limita)

input group "=== STEALTH EXECUTION ==="
input int      SLDelayMin       = 7;        // Min delay za SL (sekunde)
input int      SLDelayMax       = 13;       // Max delay za SL (sekunde)
input double   LargeCandleATR   = 3.0;      // Filter ekstremnih svijeća (> 3x ATR)

input group "=== TRAILING STOP ==="
input int      TrailActivatePips   = 500;   // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin      = 38;    // BE + min pips
input int      TrailBEPipsMax      = 43;    // BE + max pips
input int      TrailLevel2Pips     = 1000;  // Level 2 aktivacija (pips profit)
input int      TrailLevel2SLMin    = 181;   // Level 2 SL min pips profit
input int      TrailLevel2SLMax    = 213;   // Level 2 SL max pips profit

input group "=== NEWS FILTER (NOVO) ==="
input bool     UseNewsFilter       = true;  // Koristi News Filter
input int      NewsImportance      = 2;     // Min važnost vijesti (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore   = 30;    // Minuta prije vijesti - ne trguj
input int      NewsMinutesAfter    = 30;    // Minuta nakon vijesti - ne trguj

input group "=== SPREAD FILTER (NOVO) ==="
input bool     UseSpreadFilter     = true;  // Koristi Spread Filter
input int      MaxSpreadPoints     = 50;    // Max spread u points (0 = disable)

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;    // Min barova između tradeova

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 334568;   // Magic Number (različit od CLAMA_X!)
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsSinceLastTrade;
TradeData      trades[];
int            tradesCount = 0;

// Statistika filtera
int            newsBlockedCount = 0;
int            spreadBlockedCount = 0;

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
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsSinceLastTrade = MinBarsBetweenTrades + 1;
    ArrayResize(trades, 0);
    tradesCount = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔══════════════════════════════════════════════════════════╗");
    Print("║     CLAMA M v1.0 - MARKET PROTECTED EDITION              ║");
    Print("╠══════════════════════════════════════════════════════════╣");
    Print("║ MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("║ NEWS FILTER: ", UseNewsFilter ? "ON" : "OFF", " (Importance >= ", NewsImportance, ")");
    Print("║ SPREAD FILTER: ", UseSpreadFilter ? "ON" : "OFF", " (Max ", MaxSpreadPoints, " points)");
    Print("║ Max Trades: ", MaxOpenTrades == 0 ? "UNLIMITED" : IntegerToString(MaxOpenTrades));
    Print("╚══════════════════════════════════════════════════════════╝");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

    Print("═══ CLAMA M STATISTIKA ═══");
    Print("Blokirano zbog NEWS: ", newsBlockedCount);
    Print("Blokirano zbog SPREAD: ", spreadBlockedCount);
}

//+------------------------------------------------------------------+
//| NEWS FILTER - Provjera ekonomskog kalendara                      |
//+------------------------------------------------------------------+
bool HasActiveNews()
{
    if(!UseNewsFilter) return false;

    // Dohvati valute iz simbola (npr. XAUUSD -> XAU i USD)
    string symbol = _Symbol;
    string currency1 = StringSubstr(symbol, 0, 3);  // XAU
    string currency2 = StringSubstr(symbol, 3, 3);  // USD

    // Provjeri obje valute
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

        // Provjeri važnost vijesti
        if(event.importance >= NewsImportance)
        {
            datetime eventTime = values[i].time;
            datetime blockStart = eventTime - NewsMinutesBefore * 60;
            datetime blockEnd = eventTime + NewsMinutesAfter * 60;

            if(currentTime >= blockStart && currentTime <= blockEnd)
            {
                PrintFormat("⚠ NEWS BLOCK: %s (%s) @ %s [Importance: %d]",
                           event.name, currency, TimeToString(eventTime), event.importance);
                return true;
            }
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| SPREAD FILTER - Provjera trenutnog spreada                       |
//+------------------------------------------------------------------+
bool IsSpreadTooHigh()
{
    if(!UseSpreadFilter || MaxSpreadPoints <= 0) return false;

    int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

    if(currentSpread > MaxSpreadPoints)
    {
        PrintFormat("⚠ SPREAD BLOCK: Current %d > Max %d points", currentSpread, MaxSpreadPoints);
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

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

bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
    if(dt.day_of_week == 5) return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));

    return false;
}

bool IsLargeCandle()
{
    double atr = GetATR();
    if(atr <= 0) return false;

    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);

    return ((high - low) > LargeCandleATR * atr);
}

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

int GetHullDirection()
{
    if(!UseTrendFilter) return 0;
    double close[];
    ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2 + 5;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close) <= 0) return 0;
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0.0, wmaFull = 0.0;
    double sumWeightsHalf = 0.0, sumWeightsFull = 0.0;
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
    wmaHalf = 0.0; wmaFull = 0.0;
    sumWeightsHalf = 0.0; sumWeightsFull = 0.0;
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
    double threshold = GetATR() * 0.1;
    if(diff > threshold) return 1;
    if(diff < -threshold) return -1;
    return 0;
}

double GetATR()
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;
    if(barsSinceLastTrade < MinBarsBetweenTrades) return;
    double atr = GetATR();
    if(atr < MinATR) return;
    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);
    if(CopyBuffer(macdHandle, 0, 0, 3, macdMain) <= 0) return;
    if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) <= 0) return;
    bool macdAbove = macdMain[1] > macdSignal[1];
    bool macdBelow = macdMain[1] < macdSignal[1];
    bool macdWasAbove = macdMain[2] > macdSignal[2];
    bool macdWasBelow = macdMain[2] < macdSignal[2];
    bool macdCrossUp = macdAbove && macdWasBelow;
    bool macdCrossDown = macdBelow && macdWasAbove;
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

void AddTrade(ulong ticket, double entry, double intendedSL, double tp, int delay, int bePips, int l2Pips)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].intendedSL = intendedSL;
    trades[tradesCount].openTime = TimeCurrent();
    trades[tradesCount].slDelaySeconds = delay;
    trades[tradesCount].stealthTP = tp;
    trades[tradesCount].trailLevel = 0;
    trades[tradesCount].randomBEPips = bePips;
    trades[tradesCount].randomLevel2Pips = l2Pips;
    trades[tradesCount].barsInTrade = 0;
    tradesCount++;
}

void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
    {
        Print("CLAMA M CLOSE [", ticket, "]: ", reason);
    }
}

double GetProfitPips(ulong ticket, double entryPrice)
{
    if(!PositionSelectByTicket(ticket)) return 0;
    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentPrice;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(posType == POSITION_TYPE_BUY)
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
        double profitPips = GetProfitPips(ticket, trades[i].entryPrice);

        // 1. Odgođeni Stop Loss
        if(currentSL == 0 && trades[i].intendedSL != 0)
        {
            if(TimeCurrent() >= trades[i].openTime + trades[i].slDelaySeconds)
            {
                double sl = NormalizeDouble(trades[i].intendedSL, digits);
                if(trade.PositionModify(ticket, sl, 0))
                {
                    Print("CLAMA M STEALTH: SL postavljen na ", sl, " za #", ticket);
                }
            }
        }

        // 2. Check Stealth TP
        if(trades[i].stealthTP > 0)
        {
            double currentPrice;
            bool tpHit = false;
            if(posType == POSITION_TYPE_BUY)
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(currentPrice >= trades[i].stealthTP) tpHit = true;
            }
            else
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if(currentPrice <= trades[i].stealthTP) tpHit = true;
            }
            if(tpHit)
            {
                ClosePosition(ticket, "Stealth TP HIT @ " + DoubleToString(currentPrice, digits));
                continue;
            }
        }

        // 3. Trailing logike
        if(currentSL > 0)
        {
            // Level 2 Trailing
            if(trades[i].trailLevel < 2 && profitPips >= TrailLevel2Pips)
            {
                double newSL;
                if(posType == POSITION_TYPE_BUY)
                {
                    newSL = trades[i].entryPrice + trades[i].randomLevel2Pips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 2;
                            Print("CLAMA M [", ticket, "] TRAIL L2: SL -> +", trades[i].randomLevel2Pips, " pips");
                        }
                    }
                }
                else
                {
                    newSL = trades[i].entryPrice - trades[i].randomLevel2Pips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 2;
                            Print("CLAMA M [", ticket, "] TRAIL L2: SL -> +", trades[i].randomLevel2Pips, " pips");
                        }
                    }
                }
                continue;
            }

            // Level 1 BE
            if(trades[i].trailLevel < 1 && profitPips >= TrailActivatePips)
            {
                double newSL;
                if(posType == POSITION_TYPE_BUY)
                {
                    newSL = trades[i].entryPrice + trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("CLAMA M [", ticket, "] TRAIL BE: SL -> BE+", trades[i].randomBEPips, " pips");
                        }
                    }
                }
                else
                {
                    newSL = trades[i].entryPrice - trades[i].randomBEPips * point;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                        {
                            trades[i].trailLevel = 1;
                            Print("CLAMA M [", ticket, "] TRAIL BE: SL -> BE+", trades[i].randomBEPips, " pips");
                        }
                    }
                }
            }
        }
    }
}

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

void OpenBuy()
{
    double atr = GetATR();
    if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = price - SLMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int l2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    if(trade.Buy(lots, _Symbol, price, 0, 0, "CLAMA M BUY"))
    {
        ulong ticket = trade.ResultOrder();
        double stealthTP = NormalizeDouble(price + TPMultiplier * atr, digits);
        AddTrade(ticket, price, sl, stealthTP, slDelay, bePips, l2Pips);
        Print("✓ CLAMA M STEALTH BUY [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " Delay=", slDelay, "s");
        Print("  Open trades: ", tradesCount, " | Trail: BE+", bePips, ", L2+", l2Pips);
        barsSinceLastTrade = 0;
    }
}

void OpenSell()
{
    double atr = GetATR();
    if(atr <= 0) return;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = price + SLMultiplier * atr;
    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    int bePips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    int l2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);
    int slDelay = RandomRange(SLDelayMin, SLDelayMax);

    if(trade.Sell(lots, _Symbol, price, 0, 0, "CLAMA M SELL"))
    {
        ulong ticket = trade.ResultOrder();
        double stealthTP = NormalizeDouble(price - TPMultiplier * atr, digits);
        AddTrade(ticket, price, sl, stealthTP, slDelay, bePips, l2Pips);
        Print("✓ CLAMA M STEALTH SELL [", ticket, "]: ", lots, " @ ", price, " SL=", sl, " Delay=", slDelay, "s");
        Print("  Open trades: ", tradesCount, " | Trail: BE+", bePips, ", L2+", l2Pips);
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
    if(MaxOpenTrades > 0 && CountOpenPositions() >= MaxOpenTrades) return;

    //=== NOVI FILTERI ===

    // NEWS FILTER - Izbjegavaj trading oko važnih vijesti
    if(HasActiveNews())
    {
        newsBlockedCount++;
        return;
    }

    // SPREAD FILTER - Izbjegavaj širok spread
    if(IsSpreadTooHigh())
    {
        spreadBlockedCount++;
        return;
    }

    //=== SIGNAL LOGIC ===
    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    if(buySignal)
    {
        Print("CLAMA M BUY SIGNAL (Hull=", GetHullDirection(), ", Spread=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), ")");
        OpenBuy();
    }
    else if(sellSignal)
    {
        Print("CLAMA M SELL SIGNAL (Hull=", GetHullDirection(), ", Spread=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), ")");
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
    if(trades_count < 50) return 0;
    return profitFactor * MathSqrt(trades_count);
}
//+------------------------------------------------------------------+
