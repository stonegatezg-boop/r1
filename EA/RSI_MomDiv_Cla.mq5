//+------------------------------------------------------------------+
//|                                             RSI_MomDiv_Cla.mq5   |
//|        *** RSI Momentum Divergence Zones Strategy ***            |
//|                   + Stealth Mode v2.2                            |
//|                   Based on ChartPrime TradingView Indicator      |
//|                   Version 2.2 - 2026-03-04                       |
//|                   Fixed: 04.03.2026 - SL ODMAH, 3-level trail    |
//+------------------------------------------------------------------+
//| Strategy:                                                        |
//| - RSI based on Momentum (rate of change) instead of price        |
//| - Detects Bullish Divergence: Price LL + RSI HL                  |
//| - Detects Bearish Divergence: Price HH + RSI LH                  |
//| - Creates dynamic support/resistance zones from divergences      |
//| - Entry on zone bounce with confirmation                         |
//+------------------------------------------------------------------+
#property copyright "RSI_MomDiv_Cla v2.2 (2026-03-04)"
#property version   "2.22"
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
input double   LargeCandleATR     = 3.0;     // Filter velikih svijeća

input group "=== TRAILING POSTAVKE (3 LEVEL + MFE) ==="
input int      TrailLevel1_Pips   = 500;     // Level 1: aktivacija (pips)
input int      TrailLevel1_BE     = 40;      // Level 1: BE + pips
input int      TrailLevel2_Pips   = 800;     // Level 2: aktivacija (pips)
input int      TrailLevel2_Lock   = 150;     // Level 2: lock profit pips
input int      TrailLevel3_Pips   = 1200;    // Level 3: aktivacija (pips)
input int      TrailLevel3_Lock   = 200;     // Level 3: lock profit pips
input int      MFE_ActivatePips   = 1500;    // MFE trailing aktivacija
input int      MFE_TrailDistance  = 500;     // MFE udaljenost od vrha

input group "=== FAILURE EXIT POSTAVKE ==="
input int      EarlyFailurePips   = 800;     // Rani izlaz ako gubitak > X pips
input int      TimeFailureBars    = 3;       // Izlaz ako nema profita nakon X bara
input int      TimeFailureMinPips = 20;      // Min profit za ostanak

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

struct StealthPosInfo
{
    bool     active;
    ulong    ticket;
    double   stealthTP1;
    double   stealthTP2;
    double   stealthTP3;
    double   entryPrice;
    double   initialLots;
    datetime openTime;
    int      targetHit;
    int      trailLevel;
    double   maxProfitPips;
    int      barsInTrade;
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

StealthPosInfo g_positions[];
int g_posCount = 0;

double pipValue = 0.01; // XAUUSD: 1 pip = 0.01

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

