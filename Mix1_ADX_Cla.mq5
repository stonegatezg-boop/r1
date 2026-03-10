//+------------------------------------------------------------------+
//|                                                  Mix1_ADX_Cla.mq5|
//|      *** Mix1 EMA Cross + Trend Channel + ADX/DI Histogram ***   |
//|                   + Stealth Mode v2.3                            |
//|                   Based on @gu5tavo71 TradingView Indicator      |
//|                   Created: 2026-02-25                            |
//|                   Fixed: 04.03.2026 - SL ODMAH, 3-level trail    |
//|                   Fixed: 10.03.2026 - Random SL, BE+@1000, Trail |
//+------------------------------------------------------------------+
//| Strategy:                                                        |
//| - EMA Cross (26/50) for trend direction                          |
//| - SMA 200 + ATR Channel for trend strength                       |
//| - ADX/DI Histogram for momentum confirmation                     |
//| BUY: TrendDir=1 + Bullish candle + DI+ > DI-                     |
//| SELL: TrendDir=-1 + Bearish candle + DI- > DI+                   |
//+------------------------------------------------------------------+
#property copyright "Mix1_ADX_Cla v2.3 (10.03.2026)"
#property version   "2.30"
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
input double   Target1_ATR        = 1.5;     // Target 1 (ATR x)
input double   Target2_ATR        = 2.5;     // Target 2 (ATR x)
input double   Target3_ATR        = 3.5;     // Target 3 (ATR x)
input int      ClosePercent1      = 33;      // % za zatvaranje na T1
input int      ClosePercent2      = 50;      // % ostatka za T2
input int      ATRPeriod          = 14;      // ATR period

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode     = true;    // Stealth mod (TP hidden)
input double   LargeCandleATR     = 3.0;     // Filter velikih svijeća

input group "=== SL POSTAVKE (RANDOM) ==="
input int      InitialSL_Min      = 988;     // SL min pips
input int      InitialSL_Max      = 1054;    // SL max pips

input group "=== TRAILING STANDARD ==="
input int      TrailingStartBE    = 1000;    // BE+ aktivacija (pips profit)
input int      BEOffset_Min       = 41;      // BE+ offset min pips
input int      BEOffset_Max       = 46;      // BE+ offset max pips
input int      TrailingDistance   = 1000;    // Trailing udaljenost (pips)

input group "=== EARLY & TIME FAILURE ==="
input int      EarlyFailurePips   = 800;     // Early failure exit (- pips)
input int      TimeFailureBars    = 3;       // Barova za time failure
input int      TimeFailurePips    = 20;      // Min profit za time failure

input group "=== FILTERI ==="
input double   MaxSpread          = 50;      // Max spread (points)
input bool     UseNewsFilter      = false;   // News filter

input group "=== RADNO VRIJEME (ZAGREB) ==="
input int      ZagrebStartHour    = 8;       // Početak tradinga
input int      ZagrebEndHour      = 22;      // Kraj tradinga
input int      FridayCloseHour    = 20;      // Petak zatvaranje

input group "=== OPĆE ==="
input ulong    MagicNumber        = 261450;  // Magic broj
input int      Slippage           = 30;      // Slippage (points)

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
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
    bool     beActivated;       // BE+ aktiviran
    int      beOffset;          // Random BE offset za ovu poziciju
    double   maxProfitPips;
    int      barsInTrade;
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

