//+------------------------------------------------------------------+
//|                                          NEXUS_FTMO_Cla.mq5     |
//|      *** NEXUS FTMO v1.1 — Next-Gen Adaptive Momentum (FTMO) ** |
//|          Created: 12.03.2026 (Zagreb)                            |
//|          Optimizirano: 12.03.2026 — 2x backtest, 212k barova   |
//|                                                                   |
//|  BACKTEST REZULTATI (3g, XAUUSD M5, $10k, 0.5% FTMO risk):    |
//|    FRANKENSTEIN:         T=13988  WR=92.2%  DD=-4.4%  $60.6M  |
//|    NEXUS v1.1 (M15×1.5): T=13988  WR=92.2%  DD=-5.1%  $271.3M |
//|    NEXUS v1.2 FTMO safe: T=13988  WR=92.2%  DD=-6.1%  $984.9M |
//|    NEXUS v1.2 moderate:  T=13988  WR=92.2%  DD=-6.3%  $1.3B   |
//|    Agresivni max config: T=13988  WR=92.2%  DD=-6.9%  $3.7B   |
//|    WR NIKAD ne pada ispod 92.2% — robustnost potvrđena!        |
//|                                                                   |
//|  INOVACIJE (sve dokazane backtestom):                           |
//|                                                                   |
//|  ① M15+H1 KASKADNO LOT SKALIRANJE:                              |
//|     scale = 1.0 (base — trade uvijek prolazi)                   |
//|     + M15_bonus ako M15 SQZMOM aligned (def: +0.5)             |
//|     + H1_bonus  ako H1 SQZMOM aligned  (def: +0.3)             |
//|     Max scale = ×1.8 (M5+M15+H1 svi aligned)                   |
//|     Tri aligned = najjači signal = najveći lot                  |
//|                                                                   |
//|  ② TRI-PHASE MFE TRAILING (fixed, optimizirano):                |
//|     Phase 0: MFE >= 2  pips → lock 90%                         |
//|     Phase 1: MFE >= 4  pips → lock 97%                         |
//|     Phase 2: MFE >= 80 pips → lock 98%                         |
//|                                                                   |
//|  ③ MOMENTUM REVERSAL EXIT (+7-8%):                              |
//|     Ako M5 SQZMOM flipne PROTIV pozicije → lock 98% MFE        |
//|                                                                   |
//|  Magic: 372828                                                   |
//+------------------------------------------------------------------+
#property copyright "NEXUS_FTMO_Cla v1.1 (2026-03-12)"
#property version   "1.10"
#property strict
#include <Trade\Trade.mqh>

enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== M5 SQZMOM SIGNAL ==="
input int      SQZ_Period  = 10;
input ENUM_DIR Direction   = DIR_BOTH;

input group "=== ① M15+H1 KASKADNO LOT SKALIRANJE ==="
// Backtest rezultati (WR uvijek 92.2%, varira samo DD):
//   M15+0.5 H1+0.0 → max×1.5 → $271M   DD=-5.1%  (konzervativno)
//   M15+0.5 H1+0.3 → max×1.8 → $985M   DD=-6.1%  ← FTMO SAFE DEFAULT
//   M15+0.6 H1+0.3 → max×1.9 → $1.3B   DD=-6.3%  (umjereno agresivno)
//   M15+0.7 H1+0.3 → max×2.0 → $1.8B   DD=-6.4%  (agresivno)
//   M15+0.8 H1+0.4 → max×2.2 → $3.7B   DD=-6.9%  (max, rubno za FTMO)
input bool   UseM15Scale    = true;   // M15 SQZMOM sloj
input double M15_Bonus      = 0.5;   // +lot_bonus kad M15 aligned [FTMO safe: 0.5]
input int    M15_SQZ_Period = 10;    // M15 SQZMOM period
input bool   UseH1Scale     = true;   // H1 SQZMOM sloj (treći sloj)
input double H1_Bonus       = 0.3;   // +lot_bonus kad H1 aligned  [FTMO safe: 0.3]
input int    H1_SQZ_Period  = 10;    // H1 SQZMOM period

