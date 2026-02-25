//+------------------------------------------------------------------+
//|                                         AbsorptionScalper_Cla.mq5|
//|      *** Absorption Bubbles + PRO Scalper Combined Strategy ***  |
//|                   + Stealth Mode v2.1 (Novi Prompt Aligned)      |
//|                   Version 1.0 - 2026-02-25                       |
//+------------------------------------------------------------------+
//| Strategy: 83% Win Rate Concept                                   |
//| - Absorption Bubbles: Detect volume absorption at key levels     |
//| - PRO Scalper: VWAP + Trend + Supply/Demand zones               |
//| - BUY: Buy signal + recent bullish absorption (red bubble)       |
//| - SELL: Sell signal + recent bearish absorption (green bubble)   |
//+------------------------------------------------------------------+
#property copyright "AbsorptionScalper_Cla - Combined Strategy (2026-02-25)"
#property version   "1.00"
#property strict

#include <Trade\\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== ABSORPTION BUBBLES POSTAVKE ==="
input int      AbsLookbackPeriod   = 20;      // Lookback za volume normalizaciju
input double   AbsThreshold        = 2.0;     // Prag za detekciju absorpcije (stdev)
input int      AbsValidBars        = 5;       // Koliko bara absorpcija ostaje validna
input double   WickRatio           = 0.6;     // Min omjer wicka vs tijela svijeće

input group "=== SESSION VWAP POSTAVKE ==="
input bool     UseVWAP             = true;    // Koristi VWAP filter
input ENUM_TIMEFRAMES VWAPSession  = PERIOD_D1; // VWAP reset period

input group "=== TREND FILTER POSTAVKE ==="
input bool     UseTrendFilter      = true;    // Koristi Trend filter
input int      TrendEMA_Fast       = 9;       // Brzi EMA za trend
input int      TrendEMA_Slow       = 21;      // Spori EMA za trend
input int      TrendADX_Period     = 14;      // ADX period
input double   TrendADX_Min        = 20.0;    // Minimalni ADX za trend
input bool     UseHTF_Trend        = true;    // Koristi H1 trend filter
input int      HTF_EMA_Period      = 50;      // H1 EMA period

input group "=== SUPPLY/DEMAND ZONES ==="
input bool     UseSDZones          = true;    // Koristi Supply/Demand zone
input int      SDZone_Lookback     = 50;      // Lookback za pivot zone
input int      SDZone_Strength     = 3;       // Snaga pivota (lijevo/desno)
input double   SDZone_ATR_Mult     = 0.5;     // ATR množitelj za širinu zone

input group "=== DELTA PROXY (Volume Confirmation) ==="
input bool     UseDeltaProxy       = true;    // Koristi Delta proxy
input int      DeltaLookback       = 10;      // Lookback za delta analizu

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent         = 1.0;     // Risk % po tradeu
input int      ATRPeriod           = 14;      // ATR period
input double   SLMultiplier        = 2.0;     // SL = ATR x množitelj
input double   Target1_ATR         = 1.5;     // Target 1 (ATR x)
input double   Target2_ATR         = 2.5;     // Target 2 (ATR x)
input double   Target3_ATR         = 4.0;     // Target 3 (ATR x)
input int      ClosePercent1       = 33;      // % za zatvaranje na T1
input int      ClosePercent2       = 50;      // % ostatka za T2

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode      = true;    // Stealth mod (TP nikad na broker)
input int      OpenDelayMin        = 0;       // Min delay otvaranja (sekunde)
input int      OpenDelayMax        = 4;       // Max delay otvaranja
input int      SLDelayMin          = 7;       // Min delay SL postavljanja
input int      SLDelayMax          = 13;      // Max delay SL postavljanja
input double   LargeCandleATR      = 3.0;     // Filter velikih svijeća

