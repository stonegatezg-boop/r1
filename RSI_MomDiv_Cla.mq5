//+------------------------------------------------------------------+
//|                                             RSI_MomDiv_Cla.mq5   |
//|        *** RSI Momentum Divergence Zones Strategy ***            |
//|                   + Stealth Mode v2.1                            |
//|                   Based on ChartPrime TradingView Indicator      |
//|                   Version 1.0 - 2026-02-25                       |
//+------------------------------------------------------------------+
//| Strategy:                                                        |
//| - RSI based on Momentum (rate of change) instead of price        |
//| - Detects Bullish Divergence: Price LL + RSI HL                  |
//| - Detects Bearish Divergence: Price HH + RSI LH                  |
//| - Creates dynamic support/resistance zones from divergences      |
//| - Entry on zone bounce with confirmation                         |
//+------------------------------------------------------------------+
#property copyright "RSI_MomDiv_Cla v1.0 (2026-02-25)"
#property version   "1.00"
#property strict

#include <Trade\\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== RSI MOMENTUM POSTAVKE ==="
input int      RSI_Length         = 14;      // RSI Period
input int      Momentum_Period    = 10;      // Momentum Period (za RSI source)
input int      PivotLookbackL     = 5;       // Pivot Lookback Left
input int      PivotLookbackR     = 5;       // Pivot Lookback Right
input int      MinBarsInRange     = 5;       // Min barova između pivota
input int      MaxBarsInRange     = 50;      // Max barova između pivota

input group "=== DIVERGENCE ZONE POSTAVKE ==="
input int      MaxZones           = 10;      // Max aktivnih zona
input int      ZoneValidBars      = 100;     // Koliko bara zona ostaje aktivna
input double   ZoneBreakATR       = 0.5;     // ATR x za invalidaciju zone

input group "=== ENTRY CONFIRMATION ==="
input bool     RequireCandleConf  = true;    // Zahtijevaj svijeću potvrdu
input bool     RequireRSIConf     = true;    // Zahtijevaj RSI potvrdu
input double   RSI_Oversold       = 30.0;    // RSI oversold level
input double   RSI_Overbought     = 70.0;    // RSI overbought level

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent        = 1.0;     // Risk % po tradeu
input double   SLMultiplier       = 1.5;     // SL = ATR x množitelj
input double   Target1_ATR        = 1.5;     // Target 1 (ATR x)
input double   Target2_ATR        = 2.5;     // Target 2 (ATR x)
input double   Target3_ATR        = 3.5;     // Target 3 (ATR x)
input int      ClosePercent1      = 33;      // % za zatvaranje na T1
input int      ClosePercent2      = 50;      // % ostatka za T2
input int      ATRPeriod          = 14;      // ATR period

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode     = true;    // Stealth mod
input int      OpenDelayMin       = 0;       // Min delay otvaranja (sekunde)
input int      OpenDelayMax       = 4;       // Max delay otvaranja
input int      SLDelayMin         = 7;       // Min delay SL postavljanja
input int      SLDelayMax         = 13;      // Max delay SL postavljanja
input double   LargeCandleATR     = 3.0;     // Filter velikih svijeća

input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips  = 500;     // Aktivacija trailinga (pipsi)
input int      TrailBEPipsMin     = 38;      // BE + min pipsi
input int      TrailBEPipsMax     = 43;      // BE + max pipsi
input int      TrailLevel2Pips    = 800;     // Level 2 aktivacija
input int      TrailLockPipsMin   = 150;     // Lock min pipsi
input int      TrailLockPipsMax   = 200;     // Lock max pipsi

input group "=== FILTERI ==="
input double   MaxSpread          = 50;      // Max spread (points)
input bool     UseNewsFilter      = false;   // News filter

input group "=== OPĆE ==="
input ulong    MagicNumber        = 889900;  // Magic broj
input int      Slippage           = 30;      // Slippage (points)

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
struct DivergenceZone
{
    double   price;
    datetime time;
    int      barIndex;
    bool     isBullish;
    bool     isValid;
    bool     wasHit;
};

struct PendingTradeInfo
{
    bool            active;
    ENUM_ORDER_TYPE type;
    double          lot;
    double          intendedSL;
    double          intendedTP1;
    double          intendedTP2;
    double          intendedTP3;
    datetime        signalTime;
    int             delaySeconds;
};

