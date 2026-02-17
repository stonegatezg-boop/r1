//+------------------------------------------------------------------+
//|                                         XAUUSD_M5_MACD_EA.mq5    |
//|                        *** CLAMA v1.2 ***                        |
//|                   MACD + Hull MA Strategy for XAUUSD M5          |
//|                   + Trailing Stop + Stealth TP                   |
//|                   Date: 2026-02-17 14:45                         |
//+------------------------------------------------------------------+
#property copyright "CLAMA v1.2 - Trailing Stop + Stealth TP (2026-02-17)"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>

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
input double   TPMultiplier     = 3.0;      // Take Profit (x ATR) - STEALTH, ne postavlja se
input int      ATRPeriod        = 20;       // ATR Period za SL/TP
input double   MinATR           = 1.0;      // Min ATR za trade (izbjegava low vol)
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu
input double   RiskPercent      = 1.0;      // Risk % od Balance-a

input group "=== TRAILING STOP (NOVO v1.2) ==="
input int      TrailActivatePips   = 500;   // Aktivacija trailing-a (pips profit)
input int      TrailBEPipsMin      = 28;    // BE + min pips (random 28-34)
input int      TrailBEPipsMax      = 34;    // BE + max pips
input int      TrailLevel2Pips     = 1000;  // Level 2 aktivacija (pips profit)
input int      TrailLevel2SLMin    = 181;   // Level 2 SL min pips profit (random 181-213)
input int      TrailLevel2SLMax    = 213;   // Level 2 SL max pips profit

input group "=== COOLDOWN ==="
input int      MinBarsBetweenTrades = 6;    // Min barova između tradeova (30 min)

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;     // Koristi session filter
input int      LondonStart      = 8;        // London početak (BROKER TIME)
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
datetime       lastTradeTime;
int            barsInCurrentTrade;
int            barsSinceLastTrade;
ulong          currentTicket;

//--- Trailing stop tracking (per trade)
double         entryPrice;
double         stealthTP;           // TP koji pratimo interno, nije na orderu
int            trailLevel;          // 0=none, 1=BE activated, 2=Level2 activated
int            randomBEPips;        // Random BE pips za ovaj trade
int            randomLevel2Pips;    // Random Level2 pips za ovaj trade

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
    barsSinceLastTrade = MinBarsBetweenTrades + 1;
    currentTicket = 0;
    entryPrice = 0;
    stealthTP = 0;
    trailLevel = 0;

    // Seed random generator
    MathSrand((int)TimeCurrent());

    Print("=== CLAMA v1.2 inicijaliziran (2026-02-17 14:45) ===");
    Print("MACD(", FastEMA, ",", SlowEMA, ",", SignalSMA, ") + Hull(", HullPeriod, ")");
    Print("SL=", SLMultiplier, "xATR, Stealth TP=", TPMultiplier, "xATR (ne prikazuje se)");
    Print("Trailing: BE@", TrailActivatePips, "pips (+", TrailBEPipsMin, "-", TrailBEPipsMax, " random)");
    Print("Trailing L2: @", TrailLevel2Pips, "pips (SL +", TrailLevel2SLMin, "-", TrailLevel2SLMax, " random)");
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
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

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
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    if(hour >= LondonStart && hour < LondonEnd) return true;
    if(hour >= NYStart && hour < NYEnd) return true;

    return false;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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
void ClosePosition(string reason)
{
    if(currentTicket > 0)
    {
        trade.PositionClose(currentTicket);
        Print("CLAMA v1.2 CLOSE: ", reason);
        currentTicket = 0;
        barsInCurrentTrade = 0;
        entryPrice = 0;
        stealthTP = 0;
        trailLevel = 0;
    }
}

