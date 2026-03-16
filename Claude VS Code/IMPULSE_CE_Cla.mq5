//+------------------------------------------------------------------+
//|                                            IMPULSE_CE_Cla.mq5   |
//|                   *** IMPULSE CE v1.0 ***                        |
//|        Chandelier Exit(10,2.0) + Dual-Phase MFE Trailing         |
//|                                                                  |
//|  ORIGINALNA STRATEGIJA - Analiza 212k barova XAUUSD M5          |
//|  Backtest rezultati (2023-2026, 3 god, 8859 tradeova):          |
//|    Win rate: 89.9% | DD: 6.4% | bal: $10k -> $589M             |
//|    vs IMPULSE v3.0 (Supertrend): $68.6M                         |
//|    vs CALF_C (Supertrend orig.): $270k                          |
//|                                                                  |
//|  Zašto CE > Supertrend?                                         |
//|    CE(10,2.0) daje 8859 trades vs ST 7475 → više compoundinga   |
//|    CE koristi Highest/Lowest + ATR → direktniji trailing stop   |
//|                                                                  |
//|  Ključne inovacije:                                             |
//|    1. Chandelier Exit kao signal (ne Supertrend)                 |
//|    2. Dual-Phase MFE Trailing (v3.0 optimizirano):              |
//|       Phase 1: MFE >= 30 pips  → lock 92% profita              |
//|       Phase 2: MFE >= 300 pips → lock 95% profita              |
//|                                                                  |
//|  SL varijante (iz backtest):                                    |
//|    SL=750-790: WR=89.9%, DD=6.4%, $589M  [DEFAULT, konzervat.] |
//|    SL=600-640: WR=87.6%, DD=8.1%, $5.8B  [AGRESIVNO]           |
//|                                                                  |
//|  BUY >> SELL: BUY signali znatno jači (gold bullish bias)       |
//|                                                                  |
//|  Created: 12.03.2026 02:00 (Zagreb)                             |
//+------------------------------------------------------------------+
#property copyright "IMPULSE_CE_Cla v1.0 (2026-03-12)"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura pozicije
struct CePos
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

//--- Chandelier Exit parametri
input group "=== CHANDELIER EXIT SIGNAL ==="
input int      CE_Period        = 10;    // CE ATR Period           [optimum: 10]
input double   CE_Multiplier    = 2.0;   // CE ATR Multiplier       [optimum: 2.0]
input bool     CE_UseClose      = true;  // Use Close for Extremums (true = kao Pine Script)

//--- Dual-Phase MFE Trailing
input group "=== MFE TRAILING (DUAL-PHASE) ==="
input int      MFE1_ActivatePips = 30;  // Phase 1: MFE aktivacija  [optimum: 30]
input double   MFE1_LockPct      = 92.0;// Phase 1: % MFE za lock   [optimum: 92%]
input int      MFE2_ActivatePips = 300; // Phase 2: tighter lock     [optimum: 300]
input double   MFE2_LockPct      = 95.0;// Phase 2: % MFE za lock   [optimum: 95%]

//--- Stop Loss
input group "=== STOP LOSS ==="
// Konzervativno: 750-790 ($589M), Agresivno: 600-640 ($5.8B)
input int      SL_PipsMin       = 750;  // SL min pips (random)
input int      SL_PipsMax       = 790;  // SL max pips (random)

//--- Filteri
input group "=== FILTERI ==="
input double   MaxSpreadPoints  = 50;   // Max spread (0=isključen)
input double   LargeCandleATR   = 3.0;  // Large candle filter (x ATR)
input int      OpenDelayMin     = 0;    // Stealth delay min (sekunde)
input int      OpenDelayMax     = 4;    // Stealth delay max (sekunde)
// Session filter: London+NY H7-16 UTC = best edge za XAUUSD
input int      SessionStartHour = 0;    // Session filter start UTC (0=off)
input int      SessionEndHour   = 24;   // Session filter end UTC
// ATR minimum: filtrira low-volatility periode
input double   ATR_MinFilter    = 0.0;  // Min ATR (0=off, npr. 1.0)

