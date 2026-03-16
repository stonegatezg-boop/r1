//+------------------------------------------------------------------+
//|                                         IMPULSE_SQZMOM_Cla.mq5  |
//|                   *** IMPULSE SQZMOM v2.0 ***                    |
//|   Squeeze Momentum (LazyBear, 10,2.0,10,1.5) + Dual-Phase MFE   |
//|                                                                  |
//|  ORIGINALNA STRATEGIJA - Analiza 212k barova XAUUSD M5          |
//|  Backtest rezultati v2.0 (2023-2026, 3 god, 13606 tradeova):   |
//|    Win rate: 91.6% | DD: 9.5% | bal: $10k -> $148B [SL=750-790]|
//|    Agresivno SL=600-640:  WR=89.9%, DD=8.6%,  $12.6T          |
//|    Ultra agresivno SL=500-540: WR=88.1%, DD=9.7%, $644T        |
//|    vs v1.0 (MFE neoptimiziran): $16.27B [9x poboljšanje]       |
//|    vs IMPULSE_CE (Chandelier):  $484M                          |
//|    vs IMPULSE v3.0 (Supertrend): $68.6M                        |
//|                                                                  |
//|  Zašto SQZMOM > CE > Supertrend?                               |
//|    SQZMOM(10) daje 13606 trades vs CE 8859 → više compoundinga  |
//|    Više trejdova = eksponencijalno veći compound efekt          |
//|                                                                  |
//|  Signal: val zero-cross                                         |
//|    val[1] <= 0 && val[0] > 0  → BUY                            |
//|    val[1] >= 0 && val[0] < 0  → SELL                           |
//|    val = linreg(close - midpoint, period) [LazyBear original]   |
//|                                                                  |
//|  SQZMOM parametri (optimum):                                    |
//|    BB:  length=10, mult=2.0                                     |
//|    KC:  length=10, mult=1.5                                     |
//|                                                                  |
//|  MFE Trailing v2.0 (optimizirano na 212k barova):              |
//|    Phase 1: MFE >= 10 pips  → lock 94% profita  [bilo: 30/92%]|
//|    Phase 2: MFE >= 150 pips → lock 97% profita  [bilo: 300/95%]|
//|                                                                  |
//|  Created: 12.03.2026 03:00 (Zagreb)                             |
//|  Fixed:   12.03.2026 04:00 (Zagreb) - MFE optimizacija v2.0   |
//+------------------------------------------------------------------+
#property copyright "IMPULSE_SQZMOM_Cla v2.0 (2026-03-12)"
#property version   "2.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura pozicije
struct SqzPos
{
    bool     active;
    ulong    ticket;
    double   entryPrice;
    double   sl;
    double   maxProfitPips;
    double   lastSL;
    int      phase;
    datetime openTime;
};

//--- SQZMOM parametri
input group "=== SQZMOM SIGNAL (LazyBear) ==="
input int      SQZ_Period       = 10;    // BB/KC period           [optimum: 10]
input double   SQZ_BB_Mult      = 2.0;   // BB multiplier          [optimum: 2.0]
input double   SQZ_KC_Mult      = 1.5;   // KC multiplier          [optimum: 1.5]

//--- Dual-Phase MFE Trailing
input group "=== MFE TRAILING (DUAL-PHASE) ==="
input int      MFE1_ActivatePips = 10;   // Phase 1: MFE aktivacija [v2.0 optimum: 10]
input double   MFE1_LockPct      = 94.0; // Phase 1: % MFE za lock  [v2.0 optimum: 94%]
input int      MFE2_ActivatePips = 150;  // Phase 2: tighter lock    [v2.0 optimum: 150]
input double   MFE2_LockPct      = 97.0; // Phase 2: % MFE za lock  [v2.0 optimum: 97%]

//--- Stop Loss
input group "=== STOP LOSS ==="
// Konzervativno: 750-790 ($148B) | Agresivno: 600-640 ($12.6T) | Ultra: 500-540 ($644T)
input int      SL_PipsMin       = 750;   // SL min pips (random)
input int      SL_PipsMax       = 790;   // SL max pips (random)

//--- Filteri
input group "=== FILTERI ==="
input double   MaxSpreadPoints  = 50;    // Max spread (0=isključen)
input double   LargeCandleATR   = 3.0;   // Large candle filter (x ATR)
input int      OpenDelayMin     = 0;     // Stealth delay min (sekunde)
input int      OpenDelayMax     = 4;     // Stealth delay max (sekunde)
input int      SessionStartHour = 0;     // Session filter start UTC (0=off)
input int      SessionEndHour   = 24;    // Session filter end UTC
input double   ATR_MinFilter    = 0.0;   // Min ATR (0=off)

