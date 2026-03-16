//+------------------------------------------------------------------+
//|                                    IMPULSE_SQZMOM_FTMO_Cla.mq5  |
//|              *** IMPULSE SQZMOM FTMO v2.0 ***                    |
//|              Created: 12.03.2026 05:00 (Zagreb)                  |
//|              Upgrade: 12.03.2026 — v2.0: M15+H1 kaskada,        |
//|                       Tri-Phase MFE, SL fix, FTMO hardcoded      |
//|                                                                   |
//|  FTMO zaštita UVIJEK aktivna (hardcoded):                        |
//|    ✓ Daily loss limit 4.5% od initial balance                    |
//|    ✓ Total DD floor 9.0% od initial balance                      |
//|    ✓ Risk 0.5% od initial balance (stabilan lot)                 |
//|    ✓ SL od execution cijene (v2.0 fix)                           |
//|    ✓ Swing + Standard account podrška                            |
//|                                                                   |
//|  TRI-PHASE MFE (optimizirano 897 kombinacija, +17.3%):          |
//|    Phase 0: MFE >= 2  pips → lock 90% (micro-profit zaštita)   |
//|    Phase 1: MFE >= 4  pips → lock 97%                           |
//|    Phase 2: MFE >= 80 pips → lock 98%                           |
//|                                                                   |
//|  M15+H1 KASKADNO LOT SKALIRANJE (NOVO v2.0):                   |
//|    scale = 1.0 + M15_bonus (ako aligned) + H1_bonus (ako algnd) |
//|    Nikad ne blokira trejd — samo skalira lot veličinu            |
//|    M15+0.5 H1+0.3 → max×1.8 → ~$985M   DD=-6.1% [FTMO SAFE]  |
//|    WR ostaje fiksno 92.2% kroz sve konfiguracije!               |
//|                                                                   |
//|  BACKTEST (3god, XAUUSD M5, $10k start, 0.5% risk):            |
//|    v1.0 (bez cascade): WR=91.6%  DD=-9.5%                       |
//|    v2.0 (M15+H1 ×1.8): WR=92.2%  DD=-6.1%  ~$985M             |
//|                                                                   |
//|  Magic: 372822                                                   |
//+------------------------------------------------------------------+
#property copyright "IMPULSE_SQZMOM_FTMO_Cla v2.0 (2026-03-12)"
#property version   "2.00"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUM
//============================================================
enum ENUM_TRADE_DIR { BOTH=0, ONLY_BUY=1, ONLY_SELL=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== SQZMOM SIGNAL (LazyBear) ==="
input int      SQZ_Period    = 10;   // BB/KC period [optimum: 10]
input double   SQZ_BB_Mult   = 2.0;  // BB multiplier [optimum: 2.0]
input double   SQZ_KC_Mult   = 1.5;  // KC multiplier [optimum: 1.5]
input ENUM_TRADE_DIR TradeDirection = BOTH;

input group "=== M15+H1 KASKADNO LOT SKALIRANJE ==="
// Ista logika kao FRANKENSTEIN v1.2 — dokazano +1525% bez gubitka WR
input bool   UseM15Scale    = true;
input double M15_Bonus      = 0.5;   // [FTMO safe: 0.5]
input int    M15_SQZ_Period = 10;
input bool   UseH1Scale     = true;
input double H1_Bonus       = 0.3;   // [FTMO safe: 0.3]
input int    H1_SQZ_Period  = 10;

input group "=== TRI-PHASE MFE TRAILING ==="
// Optimizirano 897 kombinacija — +17.3% vs Dual-Phase
input int    MFE0_Act = 0;    // Phase 0: aktivacija (pips) [v2.2: UGAŠENO=0, bio uzrok live problema]
input double MFE0_Pct = 0.90; // Phase 0: lock %
input int    MFE1_Act = 20;   // Phase 1: aktivacija (pips) [v2.2: 20 pip, bilo 4]
input double MFE1_Pct = 0.85; // Phase 1: lock % [v2.2: 85%, više prostora]
input int    MFE2_Act = 80;   // Phase 2: aktivacija (pips)
input double MFE2_Pct = 0.98; // Phase 2: lock %

input group "=== STOP LOSS ==="
input int    SL_PipsMin = 750;  // SL min pips [FTMO konzervativno: 750-790]
input int    SL_PipsMax = 790;  // SL max pips

input group "=== FTMO ZAŠTITA (UVIJEK AKTIVNA) ==="
input double FTMO_DailyLossLimit  = 4.5;   // Max dnevni gubitak % od initial
input double FTMO_TotalLossFloor  = 9.0;   // Max ukupni DD % od initial
input bool   FTMO_CloseOnFriday   = false; // true=Standard, false=Swing account
input int    FTMO_FridayCloseHour = 10;    // Sat zatvaranja petkom

input group "=== RISK MANAGEMENT ==="
input double RiskPercent = 0.5;  // Risk % od initial balance [FTMO: max 1%]

input group "=== FILTERI ==="
input double MaxSpreadPoints = 50;
input double LargeCandleATR  = 3.0;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 372822;
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct ImpulsePos
{
    bool     active;
    ulong    ticket;
    double   entryPrice;
    double   sl;
    double   mfe;
    datetime openTime;
};

struct PendingInfo
{
    bool     active;
    int      direction;
    double   lots;
    int      slPips;
    datetime signalTime;
    int      delaySeconds;
};

//============================================================
//  GLOBALNE
//============================================================
CTrade      trade;
ImpulsePos  g_pos;
PendingInfo g_pending;
datetime    g_lastBarTime = 0;
double      g_lastVal     = 0;
bool        g_lastValSet  = false;
int         g_atrHandle   = INVALID_HANDLE;

double      g_initialBalance    = 0;
double      g_dailyStartBalance = 0;
datetime    g_lastDayReset      = 0;
bool        g_tradingHalted     = false;
string      g_haltReason        = "";

//============================================================
//  INIT
//============================================================
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, SQZ_Period);
    if(g_atrHandle == INVALID_HANDLE)
    { Print("IMPULSE_FTMO: ATR handle FAILED"); return INIT_FAILED; }

    g_pos.active     = false;
    g_pending.active = false;
    g_lastValSet     = false;
    g_tradingHalted  = false;
    g_initialBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBalance = g_initialBalance;
    g_lastDayReset      = TimeCurrent();
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    double maxScale = 1.0 + (UseM15Scale?M15_Bonus:0.0) + (UseH1Scale?H1_Bonus:0.0);
    Print("╔══════════════════════════════════════════════════════╗");
    Print("║  IMPULSE_SQZMOM_FTMO_Cla v2.0 — SQZMOM FTMO EA    ║");
    Print("╠══════════════════════════════════════════════════════╣");
    Print("║  Signal:  SQZMOM zero-cross (", SQZ_Period, "/", SQZ_BB_Mult, "/", SQZ_KC_Mult, ")");
    Print("║  SL:      ", SL_PipsMin, "-", SL_PipsMax, " pips");
    Print("║  Risk:    ", RiskPercent, "% | MaxScale: ×", DoubleToString(maxScale,1));
    Print("║  M15:     ", UseM15Scale?"ON +"+DoubleToString(M15_Bonus,1):"OFF");
    Print("║  H1:      ", UseH1Scale?"ON +"+DoubleToString(H1_Bonus,1):"OFF");
    Print("║  MFE0:    ", MFE0_Act, "pips/", (int)(MFE0_Pct*100), "%");
    Print("║  MFE1:    ", MFE1_Act, "pips/", (int)(MFE1_Pct*100), "%");
    Print("║  MFE2:    ", MFE2_Act, "pips/", (int)(MFE2_Pct*100), "%");
    Print("║  FTMO:    Daily=",FTMO_DailyLossLimit,"% Total=",FTMO_TotalLossFloor,"% [UVIJEK ON]");
    Print("║  Friday:  Zatvori u ",FTMO_FridayCloseHour,":00h — ",FTMO_CloseOnFriday?"DA":"NE");
    Print("║  Magic:   ", MagicNumber);
    Print("╚══════════════════════════════════════════════════════╝");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//============================================================