//+------------------------------------------------------------------+
double GetCurrentProfitPips()
{
    if(currentTicket == 0 || entryPrice == 0) return 0;

    if(!PositionSelectByTicket(currentTicket)) return 0;

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

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(currentTicket == 0 || entryPrice == 0) return;
    if(!PositionSelectByTicket(currentTicket)) return;

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double profitPips = GetCurrentProfitPips();

    //--- Check for Stealth TP hit (EA closes "manually")
    if(stealthTP > 0)
    {
        double currentPrice;
        if(posType == POSITION_TYPE_BUY)
        {
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(currentPrice >= stealthTP)
            {
                ClosePosition("Stealth TP HIT @ " + DoubleToString(currentPrice, digits));
                return;
            }
        }
        else
        {
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(currentPrice <= stealthTP)
            {
                ClosePosition("Stealth TP HIT @ " + DoubleToString(currentPrice, digits));
                return;
            }
        }
    }

    //--- Level 2 Trailing (at 1000 pips profit)
    if(trailLevel < 2 && profitPips >= TrailLevel2Pips)
    {
        double newSL;

        if(posType == POSITION_TYPE_BUY)
        {
            newSL = entryPrice + randomLevel2Pips * point;
            newSL = NormalizeDouble(newSL, digits);

            if(newSL > currentSL)
            {
                if(trade.PositionModify(currentTicket, newSL, 0))
                {
                    trailLevel = 2;
                    Print("CLAMA v1.2 TRAIL L2: SL -> +", randomLevel2Pips, " pips (profit: ", (int)profitPips, " pips)");
                }
            }
        }
        else
        {
            newSL = entryPrice - randomLevel2Pips * point;
            newSL = NormalizeDouble(newSL, digits);

            if(newSL < currentSL)
            {
                if(trade.PositionModify(currentTicket, newSL, 0))
                {
                    trailLevel = 2;
                    Print("CLAMA v1.2 TRAIL L2: SL -> +", randomLevel2Pips, " pips (profit: ", (int)profitPips, " pips)");
                }
            }
        }
        return;
    }

    //--- Level 1 Break-Even (at 500 pips profit)
    if(trailLevel < 1 && profitPips >= TrailActivatePips)
    {
        double newSL;

        if(posType == POSITION_TYPE_BUY)
        {
            newSL = entryPrice + randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);

            if(newSL > currentSL)
            {
                if(trade.PositionModify(currentTicket, newSL, 0))
                {
                    trailLevel = 1;
                    Print("CLAMA v1.2 TRAIL BE: SL -> BE+", randomBEPips, " pips (profit: ", (int)profitPips, " pips)");
                }
            }
        }
        else
        {
            newSL = entryPrice - randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);

            if(newSL < currentSL)
            {
                if(trade.PositionModify(currentTicket, newSL, 0))
                {
                    trailLevel = 1;
                    Print("CLAMA v1.2 TRAIL BE: SL -> BE+", randomBEPips, " pips (profit: ", (int)profitPips, " pips)");
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = price - SLMultiplier * atr;
    // TP se NE postavlja na order - pratimo interno (stealth)
    double lots = CalculateLotSize(SLMultiplier * atr);

    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    // Generiraj random pips za ovaj trade
    randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    randomLevel2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);

    // TP = 0 na orderu, ali pratimo interno
    if(trade.Buy(lots, _Symbol, price, sl, 0, "CLAMA v1.2 BUY"))
    {
        entryPrice = price;
        stealthTP = price + TPMultiplier * atr;
        stealthTP = NormalizeDouble(stealthTP, digits);
        trailLevel = 0;

        Print("CLAMA v1.2 BUY: ", lots, " @ ", price, " SL=", sl, " StealthTP=", stealthTP);
        Print("Random Trail: BE+", randomBEPips, " pips, L2+", randomLevel2Pips, " pips");

        barsInCurrentTrade = 0;
        barsSinceLastTrade = 0;
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
    // TP se NE postavlja na order - pratimo interno (stealth)
    double lots = CalculateLotSize(SLMultiplier * atr);

    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    // Generiraj random pips za ovaj trade
    randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
    randomLevel2Pips = RandomRange(TrailLevel2SLMin, TrailLevel2SLMax);

    // TP = 0 na orderu, ali pratimo interno
    if(trade.Sell(lots, _Symbol, price, sl, 0, "CLAMA v1.2 SELL"))
    {
        entryPrice = price;
        stealthTP = price - TPMultiplier * atr;
        stealthTP = NormalizeDouble(stealthTP, digits);
        trailLevel = 0;

        Print("CLAMA v1.2 SELL: ", lots, " @ ", price, " SL=", sl, " StealthTP=", stealthTP);
        Print("Random Trail: BE+", randomBEPips, " pips, L2+", randomLevel2Pips, " pips");

        barsInCurrentTrade = 0;
        barsSinceLastTrade = 0;
        lastTradeTime = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    //--- UVIJEK provjeravaj trailing stop (svaki tick, ne samo novi bar)
    if(HasOpenPosition())
    {
        ManageTrailingStop();
    }

    if(!IsNewBar()) return;

    //--- Time exit check
    if(HasOpenPosition())
    {
        barsInCurrentTrade++;
        if(barsInCurrentTrade >= MaxBarsInTrade)
        {
            ClosePosition("Time exit - " + IntegerToString(barsInCurrentTrade) + " bars");
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
        Print("CLAMA v1.2 BUY SIGNAL (Hull=", GetHullDirection(), ", Cooldown=", barsSinceLastTrade, ")");
        OpenBuy();
    }
    else if(sellSignal && !HasOpenPosition())
    {
        Print("CLAMA v1.2 SELL SIGNAL (Hull=", GetHullDirection(), ", Cooldown=", barsSinceLastTrade, ")");
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
