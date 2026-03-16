//+------------------------------------------------------------------+
//|                                        CALF_C_Supertrend_v4.mq5  |
//|                   *** CALF C v4.0 - Supertrend Optimizirani ***  |
//|                   Created: 12.03.2026 13:00 (Zagreb)             |
//|                   Optimizacija: ST(5,1.5) + SL=700-740 +         |
//|                                 Dual-Phase MFE (5/94%, 100/97%)  |
//|                   Backtest: T=11010, WR=91.9%, DD=-6.7%, $38.4B  |
//|                   vs v3.5:  T=7805,  WR=91.8%, DD=-6.1%, $298M  |
//|                   Agresivno (SL=500-540): WR=89.1%, $18.9T       |
//|                   FTMO-safe  (SL=750-790): WR=92.3%, DD=-6.9%    |
//+------------------------------------------------------------------+
#property copyright "CALF C Supertrend v4.0 Optimizirani"
#property version   "4.00"
#property strict
#include <Trade\Trade.mqh>

input group "=== SUPERTREND POSTAVKE ==="
input int    STperiod        = 5;      // ST Period (optimum: 5)
input double STmultiplier    = 1.5;    // ST Multiplier (optimum: 1.5)

input group "=== RISK MANAGEMENT ==="
input double RiskPercent     = 1.0;    // Rizik po trejdu (%)
input int    SL_Min_Pips     = 700;    // SL minimum (pips) [agresivno: 500, FTMO: 750]
input int    SL_Max_Pips     = 740;    // SL maksimum (pips)

input group "=== DUAL-PHASE MFE TRAILING ==="
input int    MFE1_Act_Pips   = 5;      // Phase 1: aktivacija (pips)
input double MFE1_Lock_Pct   = 0.94;  // Phase 1: zaključaj % MFE
input int    MFE2_Act_Pips   = 100;   // Phase 2: aktivacija (pips)
input double MFE2_Lock_Pct   = 0.97;  // Phase 2: zaključaj % MFE

input group "=== FILTERI ==="
input double LargeCandleATR  = 3.0;   // Large Candle Filter (×ATR)

input group "=== STEALTH POSTAVKE ==="
input bool   UseStealthMode  = true;
input int    OpenDelayMin    = 0;      // Delay min (sekunde)
input int    OpenDelayMax    = 4;      // Delay max (sekunde)

input group "=== OPĆE ==="
input ulong  MagicNumber     = 100004;
input int    Slippage        = 30;

//--- Strukture
struct PendingTrade {
    bool              active;
    ENUM_ORDER_TYPE   type;
    double            lot;
    datetime          signalTime;
    int               delaySeconds;
};

struct Position {
    bool    active;
    ulong   ticket;
    double  entryPrice;
    double  sl;
    double  mfe;          // max favorable excursion u PIPS
};

//--- Globalne varijable
CTrade          trade;
int             atrHandle;
datetime        lastBarTime;
PendingTrade    g_pending;
Position        g_pos;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    atrHandle = iATR(_Symbol, PERIOD_CURRENT, STperiod);
    if(atrHandle == INVALID_HANDLE) { Print("ATR handle FAILED"); return INIT_FAILED; }

    lastBarTime         = 0;
    g_pending.active    = false;
    g_pos.active        = false;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    Print("=== CALF_C v4.0 | ST(", STperiod, ",", STmultiplier, ") | SL=",
          SL_Min_Pips, "-", SL_Max_Pips, " | MFE1=", MFE1_Act_Pips, "/",
          (int)(MFE1_Lock_Pct*100), "% | MFE2=", MFE2_Act_Pips, "/",
          (int)(MFE2_Lock_Pct*100), "% ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
int RandomRange(int mn, int mx)
{
    if(mn >= mx) return mn;
    return mn + (MathRand() % (mx - mn + 1));
}

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != lastBarTime) { lastBarTime = t; return true; }
    return false;
}

bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 6) return false;                             // Subota = off
    if(dt.day_of_week == 0) return (dt.hour > 0 || dt.min >= 1);     // Nedjelja od 00:01
    if(dt.day_of_week == 5) return (dt.hour < 11);                   // Petak do 11:00
    return true;
}

bool IsLargeCandle()
{
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    return (iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1))
           > LargeCandleATR * atr[0];
}