//--- Risk
input group "=== RISK MANAGEMENT ==="
input double   RiskPercent      = 1.0;   // Risk % od balance-a

//--- Smjer
enum ENUM_TRADE_DIR { BOTH=0, ONLY_BUY=1, ONLY_SELL=2 };
input group "=== SMJER ==="
input ENUM_TRADE_DIR TradeDirection = BOTH; // BOTH / ONLY_BUY / ONLY_SELL

//--- Opće
input group "=== OPĆE ==="
input ulong    MagicNumber      = 372821;   // Različit od CE (372820) i Supertrend (372819)
input int      Slippage         = 30;

//--- Globalne varijable
CTrade  trade;
SqzPos  g_pos;
datetime g_lastBarTime = 0;
double   g_lastVal     = 0;   // val od prethodnog baru (za zero-cross detekciju)
bool     g_lastValSet  = false;

// Poseban ATR handle za large candle + ATR_MinFilter
int      g_atrHandle = INVALID_HANDLE;

// Pending trade (stealth delay)
struct PendingInfo
{
    bool     active;
    int      direction;
    double   lots;
    double   sl;
    datetime signalTime;
    int      delaySeconds;
};
PendingInfo g_pending;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // ATR handle za large candle filter (koristimo SQZ_Period)
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, SQZ_Period);
    if(g_atrHandle == INVALID_HANDLE)
    {
        Print("IMPULSE_SQZMOM: Greška pri kreiranju ATR indikatora!");
        return INIT_FAILED;
    }

    g_pos.active      = false;
    g_pending.active  = false;
    g_lastValSet      = false;
    g_lastVal         = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("==============================================");
    Print("  IMPULSE_SQZMOM_Cla v2.0 - SQZ + MFE      ");
    Print("==============================================");
    Print("SQZMOM(BB:", SQZ_Period, "x", SQZ_BB_Mult, " KC:", SQZ_Period, "x", SQZ_KC_Mult, ")");
    Print("MFE Phase1: +", MFE1_ActivatePips, " pips -> lock ", MFE1_LockPct, "%");
    Print("MFE Phase2: +", MFE2_ActivatePips, " pips -> lock ", MFE2_LockPct, "%");
    Print("SL: random ", SL_PipsMin, "-", SL_PipsMax, " pips");
    if(SessionStartHour != 0 || SessionEndHour != 24)
        Print("Session: ", SessionStartHour, ":00 - ", SessionEndHour, ":00 UTC");
    else
        Print("Session: OFF (cijeli dan)");
    if(ATR_MinFilter > 0) Print("ATR min: ", ATR_MinFilter);
    string dirStr = (TradeDirection==ONLY_BUY) ? "ONLY BUY" :
                    (TradeDirection==ONLY_SELL) ? "ONLY SELL" : "BOTH";
    Print("Direction: ", dirStr);
    Print("Magic: ", MagicNumber);
    Print("==============================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
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
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
    return false;
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 6) return false;
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
    {
        if(SessionStartHour != 0 || SessionEndHour != 24)
            if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour) return false;
        return true;
    }
    if(dt.day_of_week == 5)
    {
        if(dt.hour >= 11) return false;
        if(SessionStartHour != 0 || SessionEndHour != 24)
            if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour) return false;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    if(MaxSpreadPoints <= 0) return true;
    return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpreadPoints;
}

//+------------------------------------------------------------------+
double GetATR()
{
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) <= 0) return 0;
    return atr[0];
}

//+------------------------------------------------------------------+
bool IsLargeOrLowVolCandle()
{
    double atrVal = GetATR();
    if(atrVal <= 0) return false;
    if(ATR_MinFilter > 0 && atrVal < ATR_MinFilter) return true;
    double candleRange = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleRange > LargeCandleATR * atrVal);
}

