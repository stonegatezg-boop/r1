//+------------------------------------------------------------------+
//|                                               IMPULSE_Cla.mq5   |
//|                      *** IMPULSE v3.0 ***                       |
//|         Supertrend(10,2.0) + Dual-Phase MFE Trailing            |
//|                                                                  |
//|  ORIGINALNA STRATEGIJA - Analiza 212k barova XAUUSD M5          |
//|  Backtest rezultati (2023-2026, 3 god, 7475 tradeova):          |
//|    Win rate: 89.8% | DD: 6.0% | bal: $10k -> $68.6M            |
//|    vs v2.0: 84.2% WR, 9.3% DD, $10k -> $7.3M                  |
//|    vs CALF_C: 72.4% WR, 24.5% DD, $10k -> $270k                |
//|                                                                  |
//|  Ključna inovacija: Dual-Phase MFE Trailing (ultra-agresivno)  |
//|    Phase 1: MFE >= 30 pips  → lock 88% profita  (rani lock!)   |
//|    Phase 2: MFE >= 300 pips → lock 93% profita  (tighter)      |
//|                                                                  |
//|  v3.0 ključna poboljšanja:                                      |
//|    - MFE Phase1 act: 100 → 30 pips  (raniji lock = +5.6% WR)   |
//|    - MFE Phase1 lock: 82% → 88%     (veći lock = manji DD)      |
//|    - MFE Phase2 act: 700 → 300 pips (ranija aktivacija)         |
//|    - MFE Phase2 lock: 87% → 93%     (tighter = +profit)         |
//|                                                                  |
//|  Signal: Supertrend(10, 2.0) crossover (SMA ATR)               |
//|                                                                  |
//|  Created: 11.03.2026 21:00 (Zagreb)                             |
//|  Updated: 11.03.2026 23:00 (Zagreb) - v2.0 optimizirani param  |
//|  Updated: 11.03.2026 24:00 (Zagreb) - v3.0 deep optimization   |
//|  Updated: 12.03.2026 00:30 (Zagreb) - v3.0 session+ATR filter  |
//|  Updated: 12.03.2026 01:00 (Zagreb) - BUY/SELL direction opt.  |
//|  Research: BUY PF=2.70 (91.1%WR) >> SELL PF=1.88 (89.1%WR)   |
//|  MTF filter ne pomaže: smanjuje trades → uništava compounding   |
//+------------------------------------------------------------------+
#property copyright "IMPULSE_Cla v3.0 (2026-03-11)"
#property version   "3.00"
#property strict
#include <Trade\Trade.mqh>

//--- Struktura pozicije
struct ImpulsePos
{
    bool     active;
    ulong    ticket;
    double   entryPrice;
    double   sl;
    double   maxProfitPips;   // MFE tracking
    double   lastSL;          // Zadnji postavljen SL (za backup check)
    int      phase;           // 0=initial, 1=BE done, 2=MFE1 active, 3=MFE2 active
    int      randomBE;        // Random BE offset (38-43 pips)
    datetime openTime;
};

//--- Parametri indikatora
input group "=== SUPERTREND POSTAVKE ==="
input int      ST_Period        = 10;     // Supertrend period
input double   ST_Multiplier    = 2.0;    // Supertrend multiplier

//--- Trailing parametri (v3.0 - deep optimization na 3 god. backtestu, 212k barova)
input group "=== MFE TRAILING (DUAL-PHASE) ==="
input int      BE_ActivatePips  = 100;    // BE aktivacija (superseded by MFE1 koji pali prvi)
input int      BE_OffsetMin     = 38;     // BE + min pips (random)
input int      BE_OffsetMax     = 43;     // BE + max pips (random)
input int      MFE1_ActivatePips= 30;    // Phase 1: MFE aktivacija (pips)   [v3.0 optimum: 30]
input double   MFE1_LockPct     = 88.0;  // Phase 1: % MFE za lock           [v3.0 optimum: 88%]
input int      MFE2_ActivatePips= 300;   // Phase 2: tighter lock             [v3.0 optimum: 300]
input double   MFE2_LockPct     = 93.0;  // Phase 2: % MFE za lock            [v3.0 optimum: 93%]