input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips   = 500;     // Aktivacija trailinga (pipsi)
input int      TrailBEPipsMin      = 38;      // BE + min pipsi
input int      TrailBEPipsMax      = 43;      // BE + max pipsi
input int      TrailLevel2Pips     = 800;     // Level 2 aktivacija
input int      TrailLockPipsMin    = 150;     // Lock min pipsi
input int      TrailLockPipsMax    = 200;     // Lock max pipsi

input group "=== FILTERI ==="
input double   MaxSpread           = 50;      // Max spread (points)
input bool     UseNewsFilter       = false;   // News filter (placeholder)

input group "=== OPĆE ==="
input ulong    MagicNumber         = 778899;  // Magic broj
input int      Slippage            = 30;      // Slippage (points)

//+------------------------------------------------------------------+
//| GLOBAL STRUCTURES                                                 |
//+------------------------------------------------------------------+
struct AbsorptionEvent
{
    datetime time;
    int      barIndex;
    bool     isBullish;     // true = red bubble (bullish absorption)
    double   strength;
    double   price;
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
    int      targetHit;       // 0=none, 1=T1, 2=T2, 3=T3
    int      trailLevel;      // 0=none, 1=BE, 2=Lock
};

struct SDZone
{
    double   priceTop;
    double   priceBottom;
    bool     isSupply;        // true=supply(resistance), false=demand(support)
    int      touches;
    bool     fresh;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade trade;
int atrHandle;
int adxHandle;
int emaFastHandle;
int emaSlowHandle;
int htfEmaHandle;

datetime lastBarTime;
AbsorptionEvent g_absorptions[];
int g_absCount = 0;

PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;

SDZone g_supplyZones[];
SDZone g_demandZones[];
int g_supplyCount = 0;
int g_demandCount = 0;

double g_sessionVWAP = 0;
double g_sessionVWAPSum = 0;
double g_sessionVolSum = 0;
datetime g_sessionStart = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Initialize indicators
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ATR handle");
        return INIT_FAILED;
    }

    adxHandle = iADX(_Symbol, PERIOD_CURRENT, TrendADX_Period);
    if(adxHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ADX handle");
        return INIT_FAILED;
    }

    emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

    if(UseHTF_Trend)
    {
        htfEmaHandle = iMA(_Symbol, PERIOD_H1, HTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
        if(htfEmaHandle == INVALID_HANDLE)
        {
            Print("WARNING: Failed to create H1 EMA handle");
        }
    }

    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0);
    g_posCount = 0;

    ArrayResize(g_absorptions, 0);
    g_absCount = 0;

    ArrayResize(g_supplyZones, 0);
    ArrayResize(g_demandZones, 0);
    g_supplyCount = 0;
    g_demandCount = 0;

    ResetSessionVWAP();

    Print("=== AbsorptionScalper_Cla v1.0 INITIALIZED ===");
    Print("Strategy: Absorption Bubbles + PRO Scalper (83% WR Concept)");
    Print("Stealth Mode: ", UseStealthMode ? "ENABLED" : "DISABLED");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
    if(htfEmaHandle != INVALID_HANDLE) IndicatorRelease(htfEmaHandle);
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

double GetADX()
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

double GetEMA(int handle, int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
//| TRADING WINDOW - Sunday 00:01 to Friday 11:30                     |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Sunday from 00:01
    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

    // Monday to Thursday - full day
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
        return true;

    // Friday until 11:30
    if(dt.day_of_week == 5)
        return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));

    return false;
}

//+------------------------------------------------------------------+
//| SPREAD FILTER                                                     |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
//| LARGE CANDLE FILTER                                               |
//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    if(!UseStealthMode) return false;

    double atr = GetATR(1);
    if(atr <= 0) return false;

    double candleSize = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleSize > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
//| SESSION VWAP CALCULATION                                          |
//+------------------------------------------------------------------+
void ResetSessionVWAP()
{
    g_sessionVWAPSum = 0;
    g_sessionVolSum = 0;
    g_sessionVWAP = 0;
    g_sessionStart = 0;
}

