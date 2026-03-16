//+------------------------------------------------------------------+
//|                                           CALF_F_WilliamsCMF.mq5 |
//|                   *** CALF F - Williams %R + CMF ***             |
//|                   Created: 05.03.2026 (Zagreb)                   |
//|                   Williams %R Momentum + CMF Volume Confirm      |
//|                   + H1 EMA Trend + ADX Filter                    |
//|                   + Stealth TP + 3-Level Trailing                |
//|                   + Session Filter + Max SL 800 pips             |
//+------------------------------------------------------------------+
#property copyright "CALF F - Williams CMF v1.0 (2026-03-05)"
#property version   "1.00"
#property strict
#include <Trade/Trade.mqh>

//--- Position tracking
struct StealthPos
{
    bool     active;
    ulong    ticket;
    double   entry;
    double   stealthTP;
    double   maxProfit;
    int      trailLevel;
    int      bars;
    int      dir;
    int      randomBE;
    int      randomL2;
    int      randomL3;
};

//=== INPUT PARAMETERS ===
input group "=== WILLIAMS %R SETTINGS ==="
input int      WilliamsRPeriod  = 21;       // Williams %R Period
input int      WR_Oversold     = -80;       // Oversold Level (default -80)
input int      WR_Overbought   = -20;       // Overbought Level (default -20)

input group "=== CMF SETTINGS ==="
input int      CMF_Period       = 20;       // Chaikin Money Flow Period
input double   CMF_BuyLevel     = 0.05;     // CMF > X for buy (money inflow)
input double   CMF_SellLevel    = -0.05;    // CMF < X for sell (money outflow)

input group "=== H1 EMA TREND FILTER ==="
input bool     UseH1Filter      = true;     // Use H1 EMA Trend Filter
input int      H1_EMA_Period    = 50;       // H1 EMA Period

input group "=== ADX FILTER ==="
input bool     UseADXFilter     = true;     // Use ADX Filter
input int      ADX_Period       = 14;       // ADX Period
input int      ADX_Threshold    = 20;       // Min ADX (trending market)

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;     // Use Session Filter
input int      LondonStart      = 8;        // London Start Hour
input int      LondonEnd        = 12;       // London End Hour
input int      NYStart          = 13;       // NY Start Hour
input int      NYEnd            = 17;       // NY End Hour

input group "=== SPREAD FILTER ==="
input bool     UseSpreadFilter  = true;     // Use Spread Filter
input int      MaxSpread        = 50;       // Max Spread (points)

input group "=== RISK MANAGEMENT ==="
input double   RiskPercent      = 1.0;      // Risk % of Balance
input double   SLMultiplier     = 2.0;      // SL = ATR * X
input double   TPMultiplier     = 3.0;      // TP = ATR * X (stealth)
input int      MaxSL_Pips       = 800;      // Max SL in pips
input int      ATRPeriod        = 14;       // ATR Period

input group "=== TRAILING STOP (3-LEVEL) ==="
input int      TrailL1_Pips     = 500;      // L1: Activate at X pips
input int      TrailL1_BEMin    = 38;       // L1: BE + min pips
input int      TrailL1_BEMax    = 43;       // L1: BE + max pips
input int      TrailL2_Pips     = 800;      // L2: Activate at X pips
input int      TrailL2_LockMin  = 150;      // L2: Lock min pips
input int      TrailL2_LockMax  = 200;      // L2: Lock max pips
input int      TrailL3_Pips     = 1200;     // L3: Activate at X pips
input int      TrailL3_LockMin  = 180;      // L3: Lock min pips
input int      TrailL3_LockMax  = 220;      // L3: Lock max pips

input group "=== MFE TRAILING ==="
input int      MFE_Pips         = 1500;     // MFE: Activate at X pips
input int      MFE_TrailDist    = 500;      // MFE: Trail distance

input group "=== LARGE CANDLE FILTER ==="
input double   LargeCandleATR   = 3.0;      // Skip if candle > X * ATR

input group "=== GENERAL ==="
input ulong    MagicNumber      = 100006;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)

