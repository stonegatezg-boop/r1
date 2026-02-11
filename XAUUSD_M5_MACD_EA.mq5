//+------------------------------------------------------------------+
//|                                         XAUUSD_M5_MACD_EA.mq5    |
//|                        *** CLAMA v1.1 ***                        |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   Date: 2026-02-11 17:30                         |
//+------------------------------------------------------------------+
#property copyright "CLAMA v1.1 - MACD + Hull MA (2026-02-11)"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 8;        // Fast EMA
input int      SlowEMA          = 17;       // Slow EMA
input int      SignalSMA        = 9;        // Signal SMA
input bool     UseHistogramFilter = true;   // NOVO: Histogram mora rasti

input group "=== TREND FILTER (Hull MA) ==="
input bool     UseTrendFilter   = true;     // Koristi Hull MA filter
input int      HullPeriod       = 20;       // Hull MA Period
input bool     StrictHullFilter = true;     // NOVO: Striktni filter (ne dopušta neutral)

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;      // Stop Loss (x ATR) - POVEĆANO sa 1.5
input double   TPMultiplier     = 3.0;      // Take Profit (x ATR) - POVEĆANO sa 2.5
input int      ATRPeriod        = 20;       // ATR Period za SL/TP
input double   MinATR           = 1.0;      // NOVO: Min ATR za trade (izbjegava low vol)
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu
input double   RiskPercent      = 1.0;      // Risk % od Balance-a

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;    // NOVO: Min barova između tradeova (30 min)

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;     // Koristi session filter
input int      LondonStart      = 8;        // London početak (BROKER TIME) - promijenjeno
input int      LondonEnd        = 11;       // London kraj
input int      NYStart          = 14;       // NY početak (BROKER TIME)
input int      NYEnd            = 20;       // NY kraj

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 234567;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
datetime       lastTradeTime;              // NOVO: Za cooldown
int            barsInCurrentTrade;
int            barsSinceLastTrade;         // NOVO: Za cooldown
ulong          currentTicket;

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
    lastTradeTime = 0;
    barsInCurrentTrade = 0;
    barsSinceLastTrade = MinBarsBetweenTrades + 1; // Dopusti prvi trade odmah
    currentTicket = 0;

    Print("=== CLAMA v1.1 inicijaliziran (2026-02-11) ===");
    Print("MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("SL=", SLMultiplier, "xATR, TP=", TPMultiplier, "xATR, Cooldown=", MinBarsBetweenTrades, " bars");
    Print("Session: ", LondonStart, "-", LondonEnd, " i ", NYStart, "-", NYEnd, " (broker time)");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        barsSinceLastTrade++;  // NOVO: Increment cooldown counter
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    // London session (broker time)
    if(hour >= LondonStart && hour < LondonEnd) return true;

    // NY session (broker time)
    if(hour >= NYStart && hour < NYEnd) return true;

    return false;
}