struct StealthPosInfo
{
    bool     active;
    ulong    ticket;
    double   intendedSL;
    double   stealthTP1;
    double   stealthTP2;
    double   stealthTP3;
    double   entryPrice;
    double   initialLots;
    datetime openTime;
    int      delaySeconds;
    int      randomBEPips;
    int      randomLockPips;
    int      targetHit;
    int      trailLevel;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade trade;
int atrHandle;
int rsiHandle;
int momHandle;

datetime lastBarTime;

DivergenceZone g_bullZones[];
DivergenceZone g_bearZones[];
int g_bullZoneCount = 0;
int g_bearZoneCount = 0;

PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;

// RSI Momentum arrays
double g_rsiMom[];
double g_momentum[];

// Statistics
int totalBuys = 0;
int totalSells = 0;
int bullDivCount = 0;
int bearDivCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Initialize ATR
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ATR handle");
        return INIT_FAILED;
    }

    // Initialize Momentum
    momHandle = iMomentum(_Symbol, PERIOD_CURRENT, Momentum_Period, PRICE_CLOSE);
    if(momHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create Momentum handle");
        return INIT_FAILED;
    }

    // We'll calculate RSI of Momentum manually
    lastBarTime = 0;

    ArrayResize(g_bullZones, 0);
    ArrayResize(g_bearZones, 0);
    g_bullZoneCount = 0;
    g_bearZoneCount = 0;

    ArrayResize(g_positions, 0);
    g_posCount = 0;
    g_pendingTrade.active = false;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     RSI MOMENTUM DIVERGENCE ZONES CLA v1.0                    ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ RSI Length: ", RSI_Length, " | Momentum: ", Momentum_Period);
    Print("║ Pivot: L", PivotLookbackL, " R", PivotLookbackR);
    Print("║ Targets: ", Target1_ATR, "x / ", Target2_ATR, "x / ", Target3_ATR, "x ATR");
    Print("║ Stealth: ", UseStealthMode ? "ON" : "OFF");
    Print("║ Trailing L1: ", TrailActivatePips, " pips -> BE+", TrailBEPipsMin, "-", TrailBEPipsMax);
    Print("║ Trailing L2: ", TrailLevel2Pips, " pips -> Lock+", TrailLockPipsMin, "-", TrailLockPipsMax);
    Print("║ Trading: Sunday 00:01 - Friday 11:30");
    Print("╚═══════════════════════════════════════════════════════════════╝");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(momHandle != INVALID_HANDLE) IndicatorRelease(momHandle);

    Print("═══════════════════════════════════════════════════");
    Print("     RSI MOMDIV CLA - ZAVRŠNA STATISTIKA");
    Print("═══════════════════════════════════════════════════");
    Print("Total BUY: ", totalBuys, " | SELL: ", totalSells);
    Print("Bull Divergences: ", bullDivCount);
    Print("Bear Divergences: ", bearDivCount);
    Print("═══════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                 |
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != lastBarTime)
    {
        lastBarTime = t;
        return true;
    }
    return false;
}