StealthPosInfo g_positions[];
int g_posCount = 0;
double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01

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

    ArrayResize(g_positions, 0);
    g_posCount = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    // Set pipValue based on symbol
    string symbol = _Symbol;
    if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
        pipValue = 0.01;
    else if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3 || SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5)
        pipValue = 0.0001;
    else
        pipValue = 0.01;

    Print("╔═══════════════════════════════════════════════════════════════╗");
    Print("║     MIX1 EMA CROSS + TREND CHANNEL + ADX/DI CLA v2.3          ║");
    Print("╠═══════════════════════════════════════════════════════════════╣");
    Print("║ EMA Fast: ", EMA_Fast, " | EMA Med: ", EMA_Medium, " | MA Trend: ", MA_Trend);
    Print("║ Channel ATR: ", Channel_ATR_Mult, " | ADX Threshold: ", ADX_Threshold);
    Print("║ DI Buffer: ", DI_Buffer, "%");
    Print("║ Targets: ", Target1_ATR, "x / ", Target2_ATR, "x / ", Target3_ATR, "x ATR");
    Print("║ SL: RANDOM ", InitialSL_Min, "-", InitialSL_Max, " pips ODMAH");
    Print("║ TP: STEALTH (hidden)");
    Print("║ BE+: @", TrailingStartBE, " pips -> entry+", BEOffset_Min, "-", BEOffset_Max);
    Print("║ TRAILING: ", TrailingDistance, " pips distance");
    Print("║ EARLY FAILURE: -", EarlyFailurePips, " pips");
    Print("║ pipValue: ", pipValue);
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
//| TRADING WINDOW (Zagreb Time)                                      |
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Nedjelja - ne trejdaj do 00:01
    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

    // Subota - ne trejdaj
    if(dt.day_of_week == 6)
        return false;

    // Petak - završi ranije
    if(dt.day_of_week == 5)
    {
        if(dt.hour >= FridayCloseHour) return false;
    }

    // Pon-Pet: Trading window
    if(dt.hour < ZagrebStartHour || dt.hour >= ZagrebEndHour)
        return false;

    return true;
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
//| TRADE EXECUTION - SL ODMAH (RANDOM)                               |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(1);
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Random SL između 988-1054 pips
    int slPips = InitialSL_Min + MathRand() % (InitialSL_Max - InitialSL_Min + 1);
    double slDistance = slPips * pipValue;

    // Random BE offset za ovu poziciju (za kasnije)
    int beOffset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

    double sl, tp1, tp2, tp3;

    if(type == ORDER_TYPE_BUY)
    {
        sl = price - slDistance;
        tp1 = price + Target1_ATR * atr;
        tp2 = price + Target2_ATR * atr;
        tp3 = price + Target3_ATR * atr;
    }
    else
    {
        sl = price + slDistance;
        tp1 = price - Target1_ATR * atr;
        tp2 = price - Target2_ATR * atr;
        tp3 = price - Target3_ATR * atr;
    }

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp1 = NormalizeDouble(tp1, digits);
    tp2 = NormalizeDouble(tp2, digits);
    tp3 = NormalizeDouble(tp3, digits);

    bool ok;
    // SL ODMAH na ulasku, TP=0 (stealth)
    if(type == ORDER_TYPE_BUY)
        ok = trade.Buy(lots, _Symbol, price, sl, 0, "MIX1 BUY");
    else
        ok = trade.Sell(lots, _Symbol, price, sl, 0, "MIX1 SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();

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
        g_positions[g_posCount].beActivated = false;
        g_positions[g_posCount].beOffset = beOffset;
        g_positions[g_posCount].maxProfitPips = 0;
        g_positions[g_posCount].barsInTrade = 0;
        g_posCount++;

        if(type == ORDER_TYPE_BUY) totalBuys++;
        else totalSells++;

        Print("╔════════════════════════════════════════════════╗");
        Print("║ MIX1_ADX ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " - SL ODMAH #", ticket);
        Print("╠════════════════════════════════════════════════╣");
        Print("║ Entry: ", DoubleToString(price, digits), " | Lots: ", DoubleToString(lots, 2));
        Print("║ SL: ", DoubleToString(sl, digits), " (", slPips, " pips RANDOM)");
        Print("║ T1: ", DoubleToString(tp1, digits));
        Print("║ T2: ", DoubleToString(tp2, digits));
        Print("║ T3: ", DoubleToString(tp3, digits));
        Print("║ BE+: @", TrailingStartBE, " pips -> +", beOffset, " | Trail: ", TrailingDistance);
        Print("╚════════════════════════════════════════════════╝");
    }
    else
    {
        Print("Mix1_ADX ERROR: Trade failed - ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| STEALTH POSITION MANAGEMENT - BE+ i TRAILING STANDARD             |
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
        double profitPips = 0;
        if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - g_positions[i].entryPrice) / pipValue;
        else
            profitPips = (g_positions[i].entryPrice - currentPrice) / pipValue;

        // Update MFE
        if(profitPips > g_positions[i].maxProfitPips)
            g_positions[i].maxProfitPips = profitPips;

        //=== 1. EARLY FAILURE EXIT ===
        if(profitPips <= -EarlyFailurePips)
        {
            trade.PositionClose(ticket);
            g_positions[i].active = false;
            Print("Mix1_ADX: EARLY FAILURE @ ", DoubleToString(-profitPips, 0), " pips loss");
            continue;
        }

        //=== 2. Target 1 ===
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

        //=== 3. Target 2 ===
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

        //=== 4. Target 3 ===
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

        //=== 5. BE+ AKTIVACIJA (na 1000 pips profita) ===
        if(!g_positions[i].beActivated && profitPips >= TrailingStartBE)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
                newSL = g_positions[i].entryPrice + g_positions[i].beOffset * pipValue;
            else
                newSL = g_positions[i].entryPrice - g_positions[i].beOffset * pipValue;

            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && newSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_positions[i].beActivated = true;
                Print("Mix1_ADX: BE+ ACTIVATED @ ", TrailingStartBE, " pips -> entry+", g_positions[i].beOffset, " (SL=", newSL, ")");
            }
        }

        //=== 6. TRAILING (nakon BE+, prati na 1000 pips udaljenosti) ===
        if(g_positions[i].beActivated)
        {
            double trailSL;
            if(posType == POSITION_TYPE_BUY)
                trailSL = currentPrice - TrailingDistance * pipValue;
            else
                trailSL = currentPrice + TrailingDistance * pipValue;

            trailSL = NormalizeDouble(trailSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && trailSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && trailSL < currentSL);

            if(shouldModify && trade.PositionModify(ticket, trailSL, 0))
            {
                Print("Mix1_ADX: TRAILING @ ", TrailingDistance, " pips (SL=", trailSL, ")");
            }
        }
    }

    // Cleanup
    CleanupPositions();
}

