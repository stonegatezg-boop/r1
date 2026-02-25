//+------------------------------------------------------------------+
//|                                                  Mix1_ADX_Cla.mq5|
//|      *** Mix1 EMA Cross + Trend Channel + ADX/DI Histogram ***   |
//|                   + Stealth Mode v2.1                            |
//|                   Based on @gu5tavo71 TradingView Indicator      |
//|                   Version 1.0 - 2026-02-25                       |
//+------------------------------------------------------------------+
//| Strategy:                                                        |
//| - EMA Cross (26/50) for trend direction                          |
//| - SMA 200 + ATR Channel for trend strength                       |
//| - ADX/DI Histogram for momentum confirmation                     |
//| BUY: TrendDir=1 + Bullish candle + DI+ > DI-                     |
//| SELL: TrendDir=-1 + Bearish candle + DI- > DI+                   |
//+------------------------------------------------------------------+
#property copyright "Mix1_ADX_Cla v1.0 (2026-02-25)"
#property version   "1.00"
#property strict

#include <Trade\\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== EMA CROSS POSTAVKE ==="
input int      EMA_Fast           = 26;      // EMA Fast period
input int      EMA_Medium         = 50;      // EMA Medium period
input ENUM_APPLIED_PRICE EMA_Price = PRICE_CLOSE; // EMA Applied price

input group "=== TREND CHANNEL POSTAVKE ==="
input int      MA_Trend           = 200;     // MA Trend period
input bool     UseSMA             = true;    // Koristi SMA (false = EMA)
input double   Channel_ATR_Mult   = 0.618;   // ATR množitelj za kanal

input group "=== ADX/DI POSTAVKE ==="
input int      ADX_Period         = 14;      // ADX period
input int      ADX_Threshold      = 22;      // ADX prag za jak trend
input double   DI_Buffer          = 10.0;    // DI buffer % (DI+ mora biti > DI- + buffer%)

input group "=== SIGNAL POTVRDA ==="
input bool     RequireCandleConf  = true;    // Zahtijevaj bull/bear svijeću
input bool     RequireADXConf     = true;    // Zahtijevaj ADX potvrdu

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent        = 1.0;     // Risk % po tradeu
input double   RR_Ratio           = 1.5;     // Risk:Reward ratio
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
input ulong    MagicNumber        = 261450;  // Magic broj
input int      Slippage           = 30;      // Slippage (points)

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
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
int adxHandle;
int emaFastHandle;
int emaMedHandle;
int maTrendHandle;

datetime lastBarTime;
int prevTrendDir = 0;

PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;

// Statistics
int totalBuys = 0;
int totalSells = 0;

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

    adxHandle = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
    if(adxHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ADX handle");
        return INIT_FAILED;
    }

    emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, EMA_Price);
    emaMedHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Medium, 0, MODE_EMA, EMA_Price);

    if(UseSMA)
        maTrendHandle = iMA(_Symbol, PERIOD_CURRENT, MA_Trend, 0, MODE_SMA, PRICE_CLOSE);
    else
        maTrendHandle = iMA(_Symbol, PERIOD_CURRENT, MA_Trend, 0, MODE_EMA, PRICE_CLOSE);

    if(emaFastHandle == INVALID_HANDLE || emaMedHandle == INVALID_HANDLE || maTrendHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create MA handles");
        return INIT_FAILED;
    }

    lastBarTime = 0;
    prevTrendDir = 0;
    g_pendingTrade.active = false;

    ArrayResize(g_positions, 0);
    g_posCount = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     MIX1 EMA CROSS + TREND CHANNEL + ADX/DI CLA v1.0          ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ EMA Fast: ", EMA_Fast, " | EMA Med: ", EMA_Medium, " | MA Trend: ", MA_Trend);
    Print("║ Channel ATR: ", Channel_ATR_Mult, " | ADX Threshold: ", ADX_Threshold);
    Print("║ DI Buffer: ", DI_Buffer, "%");
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
    if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaMedHandle != INVALID_HANDLE) IndicatorRelease(emaMedHandle);
    if(maTrendHandle != INVALID_HANDLE) IndicatorRelease(maTrendHandle);

    Print("═══════════════════════════════════════════════════");
    Print("     MIX1_ADX CLA - ZAVRŠNA STATISTIKA");
    Print("═══════════════════════════════════════════════════");
    Print("Total BUY: ", totalBuys, " | SELL: ", totalSells);
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

double GetMA(int handle, int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
    return buf[0];
}

double GetADX(int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 0, shift, 1, buf) <= 0) return 0;
    return buf[0];
}

double GetDIPlus(int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 1, shift, 1, buf) <= 0) return 0;
    return buf[0];
}