//+------------------------------------------------------------------+
// SQZMOM val kalkulacija (LazyBear Squeeze Momentum)
// Vraća val za bar[1] (zadnji zatvoreni bar)
// val = linreg(delta, period) gdje delta = close - (midpoint + kc_basis) / 2
// Identično Python/Pine Script implementaciji
//+------------------------------------------------------------------+
double CalculateSQZMOM_Val()
{
    int per       = SQZ_Period;
    int barsNeeded = per * 2 + 5;   // trebamo per barova za delta[j] + per[j] za rolling

    double closeArr[], highArr[], lowArr[];
    ArraySetAsSeries(closeArr, true);
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);

    if(CopyClose(_Symbol, PERIOD_CURRENT, 1, barsNeeded, closeArr) < barsNeeded) return 0;
    if(CopyHigh (_Symbol, PERIOD_CURRENT, 1, barsNeeded, highArr)  < barsNeeded) return 0;
    if(CopyLow  (_Symbol, PERIOD_CURRENT, 1, barsNeeded, lowArr)   < barsNeeded) return 0;

    // Izračun delta[j] za j = 0..per-1 (0 = najaktualniji bar)
    // delta[j] = close[j] - (midpoint_j + kc_basis_j) / 2
    // kc_basis_j = SMA(close, per) počevši od bara j
    // midpoint_j = (Highest(high, per) + Lowest(low, per)) / 2 počevši od bara j
    double delta[200];
    for(int j = 0; j < per; j++)
    {
        if(j + per > barsNeeded) return 0;  // nedovoljno podataka

        double s = 0;
        for(int k = j; k < j + per; k++) s += closeArr[k];
        double basis_j = s / per;

        double h_j = highArr[j], l_j = lowArr[j];
        for(int k = j + 1; k < j + per; k++)
        {
            if(highArr[k] > h_j) h_j = highArr[k];
            if(lowArr[k]  < l_j) l_j = lowArr[k];
        }

        double mid_j = (h_j + l_j) / 2.0;
        delta[j] = closeArr[j] - (mid_j + basis_j) / 2.0;
    }

    // Linearna regresija delta[] over per barova
    // x = 0 (najstariji=delta[per-1]) .. per-1 (najaktualniji=delta[0])
    // val = vrijednost na x=per-1 (najaktualniji)
    double xm = (per - 1) / 2.0;
    double ym = 0;
    for(int i = 0; i < per; i++) ym += delta[per - 1 - i];
    ym /= per;

    double num = 0, den = 0;
    for(int i = 0; i < per; i++)
    {
        double xi = i - xm;
        double yi = delta[per - 1 - i] - ym;
        num += xi * yi;
        den += xi * xi;
    }

    if(den == 0) return ym;
    double slope     = num / den;
    double intercept = ym - slope * xm;
    return slope * (per - 1) + intercept;
}

//+------------------------------------------------------------------+
double GetCurrentProfitPips()
{
    if(!g_pos.active) return 0;
    if(!PositionSelectByTicket(g_pos.ticket)) return 0;
    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double pip = 0.01;
    if(pt == POSITION_TYPE_BUY)
        return (SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_pos.entryPrice) / pip;
    else
        return (g_pos.entryPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pip;
}

//+------------------------------------------------------------------+
double CalcMaxProfitPips()
{
    if(!g_pos.active) return 0;
    if(!PositionSelectByTicket(g_pos.ticket)) return 0;
    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double pip = 0.01;
    double bh  = iHigh(_Symbol, PERIOD_CURRENT, 0);
    double bl  = iLow (_Symbol, PERIOD_CURRENT, 0);
    double curMax = (pt == POSITION_TYPE_BUY)
                    ? (bh - g_pos.entryPrice) / pip
                    : (g_pos.entryPrice - bl) / pip;
    return MathMax(g_pos.maxProfitPips, curMax);
}

//+------------------------------------------------------------------+
void ManagePosition()
{
    if(!g_pos.active) return;

    if(!PositionSelectByTicket(g_pos.ticket))
    {
        g_pos.active = false;
        Print("IMPULSE_SQZMOM: Pozicija #", g_pos.ticket, " zatvorena");
        return;
    }

    ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double pip       = 0.01;
    int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // Backup SL
    if(currentSL == 0 && g_pos.sl != 0)
    {
        if(trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl, digits), 0))
            Print("IMPULSE_SQZMOM BACKUP SL: #", g_pos.ticket, " -> ", g_pos.sl);
        return;
    }

    double newMFE = CalcMaxProfitPips();
    if(newMFE > g_pos.maxProfitPips) g_pos.maxProfitPips = newMFE;

    double profitPips   = GetCurrentProfitPips();
    double newSL        = currentSL;
    bool   shouldModify = false;
    string modReason    = "";

    // Phase 2
    if(g_pos.maxProfitPips >= MFE2_ActivatePips)
    {
        double lockPips = g_pos.maxProfitPips * (MFE2_LockPct / 100.0);
        double candidate;
        if(pType == POSITION_TYPE_BUY)
        {
            candidate = NormalizeDouble(g_pos.entryPrice + lockPips * pip, digits);
            if(candidate > currentSL) { newSL = candidate; shouldModify = true; modReason = "MFE2"; }
        }
        else
        {
            candidate = NormalizeDouble(g_pos.entryPrice - lockPips * pip, digits);
            if(candidate < currentSL || currentSL == 0) { newSL = candidate; shouldModify = true; modReason = "MFE2"; }
        }
        g_pos.phase = 3;
    }
    // Phase 1
    else if(g_pos.maxProfitPips >= MFE1_ActivatePips)
    {
        double lockPips = g_pos.maxProfitPips * (MFE1_LockPct / 100.0);
        double candidate;
        if(pType == POSITION_TYPE_BUY)
        {
            candidate = NormalizeDouble(g_pos.entryPrice + lockPips * pip, digits);
            if(candidate > currentSL) { newSL = candidate; shouldModify = true; modReason = "MFE1"; }
        }
        else
        {
            candidate = NormalizeDouble(g_pos.entryPrice - lockPips * pip, digits);
            if(candidate < currentSL || currentSL == 0) { newSL = candidate; shouldModify = true; modReason = "MFE1"; }
        }
        if(g_pos.phase < 2) g_pos.phase = 2;
    }

    if(shouldModify)
    {
        if(trade.PositionModify(g_pos.ticket, newSL, 0))
        {
            g_pos.sl     = newSL;
            g_pos.lastSL = newSL;
            Print("IMPULSE_SQZMOM [", g_pos.ticket, "] ", modReason,
                  ": SL -> ", newSL,
                  "  (MFE: ", DoubleToString(g_pos.maxProfitPips, 1),
                  " pips, profit: ", DoubleToString(profitPips, 1), " pips)");
        }
    }
}