//=== GLOBAL VARIABLES ===
CTrade       trade;
int          wrHandle;
int          atrHandle;
int          emaHandle;
int          adxHandle;
double       point;
datetime     lastBarTime = 0;
StealthPos   posArray[];
int          posCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    wrHandle = iWPR(_Symbol, PERIOD_M5, WilliamsRPeriod);
    atrHandle = iATR(_Symbol, PERIOD_M5, ATRPeriod);
    emaHandle = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    adxHandle = iADX(_Symbol, PERIOD_M5, ADX_Period);

    if(wrHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE ||
       emaHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicators!");
        return INIT_FAILED;
    }

    ArrayResize(posArray, 0);
    posCount = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("=====================================================");
    Print("    CALF F - WILLIAMS %R + CMF v1.0");
    Print("=====================================================");
    Print("Williams %R: Period=", WilliamsRPeriod, " OB=", WR_Overbought, " OS=", WR_Oversold);
    Print("CMF: Period=", CMF_Period, " Buy>", CMF_BuyLevel, " Sell<", CMF_SellLevel);
    Print("H1 Filter: ", UseH1Filter ? "ON" : "OFF");
    Print("ADX Filter: ", UseADXFilter ? "ON" : "OFF", " Threshold=", ADX_Threshold);
    Print("Session Filter: ", UseSessionFilter ? "ON" : "OFF");
    Print("Max SL: ", MaxSL_Pips, " pips");
    Print("=====================================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(wrHandle != INVALID_HANDLE) IndicatorRelease(wrHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
    if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

//+------------------------------------------------------------------+
double GetATR()
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
double GetADX()
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(adxHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
// Williams %R: Returns values from -100 to 0
// -100 to -80 = Oversold (potential BUY)
// -20 to 0 = Overbought (potential SELL)
//+------------------------------------------------------------------+
void GetWilliamsR(double &wr0, double &wr1, double &wr2)
{
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(wrHandle, 0, 0, 4, buf) < 4)
    {
        wr0 = wr1 = wr2 = -50;  // Neutral
        return;
    }
    wr0 = buf[0];  // Current (forming)
    wr1 = buf[1];  // Last closed bar
    wr2 = buf[2];  // 2 bars ago
}

//+------------------------------------------------------------------+
// Calculate Chaikin Money Flow manually
// CMF = Sum(MFV * Volume) / Sum(Volume) over period
// MFV = ((Close - Low) - (High - Close)) / (High - Low)
//+------------------------------------------------------------------+
double GetCMF()
{
    double close[], high[], low[];
    long volume[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(volume, true);

    if(CopyClose(_Symbol, PERIOD_M5, 1, CMF_Period, close) < CMF_Period) return 0;
    CopyHigh(_Symbol, PERIOD_M5, 1, CMF_Period, high);
    CopyLow(_Symbol, PERIOD_M5, 1, CMF_Period, low);
    CopyTickVolume(_Symbol, PERIOD_M5, 1, CMF_Period, volume);

    double sumMFV = 0;
    double sumVol = 0;

    for(int i = 0; i < CMF_Period; i++)
    {
        double hl = high[i] - low[i];
        if(hl <= 0) continue;

        // Money Flow Multiplier: ((Close - Low) - (High - Close)) / (High - Low)
        double mfm = ((close[i] - low[i]) - (high[i] - close[i])) / hl;

        // Money Flow Volume = MFM * Volume
        double mfv = mfm * (double)volume[i];

        sumMFV += mfv;
        sumVol += (double)volume[i];
    }

    if(sumVol <= 0) return 0;

    return sumMFV / sumVol;  // CMF oscillates between -1 and +1
}

//+------------------------------------------------------------------+
int GetH1Trend()
{
    if(!UseH1Filter) return 0;

    double ema[];
    ArraySetAsSeries(ema, true);
    if(CopyBuffer(emaHandle, 0, 0, 3, ema) < 3) return 0;

    double price = iClose(_Symbol, PERIOD_H1, 1);

    if(price > ema[0] && ema[0] > ema[1]) return 1;   // Bullish
    if(price < ema[0] && ema[0] < ema[1]) return -1;  // Bearish

    return 0;
}

//+------------------------------------------------------------------+
bool IsMarketTrending()
{
    if(!UseADXFilter) return true;
    return (GetADX() >= ADX_Threshold);
}

//+------------------------------------------------------------------+
bool IsValidSession()
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

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    if(!UseSpreadFilter) return true;
    int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
bool IsLargeCandle()
{
    double atr = GetATR();
    if(atr <= 0) return false;

    double high = iHigh(_Symbol, PERIOD_M5, 1);
    double low = iLow(_Symbol, PERIOD_M5, 1);
    double range = high - low;

    return (range > LargeCandleATR * atr);
}

//+------------------------------------------------------------------+
double CalcLot(double slDist)
{
    if(slDist <= 0) return 0;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk = balance * RiskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double lot = risk / ((slDist / tickSize) * tickVal);
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));

    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
void SyncPositions()
{
    for(int i = posCount - 1; i >= 0; i--)
    {
        if(!posArray[i].active) continue;
        if(!PositionSelectByTicket(posArray[i].ticket))
        {
            posArray[i].active = false;
            for(int j = i; j < posCount - 1; j++)
                posArray[j] = posArray[j + 1];
            posCount--;
            ArrayResize(posArray, posCount);
        }
    }
}

//+------------------------------------------------------------------+
void AddPosition(ulong ticket, double entry, double tp, int dir)
{
    ArrayResize(posArray, posCount + 1);
    posArray[posCount].active = true;
    posArray[posCount].ticket = ticket;
    posArray[posCount].entry = entry;
    posArray[posCount].stealthTP = tp;
    posArray[posCount].maxProfit = 0;
    posArray[posCount].trailLevel = 0;
    posArray[posCount].bars = 0;
    posArray[posCount].dir = dir;
    posArray[posCount].randomBE = RandomRange(TrailL1_BEMin, TrailL1_BEMax);
    posArray[posCount].randomL2 = RandomRange(TrailL2_LockMin, TrailL2_LockMax);
    posArray[posCount].randomL3 = RandomRange(TrailL3_LockMin, TrailL3_LockMax);
    posCount++;
}

//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(trade.PositionClose(ticket))
        Print("CALF_F CLOSE [", ticket, "]: ", reason);
}