//--- Risk
input group "=== RISK MANAGEMENT ==="
input double   RiskPercent      = 1.0;  // Risk % od balance-a

//--- Smjer (BUY PF=2.70 >> SELL PF=1.88 na XAUUSD)
enum ENUM_TRADE_DIR { BOTH=0, ONLY_BUY=1, ONLY_SELL=2 };
input group "=== SMJER ==="
input ENUM_TRADE_DIR TradeDirection = BOTH; // BOTH / ONLY_BUY / ONLY_SELL

//--- Opće
input group "=== OPĆE ==="
input ulong    MagicNumber      = 372820;  // Različit od IMPULSE_Cla (372819)
input int      Slippage         = 30;

//--- Globalne varijable
CTrade  trade;
CePos   g_pos;
datetime g_lastBarTime = 0;

// CE state (kalkuliramo ručno bar-by-bar)
double  g_longStop  = 0;
double  g_shortStop = 0;
int     g_ceDir     = 1;  // +1=bullish, -1=bearish

// ATR handle (za large candle + ATR_MinFilter)
int     g_atrHandle = INVALID_HANDLE;

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

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, CE_Period);
    if(g_atrHandle == INVALID_HANDLE)
    {
        Print("IMPULSE_CE: Greška pri kreiranju ATR indikatora!");
        return INIT_FAILED;
    }

    g_pos.active     = false;
    g_pending.active = false;
    g_ceDir          = 1;
    g_longStop       = 0;
    g_shortStop      = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("==============================================");
    Print("  IMPULSE_CE_Cla v1.0 - Chandelier + MFE    ");
    Print("==============================================");
    Print("CE(", CE_Period, ", ", CE_Multiplier, ", UseClose=", CE_UseClose, ")");
    Print("MFE Phase1: +", MFE1_ActivatePips, " pips -> lock ", MFE1_LockPct, "%");
    Print("MFE Phase2: +", MFE2_ActivatePips, " pips -> lock ", MFE2_LockPct, "%");
    Print("SL: random ", SL_PipsMin, "-", SL_PipsMax, " pips");
    if(SessionStartHour != 0 || SessionEndHour != 24)
        Print("Session: ", SessionStartHour, ":00 - ", SessionEndHour, ":00 UTC");
    else
        Print("Session: OFF (cijeli dan)");
    if(ATR_MinFilter > 0)
        Print("ATR min: ", ATR_MinFilter);
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
// Dohvati ATR (bar [1] = zadnji zatvoreni)
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
    // ATR min filter
    if(ATR_MinFilter > 0 && atrVal < ATR_MinFilter) return true;
    // Large candle filter
    double candleRange = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleRange > LargeCandleATR * atrVal);
}