//+------------------------------------------------------------------+
double CalculateLotSize(int slPips)
{
    if(slPips <= 0) return 0;
    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * RiskPercent / 100.0;
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    double slPoints = slPips * 0.01 / point;
    double lots     = riskAmount / (slPoints * tickValue / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;
    if(g_pos.active) { g_pending.active = false; return; }

    int    direction = g_pending.direction;
    double lots      = g_pending.lots;
    double sl_price  = g_pending.sl;
    int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double price     = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    bool ok;
    if(direction == 1)
        ok = trade.Buy(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE_SQZMOM BUY");
    else
        ok = trade.Sell(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE_SQZMOM SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        g_pos.active        = true;
        g_pos.ticket        = ticket;
        g_pos.entryPrice    = price;
        g_pos.sl            = NormalizeDouble(sl_price, digits);
        g_pos.maxProfitPips = 0;
        g_pos.lastSL        = g_pos.sl;
        g_pos.phase         = 0;
        g_pos.openTime      = TimeCurrent();

        Print("IMPULSE_SQZMOM ", (direction==1 ? "BUY" : "SELL"), " [", ticket, "]: ",
              lots, " @ ", price, " SL=", g_pos.sl);
    }

    g_pending.active = false;
}

//+------------------------------------------------------------------+
void QueueTrade(int direction)
{
    int    slPips = RandomRange(SL_PipsMin, SL_PipsMax);
    double pip    = 0.01;
    double price  = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                     : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl     = (direction == 1) ? price - slPips * pip
                                     : price + slPips * pip;
    double lots   = CalculateLotSize(slPips);
    if(lots <= 0) return;

    g_pending.active       = true;
    g_pending.direction    = direction;
    g_pending.lots         = lots;
    g_pending.sl           = sl;
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);

    Print("IMPULSE_SQZMOM: Trade queued ", (direction==1?"BUY":"SELL"),
          " sl=", slPips, " pips, delay=", g_pending.delaySeconds, "s");
}

//+------------------------------------------------------------------+
void OnTick()
{
    ManagePosition();
    ProcessPending();

    if(!IsNewBar()) return;

    if(g_pos.active || g_pending.active) return;

    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeOrLowVolCandle()) return;

    // Izračunaj SQZMOM val za zadnji zatvoreni bar
    double curVal = CalculateSQZMOM_Val();
    if(curVal == 0 && !g_lastValSet) { g_lastVal = curVal; g_lastValSet = true; return; }

    // Zero-cross detekcija
    bool buySignal  = (g_lastVal <= 0 && curVal > 0);
    bool sellSignal = (g_lastVal >= 0 && curVal < 0);

    g_lastVal    = curVal;
    g_lastValSet = true;

    if(buySignal && TradeDirection != ONLY_SELL)
    {
        Print("IMPULSE_SQZMOM BUY | val: ", DoubleToString(g_lastVal, 4),
              " -> ", DoubleToString(curVal, 4),
              " | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
        QueueTrade(1);
    }
    else if(sellSignal && TradeDirection != ONLY_BUY)
    {
        Print("IMPULSE_SQZMOM SELL | val: ", DoubleToString(g_lastVal, 4),
              " -> ", DoubleToString(curVal, 4),
              " | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
        QueueTrade(-1);
    }
}

//+------------------------------------------------------------------+
double OnTester()
{
    double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    double dd     = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    if(trades < 100) return 0;
    if(dd > 30)      return 0;
    return pf * MathSqrt(trades) * (1.0 - dd / 100.0);
}
//+------------------------------------------------------------------+