double GetDIMinus(int shift = 1)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 2, shift, 1, buf) <= 0) return 0;
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
//| TREND DIRECTION CALCULATION                                       |
//| Based on Mix1 Strategy 2 logic                                    |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
    double emaFast = GetMA(emaFastHandle, 1);
    double emaMed = GetMA(emaMedHandle, 1);
    double maTrend = GetMA(maTrendHandle, 1);
    double atr = GetATR(1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);
    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);

    if(emaFast <= 0 || emaMed <= 0 || maTrend <= 0 || atr <= 0)
        return 0;

    // MA Direction: Fast EMA vs Medium EMA
    int maDir = (emaFast > emaMed) ? 1 : -1;

    // Trend Direction: Price vs MA Trend
    int maTrendDir = (close >= maTrend) ? 1 : -1;

    // Channel Range
    double rangeTop = maTrend + atr * Channel_ATR_Mult;
    double rangeBot = maTrend - atr * Channel_ATR_Mult;

    // Check if price is inside channel (range)
    bool inChannel = (open <= rangeTop || close <= rangeTop) &&
                     (open >= rangeBot || close >= rangeBot);

    // Strategy 2 logic:
    // If in channel -> neutral (0)
    // If maTrendDir == 1 AND maDir == 1 -> bullish (1)
    // If maTrendDir == -1 AND maDir == -1 -> bearish (-1)

    if(inChannel)
        return 0;

    if(maTrendDir == 1 && maDir == 1)
        return 1;

    if(maTrendDir == -1 && maDir == -1)
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| ADX/DI HISTOGRAM ANALYSIS                                         |
//+------------------------------------------------------------------+
int GetADXDISignal()
{
    double adx = GetADX(1);
    double diPlus = GetDIPlus(1);
    double diMinus = GetDIMinus(1);

    if(adx <= 0 || diPlus <= 0 || diMinus <= 0)
        return 0;

    // Calculate DI histogram value (similar to Pine Script)
    // Bullish: DI+ > DI- + (DI+ * buffer%)
    // Bearish: DI- > DI+ + (DI- * buffer%)

    double bufferPlus = diPlus * DI_Buffer / 100.0;
    double bufferMinus = diMinus * DI_Buffer / 100.0;

    bool bullish = (diPlus > (diMinus + bufferPlus));
    bool bearish = (diMinus > (diPlus + bufferMinus));

    // Strong bullish: DI+ > DI- with buffer AND ADX > threshold
    if(bullish && adx > ADX_Threshold)
        return 1;

    // Strong bearish: DI- > DI+ with buffer AND ADX > threshold
    if(bearish && adx > ADX_Threshold)
        return -1;

    // Weak bullish (ADX between 11-25)
    if(bullish && adx > 11)
        return 1;

    // Weak bearish (ADX between 11-25)
    if(bearish && adx > 11)
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| CANDLE CONFIRMATION                                               |
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
//| SIGNAL GENERATION                                                 |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
    int trendDir = GetTrendDirection();
    int adxSignal = GetADXDISignal();

    // Check for trend change (new signal)
    bool newBullTrend = (trendDir == 1 && prevTrendDir != 1);
    bool newBearTrend = (trendDir == -1 && prevTrendDir != -1);

    prevTrendDir = trendDir;

    //=== BUY CONDITIONS ===
    // 1. Trend direction is bullish (or just turned bullish)
    // 2. ADX/DI confirms bullish momentum
    // 3. Bullish candle (optional)
    if(trendDir == 1)
    {
        bool adxConf = !RequireADXConf || (adxSignal == 1);
        bool candleConf = !RequireCandleConf || IsBullishCandle(1);

        if(adxConf && candleConf)
        {
            double adx = GetADX(1);
            double diPlus = GetDIPlus(1);
            double diMinus = GetDIMinus(1);

            Print("BUY SIGNAL: TrendDir=", trendDir,
                  " | ADX=", DoubleToString(adx, 1),
                  " | DI+=", DoubleToString(diPlus, 1),
                  " | DI-=", DoubleToString(diMinus, 1));
            return 1;
        }
    }

    //=== SELL CONDITIONS ===
    // 1. Trend direction is bearish (or just turned bearish)
    // 2. ADX/DI confirms bearish momentum
    // 3. Bearish candle (optional)
    if(trendDir == -1)
    {
        bool adxConf = !RequireADXConf || (adxSignal == -1);
        bool candleConf = !RequireCandleConf || IsBearishCandle(1);

        if(adxConf && candleConf)
        {
            double adx = GetADX(1);
            double diPlus = GetDIPlus(1);
            double diMinus = GetDIMinus(1);

            Print("SELL SIGNAL: TrendDir=", trendDir,
                  " | ADX=", DoubleToString(adx, 1),
                  " | DI+=", DoubleToString(diPlus, 1),
                  " | DI-=", DoubleToString(diMinus, 1));
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

        Print("Mix1_ADX: Trade QUEUED - ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
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
             trade.Buy(lot, _Symbol, price, 0, 0, "MIX1") :
             trade.Sell(lot, _Symbol, price, 0, 0, "MIX1");
    }
    else
    {
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(lot, _Symbol, price, sl, tp, "MIX1 BUY") :
             trade.Sell(lot, _Symbol, price, sl, tp, "MIX1 SELL");
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
        Print("║ MIX1_ADX STEALTH ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", ticket);
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
        Print("Mix1_ADX: Trade opened - Lots: ", DoubleToString(lot, 2));
    }
    else
    {
        Print("Mix1_ADX ERROR: Trade failed - ", trade.ResultRetcode());
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
                    Print("Mix1_ADX: SL set #", ticket, " at ", newSL);
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
                        Print("Mix1_ADX: T1 HIT - Closed ", closeAmount, " lots");

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
                        Print("Mix1_ADX: T2 HIT - Closed ", closeAmount, " lots");
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
                Print("Mix1_ADX: T3 HIT - FULL CLOSE");
                continue;
            }
        }

        // 5. 2-Level Trailing
        if(g_positions[i].targetHit >= 1 && currentSL > 0)
        {
            // Level 1
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
                    Print("Mix1_ADX: Trail L1 - BE+", g_positions[i].randomBEPips);
                }
            }

            // Level 2
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
                    Print("Mix1_ADX: Trail L2 - Lock+", g_positions[i].randomLockPips);
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
        Print("=== MIX1_ADX BUY SIGNAL ===");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(signal == -1)
    {
        Print("=== MIX1_ADX SELL SIGNAL ===");
        QueueTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