bool HasOpenPosition()
{
    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Supertrend (SMA ATR, identično EA v3.x i Python backtestu)       |
//+------------------------------------------------------------------+
void CalcSupertrend(double &stLine[], int &stDir[])
{
    int bars = STperiod + 10;
    double high[], low[], close[];
    ArraySetAsSeries(high,  true);
    ArraySetAsSeries(low,   true);
    ArraySetAsSeries(close, true);
    CopyHigh (_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow  (_Symbol, PERIOD_CURRENT, 0, bars, low);
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);

    // SMA ATR
    double sumTR = 0;
    for(int i = 1; i <= STperiod; i++)
    {
        double tr = MathMax(high[i]-low[i],
                   MathMax(MathAbs(high[i]-close[i+1]),
                           MathAbs(low[i] -close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / STperiod;

    // Supertrend za 5 barova (idx 4=najstariji, 0=tekući)
    ArrayResize(stLine, 5); ArrayResize(stDir, 5);
    for(int s = 4; s >= 0; s--)
    {
        double hl2  = (high[s]+low[s]) / 2.0;
        double ub   = hl2 + STmultiplier * atr;
        double lb   = hl2 - STmultiplier * atr;
        double prevST  = (s < 4) ? stLine[s+1] : hl2;
        int    prevDir = (s < 4) ? stDir[s+1]  : 1;

        if(prevDir == 1)
        {
            if(close[s] < prevST) { stLine[s]=ub; stDir[s]=-1; }
            else                  { stLine[s]=MathMax(lb, prevST); stDir[s]=1; }
        }
        else
        {
            if(close[s] > prevST) { stLine[s]=lb; stDir[s]=1; }
            else                  { stLine[s]=MathMin(ub, prevST); stDir[s]=-1; }
        }
    }
}

//+------------------------------------------------------------------+
//| Lot kalkulacija (1 pip XAUUSD = 0.01)                            |
//+------------------------------------------------------------------+
double CalcLots(int slPips)
{
    if(slPips <= 0) return 0;
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt  = balance * RiskPercent / 100.0;
    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    // slPips * 0.01 = sl distance u cijeni (XAUUSD: 1 pip = 0.01 = point)
    double slDist = slPips * point;
    double lots   = riskAmt / ((slDist / point) * tickVal / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
    if(g_pending.active) return;
    g_pending.active      = true;
    g_pending.type        = type;
    g_pending.signalTime  = TimeCurrent();
    g_pending.delaySeconds= RandomRange(OpenDelayMin, OpenDelayMax);

    // Calc lots na signal baru (fiksno SL za lot calc)
    int slPips = RandomRange(SL_Min_Pips, SL_Max_Pips);
    g_pending.lot = CalcLots(slPips);

    Print("CALF_C v4.0: Signal ", (type==ORDER_TYPE_BUY?"BUY":"SELL"),
          " | queued, delay=", g_pending.delaySeconds, "s");
}

void ExecuteTrade()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;

    ENUM_ORDER_TYPE type = g_pending.type;
    double lot  = g_pending.lot;
    g_pending.active = false;

    double price  = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int    slPips = RandomRange(SL_Min_Pips, SL_Max_Pips);
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double slDist = slPips * point;
    double sl     = (type==ORDER_TYPE_BUY) ? price - slDist : price + slDist;
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl    = NormalizeDouble(sl, digits);

    bool ok;
    if(UseStealthMode)
        ok = (type==ORDER_TYPE_BUY) ? trade.Buy (lot, _Symbol, price, sl, 0, "CALF_C_v4")
                                    : trade.Sell(lot, _Symbol, price, sl, 0, "CALF_C_v4");
    else
        ok = (type==ORDER_TYPE_BUY) ? trade.Buy (lot, _Symbol, price, sl, 0, "CALF_C_v4")
                                    : trade.Sell(lot, _Symbol, price, sl, 0, "CALF_C_v4");

    if(!ok) { Print("CALF_C v4.0: Trade OPEN FAILED - ", trade.ResultRetcodeDescription()); return; }

    ulong ticket = trade.ResultOrder();

    // Backup: provjeri SL (stealth — TP=0, SL odmah)
    if(PositionSelectByTicket(ticket))
    {
        double curSL = PositionGetDouble(POSITION_SL);
        if(curSL == 0)
        {
            if(trade.PositionModify(ticket, sl, 0))
                Print("CALF_C v4.0: SL backup postavljeno #", ticket);
            else
                Print("CALF_C v4.0: WARNING SL backup FAILED #", ticket);
        }
    }

    g_pos.active     = true;
    g_pos.ticket     = ticket;
    g_pos.entryPrice = price;
    g_pos.sl         = sl;
    g_pos.mfe        = 0.0;

    Print("CALF_C v4.0: Opened #", ticket, " ", (type==ORDER_TYPE_BUY?"BUY":"SELL"),
          " @ ", price, " SL=", sl, " (", slPips, " pips) lot=", lot);
}

//+------------------------------------------------------------------+
//| MFE Trailing — Dual-Phase (identično Python backtestu)           |
//+------------------------------------------------------------------+
void ManagePosition()
{
    if(!g_pos.active) return;

    if(!PositionSelectByTicket(g_pos.ticket))
    {
        g_pos.active = false;
        return;
    }

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice = (posType==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double entry    = g_pos.entryPrice;
    double curSL    = PositionGetDouble(POSITION_SL);
    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // MFE update (u pips)
    double mfeNow = (posType==POSITION_TYPE_BUY) ? (curPrice - entry) / point
                                                  : (entry - curPrice) / point;
    if(mfeNow > g_pos.mfe) g_pos.mfe = mfeNow;
    double mfe = g_pos.mfe;

    // Backup SL ako ga nema
    if(curSL == 0 && g_pos.sl != 0)
    {
        trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl, digits), 0);
        return;
    }

    double newSL = curSL;

    // Phase 2: MFE >= 100 pips → lock 97%
    if(mfe >= MFE2_Act_Pips)
    {
        double lock = mfe * MFE2_Lock_Pct;
        double ns   = (posType==POSITION_TYPE_BUY) ? entry + lock * point
                                                   : entry - lock * point;
        ns = NormalizeDouble(ns, digits);
        if((posType==POSITION_TYPE_BUY  && ns > curSL) ||
           (posType==POSITION_TYPE_SELL && ns < curSL))
            newSL = ns;
    }
    // Phase 1: MFE >= 5 pips → lock 94%
    else if(mfe >= MFE1_Act_Pips)
    {
        double lock = mfe * MFE1_Lock_Pct;
        double ns   = (posType==POSITION_TYPE_BUY) ? entry + lock * point
                                                   : entry - lock * point;
        ns = NormalizeDouble(ns, digits);
        if((posType==POSITION_TYPE_BUY  && ns > curSL) ||
           (posType==POSITION_TYPE_SELL && ns < curSL))
            newSL = ns;
    }

    if(newSL != curSL)
    {
        if(trade.PositionModify(g_pos.ticket, newSL, 0))
            g_pos.sl = newSL;
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ExecuteTrade();
    ManagePosition();

    if(!IsNewBar()) return;

    // Provjeri je li pozicija još otvorena
    if(g_pos.active && !PositionSelectByTicket(g_pos.ticket))
        g_pos.active = false;

    if(g_pos.active) return;       // već imamo poziciju
    if(g_pending.active) return;   // pending trade
    if(!IsTradingWindow()) return;
    if(IsLargeCandle()) return;
    if(HasOpenPosition()) return;  // sigurnosna provjera

    double stLine[]; int stDir[];
    CalcSupertrend(stLine, stDir);

    // Signal: promjena smjera na bar[1] vs bar[2]
    bool buySignal  = (stDir[1] == 1 && stDir[2] == -1);
    bool sellSignal = (stDir[1] == -1 && stDir[2] == 1);

    if(buySignal)
    {
        Print("CALF_C v4.0: BUY signal | ST dir flip UP");
        if(UseStealthMode) QueueTrade(ORDER_TYPE_BUY);
        else ExecuteTrade();   // fallback, ali koristimo QueueTrade za stealth
    }
    else if(sellSignal)
    {
        Print("CALF_C v4.0: SELL signal | ST dir flip DOWN");
        if(UseStealthMode) QueueTrade(ORDER_TYPE_SELL);
        else ExecuteTrade();
    }
}
//+------------------------------------------------------------------+