//+------------------------------------------------------------------+
// NOVO: Provjeri da li je MACD histogram rastući
//+------------------------------------------------------------------+
bool IsHistogramGrowing(bool forBuy)
{
    if(!UseHistogramFilter) return true;

    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);

    if(CopyBuffer(macdHandle, 0, 0, 4, macdMain) <= 0) return false;
    if(CopyBuffer(macdHandle, 1, 0, 4, macdSignal) <= 0) return false;

    double hist1 = macdMain[1] - macdSignal[1];  // Current confirmed bar
    double hist2 = macdMain[2] - macdSignal[2];  // Previous bar
    double hist3 = macdMain[3] - macdSignal[3];  // 2 bars ago

    if(forBuy)
    {
        // Za BUY: histogram mora biti rastući (manje negativan ili više pozitivan)
        return (hist1 > hist2 && hist2 > hist3);
    }
    else
    {
        // Za SELL: histogram mora biti padajući (manje pozitivan ili više negativan)
        return (hist1 < hist2 && hist2 < hist3);
    }
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

    //--- Current Hull
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

    //--- Previous Hull (2 bars ago for stronger confirmation)
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

    //--- Direction with threshold
    double diff = hullCurrent - hullPrev;
    double threshold = GetATR() * 0.1;  // 10% of ATR as minimum move

    if(diff > threshold) return 1;    // Clear bullish
    if(diff < -threshold) return -1;  // Clear bearish
    return 0;  // Neutral/unclear
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

    //--- NOVO: Provjeri cooldown
    if(barsSinceLastTrade < MinBarsBetweenTrades)
    {
        return;  // Još uvijek u cooldown periodu
    }

    //--- NOVO: Provjeri minimum ATR
    double atr = GetATR();
    if(atr < MinATR)
    {
        return;  // Preniska volatilnost
    }

    double macdMain[], macdSignal[];
    ArraySetAsSeries(macdMain, true);
    ArraySetAsSeries(macdSignal, true);

    if(CopyBuffer(macdHandle, 0, 0, 3, macdMain) <= 0) return;
    if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) <= 0) return;

    //--- MACD crossover on CONFIRMED bar [1]
    bool macdAbove = macdMain[1] > macdSignal[1];
    bool macdBelow = macdMain[1] < macdSignal[1];
    bool macdWasAbove = macdMain[2] > macdSignal[2];
    bool macdWasBelow = macdMain[2] < macdSignal[2];

    bool macdCrossUp = macdAbove && macdWasBelow;
    bool macdCrossDown = macdBelow && macdWasAbove;

    //--- Hull MA filter (STRIKTNIJE)
    int hullDir = GetHullDirection();

    //--- Generate signals
    if(macdCrossUp)
    {
        // NOVO: Striktni Hull filter - mora biti jasno bullish
        if(!UseTrendFilter || (StrictHullFilter ? hullDir == 1 : hullDir >= 0))
        {
            // NOVO: Histogram mora rasti
            if(IsHistogramGrowing(true))
            {
                buySignal = true;
            }
        }
    }

    if(macdCrossDown)
    {
        // NOVO: Striktni Hull filter - mora biti jasno bearish
        if(!UseTrendFilter || (StrictHullFilter ? hullDir == -1 : hullDir <= 0))
        {
            // NOVO: Histogram mora padati
            if(IsHistogramGrowing(false))
            {
                sellSignal = true;
            }
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

    double slPoints = slDistance / point;
    double lotSize = riskAmount / (slPoints * tickValue / tickSize);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return NormalizeDouble(lotSize, 2);
}

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
            {
                currentTicket = ticket;
                return true;
            }
        }
    }
    currentTicket = 0;
    return false;
}

//+------------------------------------------------------------------+
void ClosePosition()
{
    if(currentTicket > 0)
    {
        trade.PositionClose(currentTicket);
        currentTicket = 0;
        barsInCurrentTrade = 0;
    }
}

//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = price - SLMultiplier * atr;
    double tp = price + TPMultiplier * atr;

    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if(trade.Buy(lots, _Symbol, price, sl, tp, "CLAMA v1.1 BUY"))
    {
        Print("CLAMA v1.1 BUY: ", lots, " @ ", price, " SL=", sl, " TP=", tp, " ATR=", atr);
        barsInCurrentTrade = 0;
        barsSinceLastTrade = 0;  // NOVO: Reset cooldown
        lastTradeTime = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
void OpenSell()
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = price + SLMultiplier * atr;
    double tp = price - TPMultiplier * atr;

    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if(trade.Sell(lots, _Symbol, price, sl, tp, "CLAMA v1.1 SELL"))
    {
        Print("CLAMA v1.1 SELL: ", lots, " @ ", price, " SL=", sl, " TP=", tp, " ATR=", atr);
        barsInCurrentTrade = 0;
        barsSinceLastTrade = 0;  // NOVO: Reset cooldown
        lastTradeTime = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    if(!IsNewBar()) return;

    //--- Time exit check
    if(HasOpenPosition())
    {
        barsInCurrentTrade++;
        if(barsInCurrentTrade >= MaxBarsInTrade)
        {
            Print("CLAMA v1.1 Time exit - ", barsInCurrentTrade, " bars");
            ClosePosition();
        }
        if(HasOpenPosition()) return;
    }

    //--- Session check
    if(!IsGoodSession()) return;

    //--- Get signals
    bool buySignal, sellSignal;
    GetMACDSignals(buySignal, sellSignal);

    //--- Execute
    if(buySignal && !HasOpenPosition())
    {
        Print("CLAMA v1.1 BUY SIGNAL (Hull=", GetHullDirection(), ", Cooldown=", barsSinceLastTrade, ")");
        OpenBuy();
    }
    else if(sellSignal && !HasOpenPosition())
    {
        Print("CLAMA v1.1 SELL SIGNAL (Hull=", GetHullDirection(), ", Cooldown=", barsSinceLastTrade, ")");
        OpenSell();
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);

    if(trades < 50) return 0;
    return profitFactor * MathSqrt(trades);
}
//+------------------------------------------------------------------+
