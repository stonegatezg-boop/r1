//+------------------------------------------------------------------+
//|                                         XAUUSD_M5_MACD_EA.mq5    |
//|                   Optimized MACD Strategy for XAUUSD M5          |
//|                   Parameters: Fast=8, Slow=17, Signal=9          |
//+------------------------------------------------------------------+
#property copyright "Quantitative Analysis"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== MACD POSTAVKE ==="
input int      FastEMA          = 8;        // Fast EMA (optimalno: 8)
input int      SlowEMA          = 17;       // Slow EMA (optimalno: 17)
input int      SignalSMA        = 9;        // Signal SMA (optimalno: 9)

input group "=== TREND FILTER (Hull MA) ==="
input bool     UseTrendFilter   = true;     // Koristi Hull MA filter
input int      HullPeriod       = 20;       // Hull MA Period (optimalno: 20)

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 1.5;      // Stop Loss (x ATR)
input double   TPMultiplier     = 2.5;      // Take Profit (x ATR)
input int      ATRPeriod        = 20;       // ATR Period za SL/TP
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu
input double   RiskPercent      = 1.0;      // Risk % od Balance-a

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;     // Koristi session filter
input int      LondonStart      = 2;        // London početak (UTC)
input int      LondonEnd        = 5;        // London kraj
input int      NYAMStart        = 9;        // NY AM početak
input int      NYAMEnd          = 11;       // NY AM kraj
input int      NYPMStart        = 13;       // NY PM početak
input int      NYPMEnd          = 17;       // NY PM kraj

input group "=== VOLUME FILTER ==="
input bool     UseVolumeFilter  = false;    // Koristi volume filter
input int      VolumePeriod     = 50;       // Volume MA period

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 234567;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//--- Global variables
CTrade         trade;
int            macdHandle;
int            atrHandle;
datetime       lastBarTime;
int            barsInCurrentTrade;
ulong          currentTicket;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    //--- Create indicators
    macdHandle = iMACD(_Symbol, PERIOD_CURRENT, FastEMA, SlowEMA, SignalSMA, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

    if(macdHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    barsInCurrentTrade = 0;
    currentTicket = 0;

    Print("MACD EA inicijaliziran: MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ")");
    if(UseTrendFilter) Print("Hull MA filter aktivan: period=", HullPeriod);
    if(UseSessionFilter) Print("Session filter aktivan");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Check if new bar                                                   |
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

//+------------------------------------------------------------------+
//| Check session                                                      |
//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    if(hour >= LondonStart && hour < LondonEnd) return true;
    if(hour >= NYAMStart && hour < NYAMEnd) return true;
    if(hour >= NYPMStart && hour < NYPMEnd) return true;

    return false;
}

//+------------------------------------------------------------------+
//| Calculate Hull MA direction                                        |
//+------------------------------------------------------------------+
int GetHullDirection()
{
    if(!UseTrendFilter) return 0;

    double close[];
    ArraySetAsSeries(close, true);
    int bars = HullPeriod * 2;
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);

    //--- WMA half period
    int halfPeriod = HullPeriod / 2;
    double wmaHalf = 0, wmaFull = 0;
    double sumWeightsHalf = 0, sumWeightsFull = 0;

    for(int i = 0; i < halfPeriod; i++)
    {
        double w = halfPeriod - i;
        wmaHalf += close[i+1] * w;
        sumWeightsHalf += w;
    }
    wmaHalf /= sumWeightsHalf;

    for(int i = 0; i < HullPeriod; i++)
    {
        double w = HullPeriod - i;
        wmaFull += close[i+1] * w;
        sumWeightsFull += w;
    }
    wmaFull /= sumWeightsFull;

    double raw = 2 * wmaHalf - wmaFull;

    //--- Previous bar calculation
    double wmaHalfPrev = 0, wmaFullPrev = 0;
    sumWeightsHalf = 0; sumWeightsFull = 0;

    for(int i = 0; i < halfPeriod; i++)
    {
        double w = halfPeriod - i;
        wmaHalfPrev += close[i+2] * w;
        sumWeightsHalf += w;
    }
    wmaHalfPrev /= sumWeightsHalf;

    for(int i = 0; i < HullPeriod; i++)
    {
        double w = HullPeriod - i;
        wmaFullPrev += close[i+2] * w;
        sumWeightsFull += w;
    }
    wmaFullPrev /= sumWeightsFull;

    double rawPrev = 2 * wmaHalfPrev - wmaFullPrev;

    //--- Direction
    if(raw > rawPrev) return 1;   // Bullish
    if(raw < rawPrev) return -1;  // Bearish
    return 0;
}

//+------------------------------------------------------------------+
//| Check volume filter                                                |
//+------------------------------------------------------------------+
bool IsVolumeAboveAverage()
{
    if(!UseVolumeFilter) return true;

    long volume[];
    ArraySetAsSeries(volume, true);
    CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, VolumePeriod + 1, volume);

    double sum = 0;
    for(int i = 1; i <= VolumePeriod; i++)
        sum += (double)volume[i];

    double avgVolume = sum / VolumePeriod;

    return (double)volume[1] > avgVolume;
}

//+------------------------------------------------------------------+
//| Get MACD signals                                                   |
//+------------------------------------------------------------------+
void GetMACDSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;

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

    //--- Hull MA filter
    int hullDir = GetHullDirection();

    //--- Volume filter
    bool volumeOK = IsVolumeAboveAverage();

    //--- Generate signals
    if(macdCrossUp)
    {
        if(!UseTrendFilter || hullDir >= 0)  // Hull bullish or neutral
        {
            if(volumeOK)
                buySignal = true;
        }
    }

    if(macdCrossDown)
    {
        if(!UseTrendFilter || hullDir <= 0)  // Hull bearish or neutral
        {
            if(volumeOK)
                sellSignal = true;
        }
    }
}

//+------------------------------------------------------------------+
//| Get ATR value                                                      |
//+------------------------------------------------------------------+
double GetATR()
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                 |
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
//| Check open position                                                |
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
//| Close position                                                     |
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
//| Open buy                                                           |
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

    if(trade.Buy(lots, _Symbol, price, sl, tp, "MACD BUY"))
    {
        Print("BUY: ", lots, " @ ", price, " SL=", sl, " TP=", tp);
        barsInCurrentTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Open sell                                                          |
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

    if(trade.Sell(lots, _Symbol, price, sl, tp, "MACD SELL"))
    {
        Print("SELL: ", lots, " @ ", price, " SL=", sl, " TP=", tp);
        barsInCurrentTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
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
            Print("Time exit - ", barsInCurrentTrade, " bars");
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
        Print("MACD BUY signal");
        OpenBuy();
    }
    else if(sellSignal && !HasOpenPosition())
    {
        Print("MACD SELL signal");
        OpenSell();
    }
}

//+------------------------------------------------------------------+
//| Tester function                                                    |
//+------------------------------------------------------------------+
double OnTester()
{
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);

    if(trades < 100) return 0;
    return profitFactor * MathSqrt(trades);
}
//+------------------------------------------------------------------+