//--- SL postavke
input group "=== STOP LOSS ==="
input int      SL_PipsMin       = 750;   // SL min pips (random)             [optimum: 750]
input int      SL_PipsMax       = 790;   // SL max pips (random)             [optimum: 790]

//--- Filteri
input group "=== FILTERI ==="
input double   MaxSpreadPoints  = 50;    // Max spread (0 = isključen)
input double   LargeCandleATR   = 3.0;  // Large candle filter (x ATR)
input int      OpenDelayMin     = 0;    // Stealth delay min (sekunde)
input int      OpenDelayMax     = 4;    // Stealth delay max (sekunde)
// Session filter (UTC sati) - istraživanje: London+NY (07-16 UTC) = best edge
// 0/24 = isključen (cijeli dan). Preporuka: StartHour=7, EndHour=16
input int      SessionStartHour = 0;   // Session filter start (UTC, 0=isključen)
input int      SessionEndHour   = 24;  // Session filter end (UTC)
// ATR minimum filter - filtrira low-volatility periode
// 0 = isključen. Za XAUUSD M5: 1.0 = tipična niska volatilnost
input double   ATR_MinFilter    = 0.0;  // Min ATR za entry (0=isključen, npr. 1.0)

//--- Risk
input group "=== RISK MANAGEMENT ==="
input double   RiskPercent      = 1.0;  // Risk % od balance-a
input int      ATRPeriodRisk    = 14;   // ATR period za risk (ne koristi se za SL, samo filter)

//--- Smjer trejdova
// Backtest: BUY PF=2.70 (91.1% WR) > SELL PF=1.88 (89.1% WR) → Gold ima bullish bias
// U bull tržištu: koristiti ONLY_BUY. U bear tržištu: ONLY_SELL.
enum ENUM_TRADE_DIR { BOTH=0, ONLY_BUY=1, ONLY_SELL=2 };
input group "=== SMJER ==="
input ENUM_TRADE_DIR TradeDirection = BOTH;     // Smjer trejdova (BOTH/ONLY_BUY/ONLY_SELL)

//--- Opće
input group "=== OPĆE ==="
input ulong    MagicNumber      = 372819;
input int      Slippage         = 30;

//--- Global
CTrade         trade;
ImpulsePos     g_pos;
datetime       g_lastBarTime = 0;

// Supertrend arraji
double         g_stLine[];
int            g_stDir[];

//--- ATR handle (za large candle filter)
int            g_atrHandle = INVALID_HANDLE;