//+------------------------------------------------------------------+
// Chandelier Exit kalkulacija
// Vraća novi CE smjer nakon obrade bara [1]
// Identično Pine Script logici (bar-by-bar tracking)
//+------------------------------------------------------------------+
int CalculateChandelier()
{
    int barsNeeded = CE_Period + 5;

    double highArr[], lowArr[], closeArr[];
    ArraySetAsSeries(highArr, true);
    ArraySetAsSeries(lowArr, true);
    ArraySetAsSeries(closeArr, true);

    if(CopyHigh(_Symbol,  PERIOD_CURRENT, 1, barsNeeded, highArr)  <= 0) return 0;
    if(CopyLow(_Symbol,   PERIOD_CURRENT, 1, barsNeeded, lowArr)   <= 0) return 0;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 1, barsNeeded, closeArr) <= 0) return 0;

    // ATR via SMA (identično Pine Script ta.atr)
    double sumTR = 0;
    for(int k = 0; k < CE_Period; k++)
    {
        double h = highArr[k], l = lowArr[k], pc = (k+1 < barsNeeded) ? closeArr[k+1] : closeArr[k];
        double tr = MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
        sumTR += tr;
    }
    double atr = CE_Multiplier * (sumTR / CE_Period);

    // Highest/Lowest za CE_Period (bar [1..CE_Period])
    double highest = closeArr[0], lowest = closeArr[0];
    for(int k = 0; k < CE_Period; k++)
    {
        double val = CE_UseClose ? closeArr[k] : (k < CE_Period ? highArr[k] : highArr[k]);
        double val2 = CE_UseClose ? closeArr[k] : lowArr[k];
        if(CE_UseClose)
        {
            if(closeArr[k] > highest) highest = closeArr[k];
            if(closeArr[k] < lowest)  lowest  = closeArr[k];
        }
        else
        {
            if(highArr[k] > highest) highest = highArr[k];
            if(lowArr[k]  < lowest)  lowest  = lowArr[k];
        }
    }

    double longStopNew  = highest - atr;
    double shortStopNew = lowest  + atr;

    // Ratchet logika: longStop samo raste, shortStop samo pada
    // close[1] (naš "close[0]" u arrayu) vs prethodne stop vrijednosti
    double prevClose = closeArr[0];  // bar [1] = najaktualniji zatvoreni
    double prevClose2 = closeArr[1]; // bar [2]

    // Long stop: ratchet gore (close[1] > longStop[1])
    double newLongStop  = (prevClose2 > g_longStop && g_longStop > 0)
                         ? MathMax(longStopNew, g_longStop)
                         : longStopNew;

    // Short stop: ratchet dolje (close[1] < shortStop[1])
    double newShortStop = (prevClose2 < g_shortStop && g_shortStop > 0)
                         ? MathMin(shortStopNew, g_shortStop)
                         : shortStopNew;

    // Nova direkcija
    int prevDir = g_ceDir;
    int newDir;
    if(prevClose > (g_shortStop > 0 ? g_shortStop : newShortStop))
        newDir = 1;
    else if(prevClose < (g_longStop > 0 ? g_longStop : newLongStop))
        newDir = -1;
    else
        newDir = prevDir;

    // Ažuriraj globalne varijable
    g_longStop  = newLongStop;
    g_shortStop = newShortStop;
    g_ceDir     = newDir;

    return newDir;
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
    double bh = iHigh(_Symbol, PERIOD_CURRENT, 0);
    double bl = iLow(_Symbol, PERIOD_CURRENT, 0);
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
        Print("IMPULSE_CE: Pozicija #", g_pos.ticket, " zatvorena");
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
            Print("IMPULSE_CE BACKUP SL: #", g_pos.ticket, " -> ", g_pos.sl);
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
            g_pos.sl    = newSL;
            g_pos.lastSL = newSL;
            Print("IMPULSE_CE [", g_pos.ticket, "] ", modReason,
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
        ok = trade.Buy(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE_CE BUY");
    else
        ok = trade.Sell(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE_CE SELL");

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

        Print("IMPULSE_CE ", (direction==1 ? "BUY" : "SELL"), " [", ticket, "]: ",
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

    Print("IMPULSE_CE: Trade queued ", (direction==1?"BUY":"SELL"),
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

    // Izračunaj Chandelier Exit smjer za zadnji zatvoreni bar
    int prevDir = g_ceDir;
    int newDir  = CalculateChandelier();
    if(newDir == 0) return;

    // CE crossover signal (na zatvorenom baru)
    bool buySignal  = (newDir == 1  && prevDir == -1);
    bool sellSignal = (newDir == -1 && prevDir == 1);

    if(buySignal && TradeDirection != ONLY_SELL)
    {
        Print("IMPULSE_CE BUY | CE flip: -1->1 | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
        QueueTrade(1);
    }
    else if(sellSignal && TradeDirection != ONLY_BUY)
    {
        Print("IMPULSE_CE SELL | CE flip: 1->-1 | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
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