double GetATR(int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, shift, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
//| TRADING WINDOW                                                    |
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

bool IsSpreadOK()
{
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return ((double)spread <= MaxSpread);
}

bool IsLargeCandle()
{
    double atr = GetATR(1);
    if(atr <= 0) return false;

    double candleSize = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleSize > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| RSI OF MOMENTUM CALCULATION                                       |
//+------------------------------------------------------------------+
double CalculateRSIMomentum(int shift)
{
    // Get momentum values
    double mom[];
    ArraySetAsSeries(mom, true);
    if(CopyBuffer(momHandle, 0, shift, RSI_Length + 1, mom) <= 0)
        return 50.0; // Default neutral

    // Calculate RSI of momentum changes
    double gains = 0;
    double losses = 0;

    for(int i = 0; i < RSI_Length; i++)
    {
        double change = mom[i] - mom[i + 1];
        if(change > 0)
            gains += change;
        else
            losses -= change;
    }

    double avgGain = gains / RSI_Length;
    double avgLoss = losses / RSI_Length;

    if(avgLoss == 0)
        return 100.0;

    double rs = avgGain / avgLoss;
    double rsi = 100.0 - (100.0 / (1.0 + rs));

    return rsi;
}

//+------------------------------------------------------------------+
//| PIVOT DETECTION                                                   |
//+------------------------------------------------------------------+
bool IsPivotLow(int shift)
{
    double low[];
    ArraySetAsSeries(low, true);
    if(CopyLow(_Symbol, PERIOD_CURRENT, shift - PivotLookbackR, PivotLookbackL + PivotLookbackR + 1, low) <= 0)
        return false;

    double pivotVal = low[PivotLookbackR];

    // Check left side
    for(int i = 0; i < PivotLookbackR; i++)
    {
        if(low[i] <= pivotVal) return false;
    }

    // Check right side
    for(int i = PivotLookbackR + 1; i < PivotLookbackL + PivotLookbackR + 1; i++)
    {
        if(low[i] < pivotVal) return false;
    }

    return true;
}

bool IsPivotHigh(int shift)
{
    double high[];
    ArraySetAsSeries(high, true);
    if(CopyHigh(_Symbol, PERIOD_CURRENT, shift - PivotLookbackR, PivotLookbackL + PivotLookbackR + 1, high) <= 0)
        return false;

    double pivotVal = high[PivotLookbackR];

    // Check left side
    for(int i = 0; i < PivotLookbackR; i++)
    {
        if(high[i] >= pivotVal) return false;
    }

    // Check right side
    for(int i = PivotLookbackR + 1; i < PivotLookbackL + PivotLookbackR + 1; i++)
    {
        if(high[i] > pivotVal) return false;
    }

    return true;
}

bool IsRSIPivotLow(double rsiVal, int shift)
{
    // Simplified RSI pivot detection
    double rsiPrev = CalculateRSIMomentum(shift + 1);
    double rsiNext = CalculateRSIMomentum(shift - 1);

    return (rsiVal < rsiPrev && rsiVal < rsiNext);
}

bool IsRSIPivotHigh(double rsiVal, int shift)
{
    double rsiPrev = CalculateRSIMomentum(shift + 1);
    double rsiNext = CalculateRSIMomentum(shift - 1);

    return (rsiVal > rsiPrev && rsiVal > rsiNext);
}

//+------------------------------------------------------------------+
//| DIVERGENCE DETECTION                                              |
//+------------------------------------------------------------------+
void DetectDivergences()
{
    int checkShift = PivotLookbackR + 1;  // Check completed pivot

    double rsiCurrent = CalculateRSIMomentum(checkShift);

    // Get price data
    double low[], high[];
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(high, true);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, MaxBarsInRange + 20, low);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, MaxBarsInRange + 20, high);

    //=== BULLISH DIVERGENCE: Price Lower Low, RSI Higher Low ===
    if(IsPivotLow(checkShift))
    {
        double currentLow = low[checkShift];

        // Find previous pivot low
        for(int i = checkShift + MinBarsInRange; i <= checkShift + MaxBarsInRange; i++)
        {
            if(IsPivotLow(i))
            {
                double prevLow = low[i];
                double prevRSI = CalculateRSIMomentum(i);

                // Bullish divergence: Price LL, RSI HL
                if(currentLow < prevLow && rsiCurrent > prevRSI)
                {
                    // Add bullish zone
                    AddBullishZone(currentLow);
                    bullDivCount++;
                    Print("BULLISH DIVERGENCE: Price LL (", DoubleToString(currentLow, 2),
                          " < ", DoubleToString(prevLow, 2), ") RSI HL (",
                          DoubleToString(rsiCurrent, 1), " > ", DoubleToString(prevRSI, 1), ")");
                }
                break;
            }
        }
    }

    //=== BEARISH DIVERGENCE: Price Higher High, RSI Lower High ===
    if(IsPivotHigh(checkShift))
    {
        double currentHigh = high[checkShift];

        // Find previous pivot high
        for(int i = checkShift + MinBarsInRange; i <= checkShift + MaxBarsInRange; i++)
        {
            if(IsPivotHigh(i))
            {
                double prevHigh = high[i];
                double prevRSI = CalculateRSIMomentum(i);

                // Bearish divergence: Price HH, RSI LH
                if(currentHigh > prevHigh && rsiCurrent < prevRSI)
                {
                    // Add bearish zone
                    AddBearishZone(currentHigh);
                    bearDivCount++;
                    Print("BEARISH DIVERGENCE: Price HH (", DoubleToString(currentHigh, 2),
                          " > ", DoubleToString(prevHigh, 2), ") RSI LH (",
                          DoubleToString(rsiCurrent, 1), " < ", DoubleToString(prevRSI, 1), ")");
                }
                break;
            }
        }
    }
}