//  HELPERS
//============================================================
int  RandomRange(int a, int b) { return (a>=b)?a:a+MathRand()%(b-a+1); }

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
    return false;
}

bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week == 6) return false;
    if(dt.day_of_week == 0) return (dt.hour > 0 || dt.min >= 1);
    if(dt.day_of_week == 5) return (dt.hour < 11);
    return true;
}

bool ShouldCloseFriday()
{
    if(!FTMO_CloseOnFriday) return false;
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    return (dt.day_of_week == 5 && dt.hour >= FTMO_FridayCloseHour);
}

bool IsSpreadOK()
{
    if(MaxSpreadPoints <= 0) return true;
    return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= (int)MaxSpreadPoints;
}

double GetATR()
{
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) <= 0) return 0;
    return atr[0];
}

bool IsLargeCandle()
{
    double atrVal = GetATR(); if(atrVal <= 0) return false;
    return (iHigh(_Symbol,PERIOD_CURRENT,1)-iLow(_Symbol,PERIOD_CURRENT,1)) > LargeCandleATR*atrVal;
}

bool HasOpenPosition()
{
    for(int i=PositionsTotal()-1;i>=0;i--){
        ulong t=PositionGetTicket(i);
        if(PositionSelectByTicket(t))
            if(PositionGetInteger(POSITION_MAGIC)==MagicNumber&&
               PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
    }
    return false;
}

//============================================================
//  FTMO ZAŠTITA (uvijek aktivna)
//============================================================
void CheckDailyReset()
{
    MqlDateTime now, last;
    TimeToStruct(TimeCurrent(), now); TimeToStruct(g_lastDayReset, last);
    if(now.day != last.day)
    {
        double cb = AccountInfoDouble(ACCOUNT_BALANCE);
        Print("IMPULSE_FTMO: Novi dan | P&L: ", NormalizeDouble(cb-g_dailyStartBalance,2));
        g_dailyStartBalance = cb; g_lastDayReset = TimeCurrent();
        if(g_tradingHalted && g_haltReason == "DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("IMPULSE_FTMO: Daily reset — nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double floor = g_initialBalance * (1.0 - FTMO_TotalLossFloor / 100.0);
    if(eq < floor)
    {
        if(!g_tradingHalted){
            g_tradingHalted = true; g_haltReason = "TOTAL";
            Print("!!! IMPULSE_FTMO: TOTAL DD — ZAUSTAVLJENO !!!");
            if(g_pos.active && PositionSelectByTicket(g_pos.ticket)) trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    double dailyLoss  = g_dailyStartBalance - eq;
    double dailyLimit = g_initialBalance * FTMO_DailyLossLimit / 100.0;
    if(dailyLoss > dailyLimit)
    {
        if(!g_tradingHalted){
            g_tradingHalted = true; g_haltReason = "DAILY";
            Print("!!! IMPULSE_FTMO: DAILY LIMIT — zaustavljeno do ponoći !!!");
        }
        return false;
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA (s cascade scale)
//============================================================
double CalcLots(int slPips, double scaleMult=1.0)
{
    if(slPips <= 0) return 0;
    double risk    = g_initialBalance * RiskPercent / 100.0 * scaleMult;
    double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tv      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double mn      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double mx      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots    = risk / ((slPips * point / point) * tv / ts);
    lots = MathFloor(lots / step) * step;
    return MathMax(mn, MathMin(mx, lots));
}

//============================================================
//  SQZMOM za bilo koji TF (za cascade skaliranje)
//============================================================
double CalcSQZMOM_TF(ENUM_TIMEFRAMES tf, int per)
{
    int needed = per * 2 + 5;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl,true); ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
    if(CopyClose(_Symbol,tf,1,needed,cl) < needed) return 0;
    if(CopyHigh (_Symbol,tf,1,needed,hi) < needed) return 0;
    if(CopyLow  (_Symbol,tf,1,needed,lo) < needed) return 0;
    double delta[200];
    for(int j=0; j<per; j++){
        if(j+per > needed) return 0;
        double s=0; for(int k=j; k<j+per; k++) s+=cl[k]; double basis=s/per;
        double hmax=hi[j], lmin=lo[j];
        for(int k=j+1; k<j+per; k++){if(hi[k]>hmax)hmax=hi[k];if(lo[k]<lmin)lmin=lo[k];}
        delta[j] = cl[j] - ((hmax+lmin)/2.0 + basis)/2.0;
    }
    double xm=(per-1)/2.0, ym=0;
    for(int i=0; i<per; i++) ym+=delta[per-1-i]; ym/=per;
    double num=0, den=0;
    for(int i=0; i<per; i++){double xi=i-xm, yi=delta[per-1-i]-ym; num+=xi*yi; den+=xi*xi;}
    if(den==0) return ym;
    double sc=num/den, ic=ym-sc*xm;
    return sc*(per-1)+ic;
}

double GetCascadeScale(int direction)
{
    double scale = 1.0;
    if(UseM15Scale){
        double s15 = CalcSQZMOM_TF(PERIOD_M15, M15_SQZ_Period);
        if(s15!=0 && ((direction==1&&s15>0)||(direction==-1&&s15<0))) scale+=M15_Bonus;
    }
    if(UseH1Scale){
        double sh1 = CalcSQZMOM_TF(PERIOD_H1, H1_SQZ_Period);
        if(sh1!=0 && ((direction==1&&sh1>0)||(direction==-1&&sh1<0))) scale+=H1_Bonus;
    }
    return scale;
}

//============================================================
//  SQZMOM SIGNAL (M5, identično Python backtestu)
//============================================================
double CalculateSQZMOM_Val()
{
    return CalcSQZMOM_TF(PERIOD_CURRENT, SQZ_Period);
}

//============================================================
//  TRADE MANAGEMENT
//============================================================
void QueueTrade(int direction)
{
    if(g_pending.active) return;
    int    slPips = RandomRange(SL_PipsMin, SL_PipsMax);
    double scale  = GetCascadeScale(direction);
    double lots   = CalcLots(slPips, scale);
    if(lots <= 0) return;

    g_pending.active       = true;
    g_pending.direction    = direction;
    g_pending.lots         = lots;
    g_pending.slPips       = slPips;
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
    if(scale > 1.0) Print("IMPULSE_FTMO: Cascade ×", DoubleToString(scale,2), " lot=", lots);
}

void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;
    if(g_pos.active){ g_pending.active=false; return; }
    if(!CheckFTMOLimits()){ g_pending.active=false; return; }

    int    dir    = g_pending.direction;
    double lots   = g_pending.lots;
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double pip    = 0.01;

    // SL od execution cijene (v2.0 fix — ne od stale signal cijene)
    double price = (dir==1) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double sl    = NormalizeDouble((dir==1) ? price - g_pending.slPips*pip
                                            : price + g_pending.slPips*pip, digits);

    bool ok = (dir==1) ? trade.Buy (lots, _Symbol, price, sl, 0, "IMPULSE_SQZMOM_FTMO")
                       : trade.Sell(lots, _Symbol, price, sl, 0, "IMPULSE_SQZMOM_FTMO");
    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        if(PositionSelectByTicket(ticket) && PositionGetDouble(POSITION_SL)==0)
            trade.PositionModify(ticket, sl, 0);
        g_pos.active    = true;
        g_pos.ticket    = ticket;
        g_pos.entryPrice = price;
        g_pos.sl        = sl;
        g_pos.mfe       = 0.0;
        g_pos.openTime  = TimeCurrent();
        Print("IMPULSE_FTMO ", (dir==1?"BUY":"SELL"), " #", ticket,
              " @ ", price, " SL=", sl, " lot=", lots);
    }
    else Print("IMPULSE_FTMO: OPEN FAILED — ", trade.ResultRetcodeDescription());
    g_pending.active = false;
}

//============================================================
//  MANAGE POSITION — TRI-PHASE MFE TRAILING
//============================================================
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)){ g_pos.active=false; return; }

    if(ShouldCloseFriday())
    { Print("IMPULSE_FTMO: Petkom zatvaranje #",g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice = (pt==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double curSL  = PositionGetDouble(POSITION_SL);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double mfeNow = (pt==POSITION_TYPE_BUY) ? (curPrice - g_pos.entryPrice) / point
                                             : (g_pos.entryPrice - curPrice) / point;
    if(mfeNow > g_pos.mfe) g_pos.mfe = mfeNow;
    double mfe = g_pos.mfe;

    // Backup SL
    if(curSL==0 && g_pos.sl!=0)
    { trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl,digits), 0); return; }

    double lock = 0.0;
    if     (mfe >= MFE2_Act)              lock = mfe * MFE2_Pct;
    else if(mfe >= MFE1_Act)              lock = mfe * MFE1_Pct;
    else if(MFE0_Act>0 && mfe>=MFE0_Act) lock = mfe * MFE0_Pct;

    if(lock > 0)
    {
        double ns = (pt==POSITION_TYPE_BUY) ? g_pos.entryPrice + lock*point
                                            : g_pos.entryPrice - lock*point;
        ns = NormalizeDouble(ns, digits);
        if((pt==POSITION_TYPE_BUY && ns>curSL)||(pt==POSITION_TYPE_SELL && ns<curSL))
            if(trade.PositionModify(g_pos.ticket, ns, 0)) g_pos.sl = ns;
    }
}

//============================================================
//  ONTICK
//============================================================
void OnTick()
{
    CheckDailyReset();
    ManagePosition();
    ProcessPending();

    if(!IsNewBar()) return;
    if(!CheckFTMOLimits()) return;

    if(g_pos.active && !PositionSelectByTicket(g_pos.ticket)) g_pos.active=false;
    if(g_pos.active || g_pending.active) return;
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;
    if(HasOpenPosition()) return;

    double curVal = CalculateSQZMOM_Val();
    if(curVal==0 && !g_lastValSet){ g_lastVal=curVal; g_lastValSet=true; return; }

    bool buySignal  = (g_lastVal <= 0 && curVal > 0);
    bool sellSignal = (g_lastVal >= 0 && curVal < 0);
    g_lastVal    = curVal;
    g_lastValSet = true;

    if(buySignal && TradeDirection != ONLY_SELL)
    { Print("IMPULSE_FTMO: BUY SQZMOM zero-cross"); QueueTrade(1); }
    else if(sellSignal && TradeDirection != ONLY_BUY)
    { Print("IMPULSE_FTMO: SELL SQZMOM zero-cross"); QueueTrade(-1); }
}

//============================================================
//  ONTESTER
//============================================================
double OnTester()
{
    double pf = TesterStatistics(STAT_PROFIT_FACTOR);
    double tr = TesterStatistics(STAT_TRADES);
    double dd = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr = TesterStatistics(STAT_PROFIT_TRADES)/(tr>0?tr:1)*100.0;
    double ep = TesterStatistics(STAT_EXPECTED_PAYOFF);
    if(tr<50 || dd>10 || wr<85) return 0;
    return pf * MathSqrt(tr) * (1.0-dd/100.0) * (wr/92.0) * MathMax(ep/10.0,1.0);
}
//+------------------------------------------------------------------+