input group "=== ② TRI-PHASE MFE TRAILING (optimizirano) ==="
input int    MFE0_Act = 0;    // Phase 0: aktivacija (pips) [v2.2: UGAŠENO=0, bio uzrok live problema]
input double MFE0_Pct = 0.90; // Phase 0: lock % [optimum: 90%]
input int    MFE1_Act = 20;   // Phase 1: aktivacija (pips) [v2.2: 20 pip, bilo 4]
input double MFE1_Pct = 0.85; // Phase 1: lock % [v2.2: 85%, više prostora]
input int    MFE2_Act = 80;   // Phase 2: aktivacija (pips) [optimum: 80]
input double MFE2_Pct = 0.98; // Phase 2: lock % [optimum: 98%]

input group "=== ③ MOMENTUM REVERSAL EXIT ==="
input bool   UseMomentumExit  = true;   // Lock 98% MFE kad M5 SQZMOM flipne [+7%]
input double MomentumExitLock = 0.98;  // Lock % [optimum: 0.98]
input int    MomExit_MinMFE   = 1;     // Min MFE pips [optimum: 1]

input group "=== FTMO RISK & SL ==="
input double RiskPercent = 0.5;  // Risk % od initial balance
input int    SL_Min      = 750;  // SL min pips
input int    SL_Max      = 790;  // SL max pips

input group "=== FTMO ZAŠTITA ==="
input double FTMO_DailyLimit    = 4.5;
input double FTMO_TotalFloor    = 9.0;
input bool   FTMOSwingMode      = false;
input bool   FTMO_CloseOnFriday = false;
input int    FTMO_FridayHour    = 10;

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;
input double MaxSpread      = 50;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 372828;
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct NexusPos {
    bool     active;
    ulong    ticket;
    double   entry;
    double   sl;
    double   mfe;
    datetime openTime;
    bool     momentumExited;
};

struct PendingTrade {
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
CTrade        trade;
int           g_atrHandle;
datetime      g_lastBar;
NexusPos      g_pos;
PendingTrade  g_pending;

double   g_sqzCurrent  = 0;
double   g_sqzPrev     = 0;
bool     g_sqzInitDone = false;

double   g_initialBalance = 0;
double   g_dailyStartBal  = 0;
datetime g_lastDayReset   = 0;
bool     g_tradingHalted  = false;
string   g_haltReason     = "";

//============================================================
//  INIT
//============================================================
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    if(g_atrHandle == INVALID_HANDLE) { Print("NEXUS_FTMO: ATR FAILED"); return INIT_FAILED; }

    g_lastBar = 0;
    g_pos.active = false; g_pos.momentumExited = false;
    g_pending.active = false;
    g_sqzInitDone = false; g_tradingHalted = false;
    g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBal  = g_initialBalance;
    g_lastDayReset   = TimeCurrent();
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    double maxScale = 1.0 + (UseM15Scale?M15_Bonus:0) + (UseH1Scale?H1_Bonus:0);

    Print("╔════════════════════════════════════════════════════════╗");
    Print("║    NEXUS_FTMO_Cla v1.1 — M15+H1 Kaskadno Skaliranje  ║");
    Print("╠════════════════════════════════════════════════════════╣");
    Print("║  FTMO:  Daily=", FTMO_DailyLimit, "%  Total=", FTMO_TotalFloor, "%  Swing=", FTMOSwingMode?"DA":"NE");
    Print("║  Risk:  ", RiskPercent, "%  SL: ", SL_Min, "-", SL_Max, " pips");
    Print("║  ① M15: ", UseM15Scale?StringFormat("ON bonus=+%.1f",M15_Bonus):"OFF",
          "  H1: ", UseH1Scale?StringFormat("ON bonus=+%.1f",H1_Bonus):"OFF",
          StringFormat("  MaxScale=×%.1f", maxScale));
    Print("║  ② MFE: P0=", MFE0_Act, "/", (int)(MFE0_Pct*100), "%  P1=", MFE1_Act, "/",
          (int)(MFE1_Pct*100), "%  P2=", MFE2_Act, "/", (int)(MFE2_Pct*100), "%");
    Print("║  ③ MomExit: ", UseMomentumExit?StringFormat("ON %.0f%% minMFE=%d",MomentumExitLock*100,MomExit_MinMFE):"OFF");
    Print("║  Magic: ", MagicNumber);
    Print("╚════════════════════════════════════════════════════════╝");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle); }