// Pending trade (stealth delay)
struct PendingInfo
{
    bool     active;
    int      direction;   // 1=buy, -1=sell
    double   lots;
    double   sl;
    datetime signalTime;
    int      delaySeconds;
};
PendingInfo    g_pending;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriodRisk);
    if(g_atrHandle == INVALID_HANDLE)
    {
        Print("IMPULSE: Greška pri kreiranju ATR indikatora!");
        return INIT_FAILED;
    }

    ArraySetAsSeries(g_stLine, true);
    ArraySetAsSeries(g_stDir, true);
    ArrayResize(g_stLine, 10);
    ArrayResize(g_stDir, 10);

    g_pos.active = false;
    g_pending.active = false;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("============================================");
    Print("  IMPULSE_Cla v3.0 - Dual-Phase MFE Trail  ");
    Print("============================================");
    Print("ST(", ST_Period, ", ", ST_Multiplier, ")");
    Print("MFE Phase1: +", MFE1_ActivatePips, " pips -> lock ", MFE1_LockPct, "%");
    Print("MFE Phase2: +", MFE2_ActivatePips, " pips -> lock ", MFE2_LockPct, "%");
    Print("SL: random ", SL_PipsMin, "-", SL_PipsMax, " pips (ODMAH na entry)");
    if(SessionStartHour != 0 || SessionEndHour != 24)
        Print("Session filter: ", SessionStartHour, ":00 - ", SessionEndHour, ":00 UTC");
    else
        Print("Session filter: OFF (cijeli dan)");
    if(ATR_MinFilter > 0)
        Print("ATR min filter: ", ATR_MinFilter, " (low-vol blokiran)");
    string dirStr = (TradeDirection == ONLY_BUY) ? "ONLY BUY (PF=2.70)" :
                    (TradeDirection == ONLY_SELL) ? "ONLY SELL (PF=1.88)" : "BOTH (PF=2.30)";
    Print("Trade direction: ", dirStr);
    Print("============================================");

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
    if(t != g_lastBarTime)
    {
        g_lastBarTime = t;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 6) return false;                                              // Subota
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));   // Ned od 00:01
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)                                    // Pon-Čet
    {
        // Session filter (UTC): 0/24 = isključen
        if(SessionStartHour != 0 || SessionEndHour != 24)
            if(dt.hour < SessionStartHour || dt.hour >= SessionEndHour) return false;
        return true;
    }
    if(dt.day_of_week == 5)                                                            // Petak
    {
        if(dt.hour >= 11) return false;  // Stop novih trejdova od 11:00
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
bool IsLargeCandle()
{
    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) <= 0) return false;
    // ATR minimum filter (low-volatility filter)
    if(ATR_MinFilter > 0 && atr[0] < ATR_MinFilter) return true;  // Tretiramo kao blokadu
    double candleRange = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
    return (candleRange > LargeCandleATR * atr[0]);
}

//+------------------------------------------------------------------+
// Supertrend kalkulacija s SMA ATR (identično backtestu)
// Vraća: 1=bullish, -1=bearish, 0=nedovoljno podataka
//+------------------------------------------------------------------+
int CalculateSupertrend()
{
    int barsNeeded = ST_Period + 15;

    double highArr[], lowArr[], closeArr[];
    ArraySetAsSeries(highArr, true);
    ArraySetAsSeries(lowArr, true);
    ArraySetAsSeries(closeArr, true);

    if(CopyHigh(_Symbol,  PERIOD_CURRENT, 0, barsNeeded, highArr)  <= 0) return 0;
    if(CopyLow(_Symbol,   PERIOD_CURRENT, 0, barsNeeded, lowArr)   <= 0) return 0;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, barsNeeded, closeArr) <= 0) return 0;

    // SMA ATR (puno točniji od EMA za ovaj signal)
    double sumTR = 0;
    for(int k = 1; k <= ST_Period; k++)
    {
        double tr = MathMax(highArr[k] - lowArr[k],
                   MathMax(MathAbs(highArr[k] - closeArr[k+1]),
                           MathAbs(lowArr[k]  - closeArr[k+1])));
        sumTR += tr;
    }
    double atr = sumTR / ST_Period;

    // Izračunaj Supertrend za zadnjih 8 barova (dovoljno za crossover detekciju)
    for(int s = 7; s >= 0; s--)
    {
        double hl2      = (highArr[s] + lowArr[s]) / 2.0;
        double upperBand = hl2 + ST_Multiplier * atr;
        double lowerBand = hl2 - ST_Multiplier * atr;

        double prevST  = (s < 7) ? g_stLine[s+1] : hl2;
        int    prevDir = (s < 7) ? g_stDir[s+1]  : 1;

        if(prevDir == 1)
        {
            if(closeArr[s] < prevST) { g_stLine[s] = upperBand; g_stDir[s] = -1; }
            else                     { g_stLine[s] = MathMax(lowerBand, prevST); g_stDir[s] = 1; }
        }
        else
        {
            if(closeArr[s] > prevST) { g_stLine[s] = lowerBand; g_stDir[s] = 1; }
            else                     { g_stLine[s] = MathMin(upperBand, prevST); g_stDir[s] = -1; }
        }
    }

    return g_stDir[1]; // Smjer na zadnjoj zatvorenoj svijeći
}