void AddBullishZone(double price)
{
    // Remove oldest if at max
    if(g_bullZoneCount >= MaxZones)
    {
        for(int i = 0; i < g_bullZoneCount - 1; i++)
            g_bullZones[i] = g_bullZones[i + 1];
        g_bullZoneCount--;
    }

    ArrayResize(g_bullZones, g_bullZoneCount + 1);
    g_bullZones[g_bullZoneCount].price = price;
    g_bullZones[g_bullZoneCount].time = TimeCurrent();
    g_bullZones[g_bullZoneCount].barIndex = 0;
    g_bullZones[g_bullZoneCount].isBullish = true;
    g_bullZones[g_bullZoneCount].isValid = true;
    g_bullZones[g_bullZoneCount].wasHit = false;
    g_bullZoneCount++;
}

void AddBearishZone(double price)
{
    if(g_bearZoneCount >= MaxZones)
    {
        for(int i = 0; i < g_bearZoneCount - 1; i++)
            g_bearZones[i] = g_bearZones[i + 1];
        g_bearZoneCount--;
    }

    ArrayResize(g_bearZones, g_bearZoneCount + 1);
    g_bearZones[g_bearZoneCount].price = price;
    g_bearZones[g_bearZoneCount].time = TimeCurrent();
    g_bearZones[g_bearZoneCount].barIndex = 0;
    g_bearZones[g_bearZoneCount].isBullish = false;
    g_bearZones[g_bearZoneCount].isValid = true;
    g_bearZones[g_bearZoneCount].wasHit = false;
    g_bearZoneCount++;
}

//+------------------------------------------------------------------+
//| ZONE MANAGEMENT                                                   |
//+------------------------------------------------------------------+
void UpdateZones()
{
    double atr = GetATR(1);
    double zoneBreak = atr * ZoneBreakATR;

    double currentHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double currentLow = iLow(_Symbol, PERIOD_CURRENT, 1);

    // Update bullish zones (support)
    for(int i = g_bullZoneCount - 1; i >= 0; i--)
    {
        g_bullZones[i].barIndex++;

        // Invalidate if too old
        if(g_bullZones[i].barIndex > ZoneValidBars)
        {
            g_bullZones[i].isValid = false;
        }

        // Invalidate if price breaks below zone
        if(currentLow < g_bullZones[i].price - zoneBreak)
        {
            g_bullZones[i].isValid = false;
            Print("Bullish zone INVALIDATED at ", DoubleToString(g_bullZones[i].price, 2));
        }
    }

    // Update bearish zones (resistance)
    for(int i = g_bearZoneCount - 1; i >= 0; i--)
    {
        g_bearZones[i].barIndex++;

        if(g_bearZones[i].barIndex > ZoneValidBars)
        {
            g_bearZones[i].isValid = false;
        }

        // Invalidate if price breaks above zone
        if(currentHigh > g_bearZones[i].price + zoneBreak)
        {
            g_bearZones[i].isValid = false;
            Print("Bearish zone INVALIDATED at ", DoubleToString(g_bearZones[i].price, 2));
        }
    }

    // Clean up invalid zones
    CleanupZones();
}

void CleanupZones()
{
    // Cleanup bullish
    int newCount = 0;
    for(int i = 0; i < g_bullZoneCount; i++)
    {
        if(g_bullZones[i].isValid)
        {
            if(i != newCount)
                g_bullZones[newCount] = g_bullZones[i];
            newCount++;
        }
    }
    if(newCount != g_bullZoneCount)
    {
        g_bullZoneCount = newCount;
        ArrayResize(g_bullZones, g_bullZoneCount);
    }

    // Cleanup bearish
    newCount = 0;
    for(int i = 0; i < g_bearZoneCount; i++)
    {
        if(g_bearZones[i].isValid)
        {
            if(i != newCount)
                g_bearZones[newCount] = g_bearZones[i];
            newCount++;
        }
    }
    if(newCount != g_bearZoneCount)
    {
        g_bearZoneCount = newCount;
        ArrayResize(g_bearZones, g_bearZoneCount);
    }
}