void UpdateSessionVWAP()
{
    if(!UseVWAP) return;

    // Check if new session started
    datetime currentBarTime = iTime(_Symbol, VWAPSession, 0);
    if(currentBarTime != g_sessionStart)
    {
        ResetSessionVWAP();
        g_sessionStart = currentBarTime;
    }

    // Calculate VWAP incrementally
    double typicalPrice = (iHigh(_Symbol, PERIOD_CURRENT, 1) +
                          iLow(_Symbol, PERIOD_CURRENT, 1) +
                          iClose(_Symbol, PERIOD_CURRENT, 1)) / 3.0;

    long volume[];
    ArraySetAsSeries(volume, true);
    if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, 1, volume) <= 0) return;

    g_sessionVWAPSum += typicalPrice * (double)volume[0];
    g_sessionVolSum += (double)volume[0];

    if(g_sessionVolSum > 0)
        g_sessionVWAP = g_sessionVWAPSum / g_sessionVolSum;
}

//+------------------------------------------------------------------+
//| ABSORPTION DETECTION                                              |
//| Red bubble on lower wick = BULLISH absorption (buyers absorb)     |
//| Green bubble on upper wick = BEARISH absorption (sellers absorb)  |
//+------------------------------------------------------------------+
void DetectAbsorption()
{
    // Get volume data
    long volumes[];
    ArraySetAsSeries(volumes, true);
    if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, AbsLookbackPeriod + 2, volumes) <= 0)
        return;

    // Calculate volume mean and stdev
    double sum = 0;
    for(int i = 1; i <= AbsLookbackPeriod; i++)
        sum += (double)volumes[i];
    double mean = sum / (double)AbsLookbackPeriod;

    double sqSum = 0;
    for(int i = 1; i <= AbsLookbackPeriod; i++)
        sqSum += MathPow((double)volumes[i] - mean, 2);
    double stdev = MathSqrt(sqSum / (double)AbsLookbackPeriod);

    if(stdev <= 0) return;

    // Analyze bar 1 (completed bar)
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low = iLow(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);

    double body = MathAbs(close - open);
    double upperWick = high - MathMax(open, close);
    double lowerWick = MathMin(open, close) - low;
    double totalRange = high - low;

    if(totalRange <= 0) return;

    // Normalized volume (Z-score)
    double normalizedVol = ((double)volumes[1] - mean) / stdev;

    // Check for absorption (high volume + significant wick)
    if(normalizedVol >= AbsThreshold)
    {
        bool isBullish = false;
        bool isAbsorption = false;
        double strength = normalizedVol;
        double absPrice = 0;

        // Bullish absorption: strong lower wick (buyers absorbing selling)
        if(lowerWick > body * WickRatio && lowerWick > upperWick)
        {
            isBullish = true;
            isAbsorption = true;
            absPrice = low;
        }
        // Bearish absorption: strong upper wick (sellers absorbing buying)
        else if(upperWick > body * WickRatio && upperWick > lowerWick)
        {
            isBullish = false;
            isAbsorption = true;
            absPrice = high;
        }

        if(isAbsorption)
        {
            // Add to absorption array
            ArrayResize(g_absorptions, g_absCount + 1);
            g_absorptions[g_absCount].time = iTime(_Symbol, PERIOD_CURRENT, 1);
            g_absorptions[g_absCount].barIndex = 1;
            g_absorptions[g_absCount].isBullish = isBullish;
            g_absorptions[g_absCount].strength = strength;
            g_absorptions[g_absCount].price = absPrice;
            g_absCount++;

            Print("ABSORPTION DETECTED: ", isBullish ? "BULLISH (Red Bubble)" : "BEARISH (Green Bubble)",
                  " Strength: ", DoubleToString(strength, 2),
                  " Price: ", DoubleToString(absPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
        }
    }

    // Clean up old absorptions
    CleanupAbsorptions();
}

void CleanupAbsorptions()
{
    int newCount = 0;
    for(int i = 0; i < g_absCount; i++)
    {
        // Increment bar index
        g_absorptions[i].barIndex++;

        // Keep if still valid
        if(g_absorptions[i].barIndex <= AbsValidBars)
        {
            if(i != newCount)
                g_absorptions[newCount] = g_absorptions[i];
            newCount++;
        }
    }

    if(newCount != g_absCount)
    {
        g_absCount = newCount;
        ArrayResize(g_absorptions, g_absCount);
    }
}

bool HasRecentBullishAbsorption()
{
    for(int i = 0; i < g_absCount; i++)
    {
        if(g_absorptions[i].isBullish && g_absorptions[i].barIndex <= AbsValidBars)
            return true;
    }
    return false;
}

bool HasRecentBearishAbsorption()
{
    for(int i = 0; i < g_absCount; i++)
    {
        if(!g_absorptions[i].isBullish && g_absorptions[i].barIndex <= AbsValidBars)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| SUPPLY/DEMAND ZONE DETECTION                                      |
//+------------------------------------------------------------------+
void DetectSDZones()
{
    if(!UseSDZones) return;

    double high[], low[], close[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, SDZone_Lookback + 10, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, SDZone_Lookback + 10, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, SDZone_Lookback + 10, close) <= 0) return;

    double atr = GetATR(1);
    if(atr <= 0) return;

    double zoneWidth = atr * SDZone_ATR_Mult;

    // Reset zones
    ArrayResize(g_supplyZones, 0);
    ArrayResize(g_demandZones, 0);
    g_supplyCount = 0;
    g_demandCount = 0;

    // Find pivot highs (supply zones) and pivot lows (demand zones)
    for(int i = SDZone_Strength + 1; i < SDZone_Lookback - SDZone_Strength; i++)
    {
        // Check for pivot high (supply zone)
        bool isPivotHigh = true;
        for(int j = 1; j <= SDZone_Strength; j++)
        {
            if(high[i] <= high[i-j] || high[i] <= high[i+j])
            {
                isPivotHigh = false;
                break;
            }
        }

        if(isPivotHigh)
        {
            ArrayResize(g_supplyZones, g_supplyCount + 1);
            g_supplyZones[g_supplyCount].priceTop = high[i] + zoneWidth;
            g_supplyZones[g_supplyCount].priceBottom = high[i] - zoneWidth;
            g_supplyZones[g_supplyCount].isSupply = true;
            g_supplyZones[g_supplyCount].touches = 0;
            g_supplyZones[g_supplyCount].fresh = true;
            g_supplyCount++;
        }

        // Check for pivot low (demand zone)
        bool isPivotLow = true;
        for(int j = 1; j <= SDZone_Strength; j++)
        {
            if(low[i] >= low[i-j] || low[i] >= low[i+j])
            {
                isPivotLow = false;
                break;
            }
        }

        if(isPivotLow)
        {
            ArrayResize(g_demandZones, g_demandCount + 1);
            g_demandZones[g_demandCount].priceTop = low[i] + zoneWidth;
            g_demandZones[g_demandCount].priceBottom = low[i] - zoneWidth;
            g_demandZones[g_demandCount].isSupply = false;
            g_demandZones[g_demandCount].touches = 0;
            g_demandZones[g_demandCount].fresh = true;
            g_demandCount++;
        }
    }
}

bool IsNearDemandZone(double price)
{
    for(int i = 0; i < g_demandCount; i++)
    {
        if(price >= g_demandZones[i].priceBottom && price <= g_demandZones[i].priceTop)
            return true;
    }
    return false;
}

bool IsNearSupplyZone(double price)
{
    for(int i = 0; i < g_supplyCount; i++)
    {
        if(price >= g_supplyZones[i].priceBottom && price <= g_supplyZones[i].priceTop)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| TREND FILTER                                                      |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
    if(!UseTrendFilter) return 0; // No filter = allow all

    double emaFast = GetEMA(emaFastHandle, 1);
    double emaSlow = GetEMA(emaSlowHandle, 1);
    double adx = GetADX();

    if(emaFast <= 0 || emaSlow <= 0) return 0;

    // Check ADX strength
    if(adx < TrendADX_Min) return 0; // No clear trend

    // Check EMA alignment
    if(emaFast > emaSlow) return 1;  // Bullish
    if(emaFast < emaSlow) return -1; // Bearish

    return 0;
}

int GetHTFTrend()
{
    if(!UseHTF_Trend || htfEmaHandle == INVALID_HANDLE) return 0;

    double htfEma = GetEMA(htfEmaHandle, 1);
    if(htfEma <= 0) return 0;

    double currentPrice = iClose(_Symbol, PERIOD_CURRENT, 1);

    if(currentPrice > htfEma) return 1;  // Bullish
    if(currentPrice < htfEma) return -1; // Bearish

    return 0;
}

//+------------------------------------------------------------------+
//| DELTA PROXY (Volume-based directional bias)                       |
//+------------------------------------------------------------------+
int GetDeltaProxy()
{
    if(!UseDeltaProxy) return 0;

    double close[];
    long volume[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(volume, true);

    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, DeltaLookback + 1, close) <= 0) return 0;
    if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, DeltaLookback + 1, volume) <= 0) return 0;

    double buyVol = 0;
    double sellVol = 0;

    for(int i = 1; i <= DeltaLookback; i++)
    {
        double change = close[i-1] - close[i];
        if(change > 0)
            buyVol += (double)volume[i];
        else if(change < 0)
            sellVol += (double)volume[i];
    }

    if(buyVol > sellVol * 1.2) return 1;  // Bullish delta
    if(sellVol > buyVol * 1.2) return -1; // Bearish delta

    return 0;
}