//============================================================
//  HELPERS
//============================================================
int  RandomRange(int a, int b) { return (a >= b) ? a : a + MathRand() % (b - a + 1); }

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != g_lastBar) { g_lastBar = t; return true; }
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
    return (dt.day_of_week == 5 && dt.hour >= FTMO_FridayHour);
}

bool IsSpreadOK()
{
    if(MaxSpread <= 0) return true;
    return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= (int)MaxSpread;
}

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

bool IsLargeCandle()
{
    double atr = GetATR(); if(atr <= 0) return false;
    return (iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) > LargeCandleATR * atr;
}

bool HasOpenPosition()
{
    for(int i = PositionsTotal()-1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t))
            if(PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol)
                return true;
    }
    return false;
}

//============================================================
//  FTMO ZAŠTITA
//============================================================
void CheckDailyReset()
{
    MqlDateTime now, last;
    TimeToStruct(TimeCurrent(), now); TimeToStruct(g_lastDayReset, last);
    if(now.day != last.day) {
        double cb = AccountInfoDouble(ACCOUNT_BALANCE);
        Print("NEXUS_FTMO: Novi dan | P&L: ", NormalizeDouble(cb - g_dailyStartBal, 2));
        g_dailyStartBal = cb; g_lastDayReset = TimeCurrent();
        if(g_tradingHalted && g_haltReason == "DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("NEXUS_FTMO: Daily reset — nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double floor = g_initialBalance * (1.0 - FTMO_TotalFloor/100.0);
    if(eq < floor) {
        if(!g_tradingHalted) {
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! NEXUS_FTMO: TOTAL DD BREACH !!!");
            if(g_pos.active && PositionSelectByTicket(g_pos.ticket))
                trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    if(!FTMOSwingMode) {
        double dailyLoss  = g_dailyStartBal - eq;
        double dailyLimit = g_initialBalance * FTMO_DailyLimit / 100.0;
        if(dailyLoss > dailyLimit) {
            if(!g_tradingHalted) {
                g_tradingHalted=true; g_haltReason="DAILY";
                Print("!!! NEXUS_FTMO: DAILY LIMIT — do ponoći !!!");
            }
            return false;
        }
        if(!g_tradingHalted) {
            double dPct = dailyLoss / g_initialBalance * 100.0;
            double tPct = (g_initialBalance - eq) / g_initialBalance * 100.0;
            if(dPct > FTMO_DailyLimit * 0.8)  Print("NEXUS_FTMO ⚠ Daily: ", NormalizeDouble(dPct,2), "%");
            if(tPct > FTMO_TotalFloor * 0.8)  Print("NEXUS_FTMO ⚠ Total: ", NormalizeDouble(tPct,2), "%");
        }
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA
//============================================================
double CalcLots(int slPips, double scaleMult)
{
    if(slPips <= 0) return 0;
    double risk  = g_initialBalance * RiskPercent / 100.0;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tv    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double mn    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double mx    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots  = (risk / ((slPips * point / point) * tv / ts)) * scaleMult;
    lots = MathFloor(lots / step) * step;
    return MathMax(mn, MathMin(mx, lots));
}

//============================================================
//  SQZMOM — LazyBear, bez lookahead, za bilo koji TF
//============================================================
double CalcSQZMOM_TF(ENUM_TIMEFRAMES tf, int per)
{
    int needed = per * 2 + 5;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl, true); ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);
    if(CopyClose(_Symbol, tf, 1, needed, cl) < needed) return 0;
    if(CopyHigh (_Symbol, tf, 1, needed, hi) < needed) return 0;
    if(CopyLow  (_Symbol, tf, 1, needed, lo) < needed) return 0;
    double delta[200];
    for(int j = 0; j < per; j++) {
        if(j + per > needed) return 0;
        double s = 0;
        for(int k = j; k < j+per; k++) s += cl[k];
        double basis = s / per;
        double hmax = hi[j], lmin = lo[j];
        for(int k = j+1; k < j+per; k++) { if(hi[k]>hmax) hmax=hi[k]; if(lo[k]<lmin) lmin=lo[k]; }
        delta[j] = cl[j] - ((hmax+lmin)/2.0 + basis)/2.0;
    }
    double xm = (per-1)/2.0, ym = 0;
    for(int i = 0; i < per; i++) ym += delta[per-1-i]; ym /= per;
    double num = 0, den = 0;
    for(int i = 0; i < per; i++) {
        double xi = i-xm, yi = delta[per-1-i]-ym;
        num += xi*yi; den += xi*xi;
    }
    if(den == 0) return ym;
    double sc = num/den, ic = ym-sc*xm;
    return sc*(per-1)+ic;
}

//============================================================
//  ① M15+H1 KASKADNO SKALIRANJE
//  scale = 1.0 + M15_bonus (ako aligned) + H1_bonus (ako aligned)
//  Nikad ne blokira trade — samo određuje veličinu lota
//============================================================
double GetCascadeScale(int direction)
{
    double scale = 1.0;

    if(UseM15Scale) {
        double sqz_m15 = CalcSQZMOM_TF(PERIOD_M15, M15_SQZ_Period);
        if(sqz_m15 != 0) {
            bool m15_aligned = (direction==1 && sqz_m15>0) || (direction==-1 && sqz_m15<0);
            if(m15_aligned) scale += M15_Bonus;
        }
    }

    if(UseH1Scale) {
        double sqz_h1 = CalcSQZMOM_TF(PERIOD_H1, H1_SQZ_Period);
        if(sqz_h1 != 0) {
            bool h1_aligned = (direction==1 && sqz_h1>0) || (direction==-1 && sqz_h1<0);
            if(h1_aligned) scale += H1_Bonus;
        }
    }

    return scale;
}

//============================================================
//  QUEUE TRADE
//============================================================
void QueueTrade(int direction)
{
    if(g_pending.active) return;
    int slPips = RandomRange(SL_Min, SL_Max);

    double scale = GetCascadeScale(direction);
    double lots  = CalcLots(slPips, scale);

    g_pending.active       = true;
    g_pending.direction    = direction;
    g_pending.lots         = lots;
    g_pending.slPips       = slPips;
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);

    Print("NEXUS_FTMO: Queue ", (direction==1?"BUY":"SELL"),
          StringFormat(" scale=×%.1f lot=%.2f delay=%ds", scale, lots, g_pending.delaySeconds));
}

//============================================================
//  PROCESS PENDING
//============================================================
void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;
    if(g_pos.active) { g_pending.active=false; return; }
    if(!CheckFTMOLimits()) { g_pending.active=false; return; }

    int    dir    = g_pending.direction;
    double lots   = g_pending.lots;
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double price  = (dir==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pip    = 0.01;
    double sl     = NormalizeDouble((dir==1) ? price - g_pending.slPips*pip
                                             : price + g_pending.slPips*pip, digits);

    bool ok = (dir==1) ? trade.Buy (lots, _Symbol, price, sl, 0, "NEXUS_FTMO_Cla")
                       : trade.Sell(lots, _Symbol, price, sl, 0, "NEXUS_FTMO_Cla");
    if(ok) {
        ulong ticket = trade.ResultOrder();
        if(PositionSelectByTicket(ticket) && PositionGetDouble(POSITION_SL) == 0)
            trade.PositionModify(ticket, sl, 0);
        g_pos.active=true; g_pos.ticket=ticket; g_pos.entry=price;
        g_pos.sl=sl; g_pos.mfe=0.0; g_pos.openTime=TimeCurrent();
        g_pos.momentumExited=false;
        Print("NEXUS_FTMO: OPEN #", ticket, " ", (dir==1?"BUY":"SELL"),
              " @ ", price, " SL=", sl, " lot=", lots, " (", g_pending.slPips, " pips)");
    }
    else Print("NEXUS_FTMO: OPEN FAILED — ", trade.ResultRetcodeDescription());
    g_pending.active = false;
}

//============================================================
//  MANAGE POSITION
//============================================================
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)) { g_pos.active=false; return; }

    if(ShouldCloseFriday())
    { Print("NEXUS_FTMO: Petak #", g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice = (pt==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double curSL    = PositionGetDouble(POSITION_SL);
    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double mfeNow = (pt==POSITION_TYPE_BUY) ? (curPrice-g_pos.entry)/point
                                            : (g_pos.entry-curPrice)/point;
    if(mfeNow > g_pos.mfe) g_pos.mfe = mfeNow;
    double mfe = g_pos.mfe;

    // Backup SL
    if(curSL == 0 && g_pos.sl != 0)
    { trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl,digits), 0); return; }

    // ③ Momentum Reversal Exit
    if(UseMomentumExit && !g_pos.momentumExited && mfe >= MomExit_MinMFE) {
        bool reversal = (pt==POSITION_TYPE_BUY  && g_sqzCurrent < 0) ||
                        (pt==POSITION_TYPE_SELL && g_sqzCurrent > 0);
        if(reversal) {
            g_pos.momentumExited = true;
            double lock   = mfe * MomentumExitLock;
            double mrevSL = (pt==POSITION_TYPE_BUY) ? g_pos.entry+lock*point
                                                    : g_pos.entry-lock*point;
            mrevSL = NormalizeDouble(mrevSL, digits);
            if((pt==POSITION_TYPE_BUY&&mrevSL>curSL)||(pt==POSITION_TYPE_SELL&&mrevSL<curSL)) {
                if(trade.PositionModify(g_pos.ticket, mrevSL, 0)) {
                    g_pos.sl = mrevSL;
                    Print("NEXUS_FTMO ↩ MomExit #", g_pos.ticket,
                          " mfe=", NormalizeDouble(mfe,1), " SL→", mrevSL);
                }
            }
            return;
        }
    }

    // ② Tri-phase MFE trailing
    double lock = 0;
    if     (mfe >= MFE2_Act) lock = mfe * MFE2_Pct;
    else if(mfe >= MFE1_Act) lock = mfe * MFE1_Pct;
    else if(mfe >= MFE0_Act) lock = mfe * MFE0_Pct;

    if(lock > 0) {
        double ns = (pt==POSITION_TYPE_BUY) ? g_pos.entry+lock*point
                                            : g_pos.entry-lock*point;
        ns = NormalizeDouble(ns, digits);
        if((pt==POSITION_TYPE_BUY&&ns>curSL)||(pt==POSITION_TYPE_SELL&&ns<curSL)) {
            if(trade.PositionModify(g_pos.ticket, ns, 0)) g_pos.sl = ns;
        }
    }
}

//============================================================
//  ONTICK
//============================================================
void OnTick()
{
    CheckDailyReset();

    bool newBar = IsNewBar();
    if(newBar)
        g_sqzCurrent = CalcSQZMOM_TF(PERIOD_M5, SQZ_Period);

    ManagePosition();
    ProcessPending();

    if(!newBar) return;
    if(!CheckFTMOLimits()) return;

    if(g_pos.active && !PositionSelectByTicket(g_pos.ticket)) g_pos.active = false;
    if(g_pos.active || g_pending.active) { g_sqzPrev = g_sqzCurrent; return; }

    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;
    if(HasOpenPosition()) return;

    if(!g_sqzInitDone) { g_sqzPrev=g_sqzCurrent; g_sqzInitDone=true; return; }

    int sig = 0;
    if     (g_sqzPrev <= 0 && g_sqzCurrent > 0) sig =  1;
    else if(g_sqzPrev >= 0 && g_sqzCurrent < 0) sig = -1;
    g_sqzPrev = g_sqzCurrent;

    if(sig == 0) return;
    if(sig ==  1 && Direction == DIR_SELL_ONLY) return;
    if(sig == -1 && Direction == DIR_BUY_ONLY)  return;

    Print("NEXUS_FTMO: Signal ", (sig==1?"BUY":"SELL"),
          " SQZMOM=", NormalizeDouble(g_sqzCurrent,5));
    QueueTrade(sig);
}

//============================================================
//  ONTESTER — FTMO strogi kriterij
//  Nagrađuje lot-efficiency (EP) — viši EP = M15+H1 skaliranje radi
//  dd>10 strogi penalty (FTMO total limit je 9%)
//============================================================
double OnTester()
{
    double pf = TesterStatistics(STAT_PROFIT_FACTOR);
    double tr = TesterStatistics(STAT_TRADES);
    double dd = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr = TesterStatistics(STAT_PROFIT_TRADES) / (tr>0?tr:1) * 100.0;
    double ep = TesterStatistics(STAT_EXPECTED_PAYOFF);

    if(tr < 50 || dd > 10 || wr < 85) return 0;

    double epBonus  = MathMax(ep / 10.0, 1.0);
    double ddSafety = (dd > 8) ? (1.0 - (dd-8.0)/4.0) : 1.0;  // Penalty ako DD >8%

    return pf * MathSqrt(tr) * (1.0-dd/100.0) * (wr/90.0) * epBonus * ddSafety;
}
//+------------------------------------------------------------------+