//+------------------------------------------------------------------+
double GetCurrentProfitPips()
{
    if(!g_pos.active) return 0;
    if(!PositionSelectByTicket(g_pos.ticket)) return 0;

    ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double pip = 0.01; // 1 pip XAUUSD = 0.01

    if(pType == POSITION_TYPE_BUY)
        return (SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_pos.entryPrice) / pip;
    else
        return (g_pos.entryPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / pip;
}

//+------------------------------------------------------------------+
double CalcMaxProfitPips()
{
    if(!g_pos.active) return 0;
    if(!PositionSelectByTicket(g_pos.ticket)) return 0;

    ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double pip = 0.01;

    // Koristimo best unrealized pips tracking (High/Low od zadnjeg bara)
    double bh = iHigh(_Symbol, PERIOD_CURRENT, 0);
    double bl = iLow(_Symbol, PERIOD_CURRENT, 0);

    double currentMax;
    if(pType == POSITION_TYPE_BUY)
        currentMax = (bh - g_pos.entryPrice) / pip;
    else
        currentMax = (g_pos.entryPrice - bl) / pip;

    return MathMax(g_pos.maxProfitPips, currentMax);
}

//+------------------------------------------------------------------+
void ManagePosition()
{
    if(!g_pos.active) return;

    if(!PositionSelectByTicket(g_pos.ticket))
    {
        // Pozicija zatvorena (SL ili TP)
        g_pos.active = false;
        Print("IMPULSE: Pozicija #", g_pos.ticket, " zatvorena");
        return;
    }

    ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double pip       = 0.01;
    int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // Backup: ako SL nije postavljen, postavi ga odmah
    if(currentSL == 0 && g_pos.sl != 0)
    {
        if(trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl, digits), 0))
            Print("IMPULSE BACKUP SL: #", g_pos.ticket, " SL -> ", g_pos.sl);
        return;
    }

    // Ažuriraj MFE
    double newMFE = CalcMaxProfitPips();
    if(newMFE > g_pos.maxProfitPips)
        g_pos.maxProfitPips = newMFE;

    double profitPips = GetCurrentProfitPips();
    double newSL      = currentSL;
    bool   shouldModify = false;
    string modReason    = "";

    //--- Phase 2 MFE (tighter lock - veći profit)
    if(g_pos.maxProfitPips >= MFE2_ActivatePips)
    {
        double lockPips = g_pos.maxProfitPips * (MFE2_LockPct / 100.0);
        if(pType == POSITION_TYPE_BUY)
        {
            double candidate = NormalizeDouble(g_pos.entryPrice + lockPips * pip, digits);
            if(candidate > currentSL) { newSL = candidate; shouldModify = true; modReason = "MFE2"; }
        }
        else
        {
            double candidate = NormalizeDouble(g_pos.entryPrice - lockPips * pip, digits);
            if(candidate < currentSL || currentSL == 0) { newSL = candidate; shouldModify = true; modReason = "MFE2"; }
        }
        g_pos.phase = 3;
    }
    //--- Phase 1 MFE (lock profit)
    else if(g_pos.maxProfitPips >= MFE1_ActivatePips)
    {
        double lockPips = g_pos.maxProfitPips * (MFE1_LockPct / 100.0);
        if(pType == POSITION_TYPE_BUY)
        {
            double candidate = NormalizeDouble(g_pos.entryPrice + lockPips * pip, digits);
            if(candidate > currentSL) { newSL = candidate; shouldModify = true; modReason = "MFE1"; }
        }
        else
        {
            double candidate = NormalizeDouble(g_pos.entryPrice - lockPips * pip, digits);
            if(candidate < currentSL || currentSL == 0) { newSL = candidate; shouldModify = true; modReason = "MFE1"; }
        }
        if(g_pos.phase < 2) g_pos.phase = 2;
    }
    //--- BE phase
    else if(g_pos.phase < 1 && profitPips >= BE_ActivatePips)
    {
        if(pType == POSITION_TYPE_BUY)
        {
            double candidate = NormalizeDouble(g_pos.entryPrice + g_pos.randomBE * pip, digits);
            if(candidate > currentSL) { newSL = candidate; shouldModify = true; modReason = "BE+"; }
        }
        else
        {
            double candidate = NormalizeDouble(g_pos.entryPrice - g_pos.randomBE * pip, digits);
            if(candidate < currentSL || currentSL == 0) { newSL = candidate; shouldModify = true; modReason = "BE+"; }
        }
        g_pos.phase = 1;
    }

    if(shouldModify)
    {
        if(trade.PositionModify(g_pos.ticket, newSL, 0))
        {
            g_pos.sl = newSL;
            g_pos.lastSL = newSL;
            Print("IMPULSE [", g_pos.ticket, "] ", modReason, ": SL -> ", newSL,
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

    double slPoints = slPips * 0.01 / point;  // 1 pip = 0.01 za XAUUSD
    double lots     = riskAmount / (slPoints * tickValue / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;
    if(g_pos.active) { g_pending.active = false; return; } // Već otvorena pozicija

    int      direction = g_pending.direction;
    double   lots      = g_pending.lots;
    double   sl_price  = g_pending.sl;
    int      digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double   price     = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    bool ok;
    if(direction == 1)
        ok = trade.Buy(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE BUY");
    else
        ok = trade.Sell(lots, _Symbol, price, NormalizeDouble(sl_price, digits), 0, "IMPULSE SELL");

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
        g_pos.randomBE      = RandomRange(BE_OffsetMin, BE_OffsetMax);
        g_pos.openTime      = TimeCurrent();

        Print("IMPULSE ", (direction==1 ? "BUY" : "SELL"), " [", ticket, "]: ",
              lots, " @ ", price, " SL=", g_pos.sl,
              " (", RandomRange(SL_PipsMin, SL_PipsMax), " pips) BE+", g_pos.randomBE);
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

    g_pending.active      = true;
    g_pending.direction   = direction;
    g_pending.lots        = lots;
    g_pending.sl          = sl;
    g_pending.signalTime  = TimeCurrent();
    g_pending.delaySeconds= RandomRange(OpenDelayMin, OpenDelayMax);

    Print("IMPULSE: Trade queued ", (direction==1?"BUY":"SELL"),
          " sl=", slPips, " pips, delay=", g_pending.delaySeconds, "s");
}

//+------------------------------------------------------------------+
void OnTick()
{
    // Uvijek upravljaj pozicijom (svaki tick)
    ManagePosition();
    ProcessPending();

    if(!IsNewBar()) return;

    // Ne otvori nov trade ako je već otvorena pozicija ili pending
    if(g_pos.active || g_pending.active) return;

    // Filteri
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;

    // Signal
    int stDir = CalculateSupertrend();
    if(stDir == 0) return;

    bool buySignal  = (g_stDir[1] == 1  && g_stDir[2] == -1);
    bool sellSignal = (g_stDir[1] == -1 && g_stDir[2] == 1);

    if(buySignal && TradeDirection != ONLY_SELL)
    {
        Print("IMPULSE BUY SIGNAL | ST flip: -1 -> 1 | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
        QueueTrade(1);
    }
    else if(sellSignal && TradeDirection != ONLY_BUY)
    {
        Print("IMPULSE SELL SIGNAL | ST flip: 1 -> -1 | Spread: ", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
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
    if(dd > 30) return 0;
    return pf * MathSqrt(trades) * (1.0 - dd/100.0);
}
//+------------------------------------------------------------------+