//+------------------------------------------------------------------+
double GetProfitPips(int idx)
{
    if(!posArray[idx].active) return 0;
    if(!PositionSelectByTicket(posArray[idx].ticket)) return 0;

    double currentPrice;
    if(posArray[idx].dir == 1)
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    else
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double diff;
    if(posArray[idx].dir == 1)
        diff = currentPrice - posArray[idx].entry;
    else
        diff = posArray[idx].entry - currentPrice;

    return diff / point;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
    SyncPositions();
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = posCount - 1; i >= 0; i--)
    {
        if(!posArray[i].active) continue;
        if(!PositionSelectByTicket(posArray[i].ticket)) continue;

        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice;
        if(posArray[i].dir == 1)
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        else
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double profitPips = GetProfitPips(i);

        // Update MFE
        if(profitPips > posArray[i].maxProfit)
            posArray[i].maxProfit = profitPips;

        // 1. STEALTH TP
        bool tpHit = false;
        if(posArray[i].dir == 1 && currentPrice >= posArray[i].stealthTP) tpHit = true;
        else if(posArray[i].dir == -1 && currentPrice <= posArray[i].stealthTP) tpHit = true;

        if(tpHit)
        {
            ClosePosition(posArray[i].ticket, "STEALTH TP @ " + DoubleToString(currentPrice, digits));
            continue;
        }

        // 2. MFE TRAILING
        if(posArray[i].trailLevel >= 3 && profitPips >= MFE_Pips)
        {
            double mfeSL;
            double trailDist = MFE_TrailDist * point;
            if(posArray[i].dir == 1)
            {
                mfeSL = posArray[i].entry + (posArray[i].maxProfit * point) - trailDist;
                mfeSL = NormalizeDouble(mfeSL, digits);
                if(mfeSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, mfeSL, 0))
                        Print("CALF_F MFE [", posArray[i].ticket, "]: Trail @ ", mfeSL);
            }
            else
            {
                mfeSL = posArray[i].entry - (posArray[i].maxProfit * point) + trailDist;
                mfeSL = NormalizeDouble(mfeSL, digits);
                if(mfeSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, mfeSL, 0))
                        Print("CALF_F MFE [", posArray[i].ticket, "]: Trail @ ", mfeSL);
            }
        }
        // 3. L3 TRAILING
        else if(posArray[i].trailLevel == 2 && profitPips >= TrailL3_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + posArray[i].randomL3 * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 3; Print("CALF_F L3 [", posArray[i].ticket, "]: Lock +", posArray[i].randomL3); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - posArray[i].randomL3 * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 3; Print("CALF_F L3 [", posArray[i].ticket, "]: Lock +", posArray[i].randomL3); }
            }
        }
        // 4. L2 TRAILING
        else if(posArray[i].trailLevel == 1 && profitPips >= TrailL2_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + posArray[i].randomL2 * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 2; Print("CALF_F L2 [", posArray[i].ticket, "]: Lock +", posArray[i].randomL2); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - posArray[i].randomL2 * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 2; Print("CALF_F L2 [", posArray[i].ticket, "]: Lock +", posArray[i].randomL2); }
            }
        }
        // 5. L1 TRAILING (BE)
        else if(posArray[i].trailLevel == 0 && profitPips >= TrailL1_Pips)
        {
            double newSL;
            if(posArray[i].dir == 1)
            {
                newSL = NormalizeDouble(posArray[i].entry + posArray[i].randomBE * point, digits);
                if(newSL > currentSL)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 1; Print("CALF_F L1 [", posArray[i].ticket, "]: BE+", posArray[i].randomBE); }
            }
            else
            {
                newSL = NormalizeDouble(posArray[i].entry - posArray[i].randomBE * point, digits);
                if(newSL < currentSL || currentSL == 0)
                    if(trade.PositionModify(posArray[i].ticket, newSL, 0))
                    { posArray[i].trailLevel = 1; Print("CALF_F L1 [", posArray[i].ticket, "]: BE+", posArray[i].randomBE); }
            }
        }
    }
}