//+------------------------------------------------------------------+
//| Check Time Exits                                                  |
//+------------------------------------------------------------------+
void CheckTimeExits()
{
    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;

        g_positions[i].barsInTrade++;

        // Time failure exit (3+ bars with < 20 pips profit)
        if(g_positions[i].barsInTrade >= TimeFailureBars)
        {
            ulong ticket = g_positions[i].ticket;
            if(!PositionSelectByTicket(ticket)) continue;

            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double currentPrice = (posType == POSITION_TYPE_BUY) ?
                                 SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                                 SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            double profitPips = 0;
            if(posType == POSITION_TYPE_BUY)
                profitPips = (currentPrice - g_positions[i].entryPrice) / pipValue;
            else
                profitPips = (g_positions[i].entryPrice - currentPrice) / pipValue;

            if(profitPips < TimeFailurePips && profitPips > -TimeFailurePips)
            {
                trade.PositionClose(ticket);
                g_positions[i].active = false;
                Print("Mix1_ADX: TIME FAILURE - ", g_positions[i].barsInTrade, " bars, ", DoubleToString(profitPips, 0), " pips");
            }
        }
    }
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

    // Time exit check
    CheckTimeExits();

    // Check filters
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;

    // Get signal
    int signal = GetTradeSignal();

    if(signal == 1)
    {
        Print("=== MIX1_ADX BUY SIGNAL ===");
        OpenTrade(ORDER_TYPE_BUY);
    }
    else if(signal == -1)
    {
        Print("=== MIX1_ADX SELL SIGNAL ===");
        OpenTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