//+------------------------------------------------------------------+
//| ENTRY SIGNAL DETECTION                                            |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
    double atr = GetATR(1);
    if(atr <= 0) return 0;

    double zoneProximity = atr * 0.5;  // How close to zone for signal

    double currentLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    double currentHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);

    double rsi = CalculateRSIMomentum(1);

    //=== BUY SIGNAL: Price bounces from bullish zone ===
    for(int i = 0; i < g_bullZoneCount; i++)
    {
        if(!g_bullZones[i].isValid || g_bullZones[i].wasHit)
            continue;

        // Price touched or came close to zone
        if(currentLow <= g_bullZones[i].price + zoneProximity &&
           currentLow >= g_bullZones[i].price - zoneProximity)
        {
            // Confirmation checks
            bool candleConf = !RequireCandleConf || (close > open); // Bullish candle
            bool rsiConf = !RequireRSIConf || (rsi < RSI_Oversold + 20); // Near oversold

            if(candleConf && rsiConf)
            {
                g_bullZones[i].wasHit = true;
                Print("BUY SIGNAL: Zone bounce at ", DoubleToString(g_bullZones[i].price, 2),
                      " | RSI: ", DoubleToString(rsi, 1));
                return 1;
            }
        }
    }

    //=== SELL SIGNAL: Price rejects from bearish zone ===
    for(int i = 0; i < g_bearZoneCount; i++)
    {
        if(!g_bearZones[i].isValid || g_bearZones[i].wasHit)
            continue;

        // Price touched or came close to zone
        if(currentHigh >= g_bearZones[i].price - zoneProximity &&
           currentHigh <= g_bearZones[i].price + zoneProximity)
        {
            // Confirmation checks
            bool candleConf = !RequireCandleConf || (close < open); // Bearish candle
            bool rsiConf = !RequireRSIConf || (rsi > RSI_Overbought - 20); // Near overbought

            if(candleConf && rsiConf)
            {
                g_bearZones[i].wasHit = true;
                Print("SELL SIGNAL: Zone rejection at ", DoubleToString(g_bearZones[i].price, 2),
                      " | RSI: ", DoubleToString(rsi, 1));
                return -1;
            }
        }
    }

    return 0;
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT                                               |
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
                return true;
        }
    }
    return false;
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

    double lots = riskAmount / ((slDistance / point) * tickValue / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;

    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION                                                   |
//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(1);
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double sl, tp1, tp2, tp3;

    if(type == ORDER_TYPE_BUY)
    {
        sl = price - SLMultiplier * atr;
        tp1 = price + Target1_ATR * atr;
        tp2 = price + Target2_ATR * atr;
        tp3 = price + Target3_ATR * atr;
    }
    else
    {
        sl = price + SLMultiplier * atr;
        tp1 = price - Target1_ATR * atr;
        tp2 = price - Target2_ATR * atr;
        tp3 = price - Target3_ATR * atr;
    }

    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;

    if(UseStealthMode)
    {
        g_pendingTrade.active = true;
        g_pendingTrade.type = type;
        g_pendingTrade.lot = lots;
        g_pendingTrade.intendedSL = sl;
        g_pendingTrade.intendedTP1 = tp1;
        g_pendingTrade.intendedTP2 = tp2;
        g_pendingTrade.intendedTP3 = tp3;
        g_pendingTrade.signalTime = TimeCurrent();
        g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);

        Print("RSI_MomDiv: Trade QUEUED - ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
              " Delay: ", g_pendingTrade.delaySeconds, "s");
    }
    else
    {
        ExecuteTrade(type, lots, sl, tp1);
    }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    bool ok;

    if(UseStealthMode)
    {
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, 0, 0, "RSIM") :
             trade.Sell(lot, _Symbol, price, 0, 0, "RSIM");
    }
    else
    {
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, sl, tp, "RSIM BUY") :
             trade.Sell(lot, _Symbol, price, sl, tp, "RSIM SELL");
    }

    if(ok && UseStealthMode)
    {
        ulong ticket = trade.ResultOrder();

        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = g_pendingTrade.intendedSL;
        g_positions[g_posCount].stealthTP1 = g_pendingTrade.intendedTP1;
        g_positions[g_posCount].stealthTP2 = g_pendingTrade.intendedTP2;
        g_positions[g_posCount].stealthTP3 = g_pendingTrade.intendedTP3;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].initialLots = lot;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
        g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
        g_positions[g_posCount].randomLockPips = RandomRange(TrailLockPipsMin, TrailLockPipsMax);
        g_positions[g_posCount].targetHit = 0;
        g_positions[g_posCount].trailLevel = 0;
        g_posCount++;

        if(type == ORDER_TYPE_BUY) totalBuys++;
        else totalSells++;

        Print("╔════════════════════════════════════════════════╗");
        Print("║ RSI_MOMDIV STEALTH ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", ticket);
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", DoubleToString(price, digits), " | Lots: ", DoubleToString(lot, 2));
        Print("║ SL: ", DoubleToString(sl, digits), " (delay ", g_positions[g_posCount-1].delaySeconds, "s)");
        Print("║ T1: ", DoubleToString(g_pendingTrade.intendedTP1, digits));
        Print("║ T2: ", DoubleToString(g_pendingTrade.intendedTP2, digits));
        Print("║ T3: ", DoubleToString(g_pendingTrade.intendedTP3, digits));
        Print("║ Trail: BE+", g_positions[g_posCount-1].randomBEPips, " | L2+", g_positions[g_posCount-1].randomLockPips);
        Print("╚════════════════════════════════════════════════╝");
    }
    else if(ok)
    {
        if(type == ORDER_TYPE_BUY) totalBuys++;
        else totalSells++;
        Print("RSI_MomDiv: Trade opened - Lots: ", DoubleToString(lot, 2));
    }
    else
    {
        Print("RSI_MomDiv ERROR: Trade failed - ", trade.ResultRetcode());
    }
}