    // pipValue za XAUUSD
    pipValue = 0.01;
    if(StringFind(_Symbol, "JPY") >= 0) pipValue = 0.01;
    else if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) pipValue = 0.01;
    else if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5) pipValue = 0.0001;

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     RSI MOMENTUM DIVERGENCE ZONES CLA v2.2                    ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ RSI Length: ", RSI_Length, " | Momentum: ", Momentum_Period);
    Print("║ Pivot: L", PivotLookbackL, " R", PivotLookbackR);
    Print("║ Targets: ", Target1_ATR, "x / ", Target2_ATR, "x / ", Target3_ATR, "x ATR");
    Print("║ Stealth: ", UseStealthMode ? "ON" : "OFF", " | SL: ODMAH");
    Print("║ Trail L1: ", TrailLevel1_Pips, " pips -> BE+", TrailLevel1_BE);
    Print("║ Trail L2: ", TrailLevel2_Pips, " pips -> Lock+", TrailLevel2_Lock);
    Print("║ Trail L3: ", TrailLevel3_Pips, " pips -> Lock+", TrailLevel3_Lock);
    Print("║ MFE: ", MFE_ActivatePips, " pips -> Trail ", MFE_TrailDistance);
    Print("║ Failure: Early -", EarlyFailurePips, " | Time ", TimeFailureBars, " bars <", TimeFailureMinPips, " pips");
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
//| TRADE EXECUTION - SL ODMAH                                       |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(1);
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

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

    sl = NormalizeDouble(sl, digits);
    double lots = CalculateLotSize(SLMultiplier * atr);
    if(lots <= 0) return;

    bool ok;

    // SL ODMAH - pravi SL se postavlja ODMAH, TP ostaje stealth (0)
    if(type == ORDER_TYPE_BUY)
        ok = trade.Buy(lots, _Symbol, price, sl, 0, "RSIM");
    else
        ok = trade.Sell(lots, _Symbol, price, sl, 0, "RSIM");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();

        if(UseStealthMode)
        {
            ArrayResize(g_positions, g_posCount + 1);
            g_positions[g_posCount].active = true;
            g_positions[g_posCount].ticket = ticket;
            g_positions[g_posCount].stealthTP1 = tp1;
            g_positions[g_posCount].stealthTP2 = tp2;
            g_positions[g_posCount].stealthTP3 = tp3;
            g_positions[g_posCount].entryPrice = price;
            g_positions[g_posCount].initialLots = lots;
            g_positions[g_posCount].openTime = TimeCurrent();
            g_positions[g_posCount].targetHit = 0;
            g_positions[g_posCount].trailLevel = 0;
            g_positions[g_posCount].maxProfitPips = 0;
            g_positions[g_posCount].barsInTrade = 0;
            g_posCount++;
        }

        if(type == ORDER_TYPE_BUY) totalBuys++;
        else totalSells++;

        Print("╔════════════════════════════════════════════════╗");
        Print("║ RSI_MOMDIV ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", ticket, " | SL ODMAH");
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", DoubleToString(price, digits), " | Lots: ", DoubleToString(lots, 2));
        Print("║ SL: ", DoubleToString(sl, digits), " (PRAVI SL)");
        Print("║ T1: ", DoubleToString(tp1, digits), " (stealth)");
        Print("║ T2: ", DoubleToString(tp2, digits), " (stealth)");
        Print("║ T3: ", DoubleToString(tp3, digits), " (stealth)");
        Print("╚════════════════════════════════════════════════╝");
    }
    else
    {
        Print("RSI_MomDiv ERROR: Trade failed - ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| GET PROFIT PIPS                                                   |
//+------------------------------------------------------------------+
double GetProfitPips(int idx)
{
    if(!g_positions[idx].active) return 0;
    if(!PositionSelectByTicket(g_positions[idx].ticket)) return 0;

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double profitPips = 0;
    if(posType == POSITION_TYPE_BUY)
        profitPips = (currentPrice - g_positions[idx].entryPrice) / pipValue;
    else
        profitPips = (g_positions[idx].entryPrice - currentPrice) / pipValue;

    return profitPips;
}

//+------------------------------------------------------------------+
//| CHECK TIME EXITS                                                  |
//+------------------------------------------------------------------+
void CheckTimeExits()
{
    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;

        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket))
        {
            g_positions[i].active = false;
            continue;
        }

        double profitPips = GetProfitPips(i);

        // Update bars in trade
        g_positions[i].barsInTrade++;

        // Time failure: X bars with less than Y pips profit
        if(g_positions[i].barsInTrade >= TimeFailureBars && profitPips < TimeFailureMinPips && profitPips > -EarlyFailurePips/2)
        {
            trade.PositionClose(ticket);
            g_positions[i].active = false;
            Print("RSI_MomDiv: TIME EXIT #", ticket, " after ", g_positions[i].barsInTrade, " bars, profit: ", DoubleToString(profitPips, 1), " pips");
        }
    }
}