//+------------------------------------------------------------------+
//| VWAP BIAS                                                         |
//+------------------------------------------------------------------+
int GetVWAPBias()
{
    if(!UseVWAP || g_sessionVWAP <= 0) return 0;

    double currentPrice = iClose(_Symbol, PERIOD_CURRENT, 1);

    if(currentPrice > g_sessionVWAP) return 1;  // Above VWAP = bullish
    if(currentPrice < g_sessionVWAP) return -1; // Below VWAP = bearish

    return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL GENERATION - Combined Strategy                             |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
    // Core requirement: Must have recent absorption
    bool bullishAbs = HasRecentBullishAbsorption();
    bool bearishAbs = HasRecentBearishAbsorption();

    if(!bullishAbs && !bearishAbs)
        return 0; // No absorption = no trade

    // Get all filters
    int trend = GetTrendDirection();
    int htfTrend = GetHTFTrend();
    int delta = GetDeltaProxy();
    int vwapBias = GetVWAPBias();

    double currentPrice = iClose(_Symbol, PERIOD_CURRENT, 1);
    bool nearDemand = IsNearDemandZone(currentPrice);
    bool nearSupply = IsNearSupplyZone(currentPrice);

    // Calculate bullish score
    int bullScore = 0;
    if(bullishAbs) bullScore += 3;  // Absorption is key
    if(trend == 1) bullScore += 2;
    if(htfTrend == 1) bullScore += 2;
    if(delta == 1) bullScore += 1;
    if(vwapBias == 1) bullScore += 1;
    if(nearDemand) bullScore += 2;  // Bounce from demand

    // Calculate bearish score
    int bearScore = 0;
    if(bearishAbs) bearScore += 3;  // Absorption is key
    if(trend == -1) bearScore += 2;
    if(htfTrend == -1) bearScore += 2;
    if(delta == -1) bearScore += 1;
    if(vwapBias == -1) bearScore += 1;
    if(nearSupply) bearScore += 2;  // Rejection from supply

    // Need minimum score and absorption must align
    int minScore = 5; // Require at least absorption + 2 confirmations

    // BUY signal: Bullish absorption + confirmations
    if(bullishAbs && bullScore >= minScore && bullScore > bearScore)
    {
        // Additional check: Don't buy into supply
        if(!nearSupply)
        {
            Print("BUY SIGNAL - Score: ", bullScore,
                  " | Trend: ", trend, " | HTF: ", htfTrend,
                  " | Delta: ", delta, " | VWAP: ", vwapBias,
                  " | Near Demand: ", nearDemand);
            return 1;
        }
    }

    // SELL signal: Bearish absorption + confirmations
    if(bearishAbs && bearScore >= minScore && bearScore > bullScore)
    {
        // Additional check: Don't sell into demand
        if(!nearDemand)
        {
            Print("SELL SIGNAL - Score: ", bearScore,
                  " | Trend: ", trend, " | HTF: ", htfTrend,
                  " | Delta: ", delta, " | VWAP: ", vwapBias,
                  " | Near Supply: ", nearSupply);
            return -1;
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

        Print("AbsorptionScalper: Trade QUEUED - ",
              (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
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
    tp = NormalizeDouble(tp, digits);

    bool ok;

    if(UseStealthMode)
    {
        // Stealth: No SL/TP to broker
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, 0, 0, "AbsScalp") :
             trade.Sell(lot, _Symbol, price, 0, 0, "AbsScalp");
    }
    else
    {
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, sl, tp, "AbsScalp BUY") :
             trade.Sell(lot, _Symbol, price, sl, tp, "AbsScalp SELL");
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

        Print("AbsorptionScalper STEALTH: Opened #", ticket,
              " Lots: ", DoubleToString(lot, 2),
              " Entry: ", DoubleToString(price, digits));
    }
    else if(ok)
    {
        Print("AbsorptionScalper: Trade opened - Lots: ", DoubleToString(lot, 2));
    }
    else
    {
        Print("AbsorptionScalper ERROR: Trade failed - ", trade.ResultRetcode());
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
                    Print("AbsorptionScalper: SL set for #", ticket, " at ", newSL);
                }
            }
        }

        // Calculate profit in pips
        double profitPips = 0;
        if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - g_positions[i].entryPrice) / point;
        else
            profitPips = (g_positions[i].entryPrice - currentPrice) / point;

        // 2. Target management (partial closes)
        // Target 1
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
                        Print("AbsorptionScalper: T1 HIT - Closed ", closeAmount, " lots");

                        // Move SL to BE + random pips
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
                    Print("AbsorptionScalper: T1 FULL CLOSE");
                    continue;
                }
            }
        }

        // Target 2
        if(g_positions[i].targetHit == 1)
        {
            bool t2Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP2) ||
                        (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP2);

            if(t2Hit)
            {
                // Recalculate remaining lots
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
                        Print("AbsorptionScalper: T2 HIT - Closed ", closeAmount, " lots");
                    }
                }
                else if(closeAmount >= currentLots)
                {
                    trade.PositionClose(ticket);
                    g_positions[i].active = false;
                    Print("AbsorptionScalper: T2 FULL CLOSE");
                    continue;
                }
            }
        }

        // Target 3
        if(g_positions[i].targetHit >= 1)
        {
            bool t3Hit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP3) ||
                        (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP3);

            if(t3Hit)
            {
                trade.PositionClose(ticket);
                g_positions[i].active = false;
                Print("AbsorptionScalper: T3 HIT - FULL CLOSE");
                continue;
            }
        }

        // 3. Trailing stop management (after T1)
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
                    Print("AbsorptionScalper: Trail L1 activated - BE+", g_positions[i].randomBEPips);
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
                    Print("AbsorptionScalper: Trail L2 activated - Lock+", g_positions[i].randomLockPips);
                }
            }
        }
    }

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
    // Always process pending trades and manage positions
    ProcessPendingTrade();
    ManageStealthPositions();

    // Only check for new signals on new bar
    if(!IsNewBar()) return;

    // Update indicators
    UpdateSessionVWAP();
    DetectAbsorption();
    DetectSDZones();

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
        Print("=== AbsorptionScalper BUY SIGNAL ===");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(signal == -1)
    {
        Print("=== AbsorptionScalper SELL SIGNAL ===");
        QueueTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