//+------------------------------------------------------------------+
void UpdateBarCount()
{
    for(int i = 0; i < posCount; i++)
        if(posArray[i].active) posArray[i].bars++;
}

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDist = SLMultiplier * atr;

    // MAX SL LIMIT
    if(MaxSL_Pips > 0)
    {
        double maxSlDist = MaxSL_Pips * point;
        if(slDist > maxSlDist)
        {
            slDist = maxSlDist;
            Print("SL capped to ", MaxSL_Pips, " pips");
        }
    }

    double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    double lot = CalcLot(slDist);
    if(lot <= 0) return;

    bool ok = false;
    string comment = (type == ORDER_TYPE_BUY) ? "CALF_F BUY" : "CALF_F SELL";

    // SL ODMAH, TP=0 (stealth)
    if(type == ORDER_TYPE_BUY)
        ok = trade.Buy(lot, _Symbol, price, sl, 0, comment);
    else
        ok = trade.Sell(lot, _Symbol, price, sl, 0, comment);

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        int dir = (type == ORDER_TYPE_BUY) ? 1 : -1;
        AddPosition(ticket, price, tp, dir);

        Print("================================================");
        Print("CALF_F ", (type == ORDER_TYPE_BUY) ? "BUY" : "SELL");
        Print("Entry: ", price, " | Lots: ", lot);
        Print("SL: ", sl, " (REAL) | TP: ", tp, " (stealth)");
        Print("================================================");
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    // ALWAYS manage positions
    ManagePositions();

    // New bar check
    datetime t = iTime(_Symbol, PERIOD_M5, 0);
    if(t == lastBarTime) return;
    lastBarTime = t;

    UpdateBarCount();

    // Skip if position open
    if(CountPositions() > 0) return;

    // Filters
    if(!IsTradingWindow()) return;
    if(!IsValidSession()) return;
    if(!IsMarketTrending()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;

    // Get indicators
    double wr0, wr1, wr2;
    GetWilliamsR(wr0, wr1, wr2);

    double cmf = GetCMF();
    int h1Trend = GetH1Trend();

    // Candle confirmation
    double close = iClose(_Symbol, PERIOD_M5, 1);
    double open = iOpen(_Symbol, PERIOD_M5, 1);
    bool bullCandle = close > open;
    bool bearCandle = close < open;

    //=== BUY SIGNAL ===
    // Williams %R crosses above oversold (-80) + CMF positive + H1 bullish
    bool wrBuySignal = (wr2 < WR_Oversold && wr1 >= WR_Oversold);  // Cross above -80
    bool cmfBuy = (cmf > CMF_BuyLevel);
    bool h1Buy = (!UseH1Filter || h1Trend >= 0);

    if(wrBuySignal && cmfBuy && h1Buy && bullCandle)
    {
        Print("=== CALF_F BUY SIGNAL ===");
        Print("Williams %R: ", DoubleToString(wr1, 2), " (crossed above ", WR_Oversold, ")");
        Print("CMF: ", DoubleToString(cmf, 4), " (> ", CMF_BuyLevel, ")");
        Print("H1 Trend: ", h1Trend);
        ExecuteTrade(ORDER_TYPE_BUY);
    }

    //=== SELL SIGNAL ===
    // Williams %R crosses below overbought (-20) + CMF negative + H1 bearish
    bool wrSellSignal = (wr2 > WR_Overbought && wr1 <= WR_Overbought);  // Cross below -20
    bool cmfSell = (cmf < CMF_SellLevel);
    bool h1Sell = (!UseH1Filter || h1Trend <= 0);

    if(wrSellSignal && cmfSell && h1Sell && bearCandle)
    {
        Print("=== CALF_F SELL SIGNAL ===");
        Print("Williams %R: ", DoubleToString(wr1, 2), " (crossed below ", WR_Overbought, ")");
        Print("CMF: ", DoubleToString(cmf, 4), " (< ", CMF_SellLevel, ")");
        Print("H1 Trend: ", h1Trend);
        ExecuteTrade(ORDER_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double pf = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    if(trades < 30) return 0;
    return pf * MathSqrt(trades);
}
//+------------------------------------------------------------------+