//+------------------------------------------------------------------+
//| STEALTH POSITION MANAGEMENT - 3 LEVEL + MFE                       |
//+------------------------------------------------------------------+
void ManageStealthPositions()
{
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

        // Calculate profit in pips
        double profitPips = GetProfitPips(i);

        // Update MFE
        if(profitPips > g_positions[i].maxProfitPips)
            g_positions[i].maxProfitPips = profitPips;

        // 0. Early Failure Exit
        if(profitPips <= -EarlyFailurePips)
        {
            trade.PositionClose(ticket);
            g_positions[i].active = false;
            Print("RSI_MomDiv: EARLY FAILURE #", ticket, " at ", DoubleToString(profitPips, 0), " pips");
            continue;
        }

        // 1. Target 1 (stealth)
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
                        Print("RSI_MomDiv: T1 HIT - Closed ", DoubleToString(closeAmount, 2), " lots");
                    }
                }
                else if(closeAmount >= currentLots)
                {
                    trade.PositionClose(ticket);
                    g_positions[i].active = false;
                    Print("RSI_MomDiv: T1 HIT - FULL CLOSE");
                    continue;
                }
            }
        }

        // 2. Target 2 (stealth)
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
                        Print("RSI_MomDiv: T2 HIT - Closed ", DoubleToString(closeAmount, 2), " lots");
                    }
                }
                else if(closeAmount >= currentLots)
                {
                    trade.PositionClose(ticket);
                    g_positions[i].active = false;
                    Print("RSI_MomDiv: T2 HIT - FULL CLOSE");
                    continue;
                }
            }
        }

        // 3. Target 3 (stealth)
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

        // 4. 3-Level Trailing + MFE
        if(currentSL > 0)
        {
            double newSL = currentSL;
            bool shouldModify = false;

            // Level 1: 500 pips -> BE + 40 pips
            if(g_positions[i].trailLevel < 1 && profitPips >= TrailLevel1_Pips)
            {
                if(posType == POSITION_TYPE_BUY)
                    newSL = g_positions[i].entryPrice + TrailLevel1_BE * pipValue;
                else
                    newSL = g_positions[i].entryPrice - TrailLevel1_BE * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                              (posType == POSITION_TYPE_SELL && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 1;
                    Print("RSI_MomDiv: Trail L1 - BE+", TrailLevel1_BE, " pips");
                }
            }

            // Level 2: 800 pips -> Lock 150 pips
            if(g_positions[i].trailLevel < 2 && profitPips >= TrailLevel2_Pips)
            {
                if(posType == POSITION_TYPE_BUY)
                    newSL = g_positions[i].entryPrice + TrailLevel2_Lock * pipValue;
                else
                    newSL = g_positions[i].entryPrice - TrailLevel2_Lock * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                              (posType == POSITION_TYPE_SELL && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 2;
                    Print("RSI_MomDiv: Trail L2 - Lock+", TrailLevel2_Lock, " pips");
                }
            }

            // Level 3: 1200 pips -> Lock 200 pips
            if(g_positions[i].trailLevel < 3 && profitPips >= TrailLevel3_Pips)
            {
                if(posType == POSITION_TYPE_BUY)
                    newSL = g_positions[i].entryPrice + TrailLevel3_Lock * pipValue;
                else
                    newSL = g_positions[i].entryPrice - TrailLevel3_Lock * pipValue;

                newSL = NormalizeDouble(newSL, digits);
                shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                              (posType == POSITION_TYPE_SELL && newSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, newSL, 0))
                {
                    g_positions[i].trailLevel = 3;
                    Print("RSI_MomDiv: Trail L3 - Lock+", TrailLevel3_Lock, " pips");
                }
            }

            // MFE Trailing: aktivacija 1500 pips, trail 500 pips od vrha
            if(g_positions[i].maxProfitPips >= MFE_ActivatePips)
            {
                double mfeSL;
                if(posType == POSITION_TYPE_BUY)
                    mfeSL = g_positions[i].entryPrice + (g_positions[i].maxProfitPips - MFE_TrailDistance) * pipValue;
                else
                    mfeSL = g_positions[i].entryPrice - (g_positions[i].maxProfitPips - MFE_TrailDistance) * pipValue;

                mfeSL = NormalizeDouble(mfeSL, digits);
                shouldModify = (posType == POSITION_TYPE_BUY && mfeSL > currentSL) ||
                              (posType == POSITION_TYPE_SELL && mfeSL < currentSL);

                if(shouldModify && trade.PositionModify(ticket, mfeSL, 0))
                {
                    Print("RSI_MomDiv: MFE Trail - Lock at MFE-", MFE_TrailDistance, " (MFE: ", DoubleToString(g_positions[i].maxProfitPips, 0), " pips)");
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
    ManageStealthPositions();

    // Only check for new signals on new bar
    if(!IsNewBar()) return;

    // Check time exits on new bar
    CheckTimeExits();

    // Update divergence zones
    UpdateZones();

    // Detect new divergences
    DetectDivergences();

    // Check filters
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;

    // Get signal
    int signal = GetTradeSignal();

    if(signal == 1)
    {
        Print("=== RSI_MOMDIV BUY SIGNAL ===");
        OpenTrade(ORDER_TYPE_BUY);
    }
    else if(signal == -1)
    {
        Print("=== RSI_MOMDIV SELL SIGNAL ===");
        OpenTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