void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;

    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                    g_pendingTrade.intendedSL, g_pendingTrade.intendedTP1);
        g_pendingTrade.active = false;
    }
}

//+------------------------------------------------------------------+
//| STEALTH POSITION MANAGEMENT                                       |
//+------------------------------------------------------------------+
void ManageStealthPositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;

        ulong ticket = g_positions[i].ticket;

        if(!PositionSelectByTicket(ticket))
        {
            g_positions[i].active = false;
            continue;
        }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentLots = PositionGetDouble(POSITION_VOLUME);
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
                             SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                             SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // 1. Delayed SL placement
        if(currentSL == 0 && g_positions[i].intendedSL != 0)
        {
            if(TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds)
            {
                double newSL = NormalizeDouble(g_positions[i].intendedSL, digits);
                if(trade.PositionModify(ticket, newSL, 0))
                {
                    Print("RSI_MomDiv: SL set #", ticket, " at ", newSL);
                }
            }
        }

        // Calculate profit in pips
        double profitPips = 0;
        if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - g_positions[i].entryPrice) / point;
        else
            profitPips = (g_positions[i].entryPrice - currentPrice) / point;

        // 2. Target 1
        if(g_positions[i].targetHit < 1)
        {
            bool t1Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP1) ||
                        (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP1);

            if(t1Hit)
            {
                double closeAmount = g_positions[i].initialLots * ClosePercent1 / 100.0;
                closeAmount = MathFloor(closeAmount / lotStep) * lotStep;
                closeAmount = MathMax(closeAmount, minLot);

                if(closeAmount < currentLots && closeAmount >= minLot)
                {
                    if(trade.PositionClosePartial(ticket, closeAmount))
                    {
                        g_positions[i].targetHit = 1;
                        Print("RSI_MomDiv: T1 HIT - Closed ", closeAmount, " lots");

                        // Move SL to BE
                        double beSL;
                        if(posType == POSITION_TYPE_BUY)
                            beSL = g_positions[i].entryPrice + g_positions[i].randomBEPips * point;
                        else
                            beSL = g_positions[i].entryPrice - g_positions[i].randomBEPips * point;

                        beSL = NormalizeDouble(beSL, digits);
                        trade.PositionModify(ticket, beSL, 0);
                    }
                }
                else if(closeAmount >= currentLots)
                {
                    trade.PositionClose(ticket);
                    g_positions[i].active = false;
                    continue;
                }
            }
        }

        // 3. Target 2
        if(g_positions[i].targetHit == 1)
        {
            bool t2Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP2) ||
                        (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP2);

            if(t2Hit)
            {
                if(!PositionSelectByTicket(ticket)) continue;
                currentLots = PositionGetDouble(POSITION_VOLUME);

                double closeAmount = currentLots * ClosePercent2 / 100.0;
                closeAmount = MathFloor(closeAmount / lotStep) * lotStep;
                closeAmount = MathMax(closeAmount, minLot);

                if(closeAmount < currentLots && closeAmount >= minLot)
                {
                    if(trade.PositionClosePartial(ticket, closeAmount))
                    {
                        g_positions[i].targetHit = 2;
                        Print("RSI_MomDiv: T2 HIT - Closed ", closeAmount, " lots");
                    }
                }
                else if(closeAmount >= currentLots)
                {
                    trade.PositionClose(ticket);
                    g_positions[i].active = false;
                    continue;
                }
            }
        }

        // 4. Target 3
        if(g_positions[i].targetHit >= 1)
        {
            bool t3Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP3) ||
                        (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP3);

            if(t3Hit)
            {
                trade.PositionClose(ticket);
                g_positions[i].active = false;
                Print("RSI_MomDiv: T3 HIT - FULL CLOSE");
                continue;
            }
        }

        // 5. 2-Level Trailing
        if(g_positions[i].targetHit >= 1 && currentSL > 0)
        {
            // Level 1: 500 pips -> BE + random
            if(g_positions[i].trailLevel < 1 && profitPips >= TrailActivatePips)
            {
                double newSL;
                if(posType == POSITION_TYPE_BUY)
                    newSL = g_positions[i].entryPrice + g_positions[i].randomBEPips * point;
                else
                    newSL = g_positions[i].entryPrice - g_positions[i].randomBEPips * point;

                newSL = NormalizeDouble(newSL, digits);

                bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                   (posType == POSITION_TYPE_SELL && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 1;
                    Print("RSI_MomDiv: Trail L1 - BE+", g_positions[i].randomBEPips);
                }
            }

            // Level 2: 800 pips -> Lock profit
            if(g_positions[i].trailLevel < 2 && profitPips >= TrailLevel2Pips)
            {
                double newSL;
                if(posType == POSITION_TYPE_BUY)
                    newSL = g_positions[i].entryPrice + g_positions[i].randomLockPips * point;
                else
                    newSL = g_positions[i].entryPrice - g_positions[i].randomLockPips * point;

                newSL = NormalizeDouble(newSL, digits);

                bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                   (posType == POSITION_TYPE_SELL && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 2;
                    Print("RSI_MomDiv: Trail L2 - Lock+", g_positions[i].randomLockPips);
                }
            }
        }
    }

    // Cleanup
    CleanupPositions();
}

void CleanupPositions()
{
    int newCount = 0;
    for(int i = 0; i < g_posCount; i++)
    {
        if(g_positions[i].active)
        {
            if(i != newCount)
                g_positions[newCount] = g_positions[i];
            newCount++;
        }
    }

    if(newCount != g_posCount)
    {
        g_posCount = newCount;
        ArrayResize(g_positions, g_posCount);
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    // Always manage positions
    ProcessPendingTrade();
    ManageStealthPositions();

    // Only check for new signals on new bar
    if(!IsNewBar()) return;

    // Update divergence zones
    UpdateZones();

    // Detect new divergences
    DetectDivergences();

    // Check filters
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;
    if(g_pendingTrade.active) return;

    // Get signal
    int signal = GetTradeSignal();

    if(signal == 1)
    {
        Print("=== RSI_MOMDIV BUY SIGNAL ===");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(signal == -1)
    {
        Print("=== RSI_MOMDIV SELL SIGNAL ===");
        QueueTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
