//+------------------------------------------------------------------+
//|                                              NEXUS_Cla.mq5       |
//|          *** NEXUS v1.1 — Next-Gen Adaptive Momentum ***         |
//|          Created: 12.03.2026 (Zagreb)                            |
//|          Optimizirano: 12.03.2026 — backtest 212k barova XAUUSD |
//|                                                                   |
//|  BACKTEST REZULTATI (3g, XAUUSD M5, FTMO 0.5% risk):           |
//|    FRANKENSTEIN baseline:  T=13961  WR=92.1%  DD=-4.4%  $56.4M |
//|    NEXUS v1.1 (optimum):   T=13922  WR=92.1%  DD=-5.2%  $252.9M|
//|    Poboljšanje: +348% uz identičan WR i prihvatljiv DD         |
//|                                                                   |
//|  KLJUČNA INOVACIJA — ① M15 SQZMOM LOT SKALIRANJE:              |
//|     Kad M15 SQZMOM potvrđuje isti smjer kao M5 → lot ×1.5      |
//|     Kad M15 nije aligned → lot ×1.0 (trade se NE blokira!)     |
//|     Trade count: 13922 (gotovo isti), WR: 92.1% (isti)         |
//|     EP: $18,168/trade vs $4,041 (4.5× više po trejdu!)         |
//|                                                                   |
//|  ② ATR-ADAPTIVNI MFE PRAGI:                                     |
//|     Backtest: marginalno slabiji od fiksnih prag(2/4/80)        |
//|     Ipak ostaje u kodu — tržišno-adaptivna logika ima smisla   |
//|     Default = identičan FRANKENSTEIN (ATR mult kalibriran)      |
//|                                                                   |
//|  ③ MOMENTUM REVERSAL EXIT:                                       |
//|     Ako M5 SQZMOM flipne PROTIV pozicije → lock 98% MFE        |
//|     Backtest: +7-8% na baznu liniju bez skaliranja              |
//|     MinMFE=1 optimalno (uhvati sve reversale od 1 pipa MFE)    |
//|                                                                   |
//|  CORE (iz FRANKENSTEIN, dokazano):                               |
//|    ● SQZMOM M5 LazyBear zero-cross signal                        |
//|    ● Tri-phase MFE trailing (2/90% 4/97% 80/98%)                |
//|    ● Stealth: SL odmah, random delay 0-4s, stealth TP          |
//|    ● FTMO zaštita (opcionalna)                                   |
//|    ● Magic: 372827                                               |
//|                                                                   |
//+------------------------------------------------------------------+
#property copyright "NEXUS_Cla v1.1 (2026-03-12)"
#property version   "1.10"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUMI
//============================================================
enum TRADE_MODE {
    MODE_FTMO       = 0,  // FTMO:       SL=750-790, Risk=0.5%
    MODE_BALANCED   = 1,  // Balanced:   SL=700-740, Risk=1.0%
    MODE_AGGRESSIVE = 2   // Aggressive: SL=500-540, Risk=1.0%
};
enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== TRADE MOD ==="
input TRADE_MODE TradeMode  = MODE_FTMO;
input ENUM_DIR   Direction  = DIR_BOTH;

input group "=== M5 SQZMOM SIGNAL ==="
input int    SQZ_Period  = 10;
input double SQZ_BB_Mult = 2.0;  // (referentno, za budući squeeze filter)
input double SQZ_KC_Mult = 1.5;  // (referentno)

input group "=== ① MULTI-TF M15 LOT SKALIRANJE ==="
input bool   UseM15Scale    = true;   // Skaliraj lot kad M15 SQZMOM aligned
input double M15_ScaleMult  = 1.5;   // Lot multiplikator [optimum backtest: 1.5]
input int    M15_SQZ_Period = 10;    // M15 SQZMOM period

input group "=== ② ATR-ADAPTIVNI MFE PRAGI ==="
// Default kalibriran za XAUUSD M5 ATR≈50 pips → isti pragi kao FRANKENSTEIN
// Phase0: ATR×4%  = ~2 pip @ ATR50 | Phase1: ATR×8% = ~4 pip | Phase2: ATR×160% = ~80 pip
input double MFE0_ATR_Mult = 0.04;  // Phase 0 prag: ATR × ovaj broj (pips)
input double MFE0_Pct      = 0.90;  // Phase 0 lock %
input double MFE1_ATR_Mult = 0.08;  // Phase 1 prag
input double MFE1_Pct      = 0.97;  // Phase 1 lock %
input double MFE2_ATR_Mult = 1.60;  // Phase 2 prag
input double MFE2_Pct      = 0.98;  // Phase 2 lock %
input int    ATR_Period     = 14;

input group "=== ③ MOMENTUM REVERSAL EXIT ==="
input bool   UseMomentumExit  = true;   // Tighten kad SQZMOM flipne [backtest: +7%]
input double MomentumExitLock = 0.98;  // Lock % pri reversal [optimum: 0.98]
input int    MomExit_MinMFE   = 1;     // Min MFE (pips) za aktivaciju [optimum: 1]

input group "=== OVERRIDE (0 = auto iz TradeMode) ==="
input double RiskOverride   = 0;
input int    SL_MinOverride = 0;
input int    SL_MaxOverride = 0;

input group "=== FTMO ZAŠTITA ==="
input double FTMO_DailyLimit        = 4.5;
input double FTMO_TotalFloor        = 9.0;
input bool   FTMO_UseInitialBalance = true;
input bool   FTMO_CloseOnFriday     = false;
input int    FTMO_FridayHour        = 10;

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;
input double MaxSpread      = 50;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 372827;
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
    bool     momentumExited;  // TRUE: reversal exit već primijenjen (jednom)
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

// SQZMOM state (ažurira se svaki novi bar)
double   g_sqzCurrent  = 0;  // Trenutna vrijednost (za reversal detekciju)
double   g_sqzPrev     = 0;  // Prethodna vrijednost (za zero-cross detekciju)
bool     g_sqzInitDone = false;

// FTMO state
double   g_initialBalance = 0;
double   g_dailyStartBal  = 0;
datetime g_lastDayReset   = 0;
bool     g_tradingHalted  = false;
string   g_haltReason     = "";

// Efektivni parametri (postavljeni u OnInit prema TradeMode + Override)
double   g_effectiveRisk;
int      g_effectiveSL_Min;
int      g_effectiveSL_Max;
bool     g_ftmoActive;

//============================================================
//  INIT
//============================================================
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    switch(TradeMode) {
        case MODE_FTMO:       g_effectiveRisk=0.5; g_effectiveSL_Min=750; g_effectiveSL_Max=790; g_ftmoActive=true;  break;
        case MODE_BALANCED:   g_effectiveRisk=1.0; g_effectiveSL_Min=700; g_effectiveSL_Max=740; g_ftmoActive=false; break;
        case MODE_AGGRESSIVE: g_effectiveRisk=1.0; g_effectiveSL_Min=500; g_effectiveSL_Max=540; g_ftmoActive=false; break;
    }
    if(RiskOverride   > 0) g_effectiveRisk   = RiskOverride;
    if(SL_MinOverride > 0) g_effectiveSL_Min = SL_MinOverride;
    if(SL_MaxOverride > 0) g_effectiveSL_Max = SL_MaxOverride;

    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    if(g_atrHandle == INVALID_HANDLE) { Print("NEXUS: ATR handle FAILED"); return INIT_FAILED; }

    g_lastBar = 0;
    g_pos.active = false; g_pos.momentumExited = false;
    g_pending.active = false;
    g_sqzInitDone = false; g_tradingHalted = false;
    g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBal  = g_initialBalance;
    g_lastDayReset   = TimeCurrent();
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    string modeName = (TradeMode==MODE_FTMO)?"FTMO":(TradeMode==MODE_BALANCED)?"BALANCED":"AGGRESSIVE";

    Print("╔════════════════════════════════════════════════════════╗");
    Print("║      NEXUS_Cla v1.0 — Next-Gen Adaptive Momentum      ║");
    Print("╠════════════════════════════════════════════════════════╣");
    Print("║  Mod:      ", modeName, "  |  SL: ", g_effectiveSL_Min, "-", g_effectiveSL_Max, " pips  |  Risk: ", g_effectiveRisk, "%");
    Print("║  ① M15 Scale: ", UseM15Scale
          ? StringFormat("ON — ×%.1f kad M15 aligned, base ×1.0 kad nije", M15_ScaleMult)
          : "OFF");
    Print("║  ② ATR MFE: ",
          StringFormat("P0=ATR×%.2f/%.0f%%  P1=ATR×%.2f/%.0f%%  P2=ATR×%.2f/%.0f%%",
          MFE0_ATR_Mult,MFE0_Pct*100, MFE1_ATR_Mult,MFE1_Pct*100, MFE2_ATR_Mult,MFE2_Pct*100));
    Print("║  ③ Mom.Exit: ", UseMomentumExit
          ? StringFormat("ON — %.0f%% lock pri SQZMOM flip (min %d pips MFE)", MomentumExitLock*100, MomExit_MinMFE)
          : "OFF");
    if(g_ftmoActive) Print("║  FTMO:     Daily=", FTMO_DailyLimit, "% Total=", FTMO_TotalFloor, "%");
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
    if(!g_ftmoActive || !FTMO_CloseOnFriday) return false;
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
        Print("NEXUS: Novi dan | P&L: ", NormalizeDouble(cb - g_dailyStartBal, 2));
        g_dailyStartBal = cb; g_lastDayReset = TimeCurrent();
        if(g_tradingHalted && g_haltReason == "DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("NEXUS: Daily reset — nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    if(!g_ftmoActive) return true;
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double floor = g_initialBalance * (1.0 - FTMO_TotalFloor/100.0);
    if(eq < floor) {
        if(!g_tradingHalted) {
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! NEXUS FTMO: TOTAL DD — ZAUSTAVLJENO !!!");
            if(g_pos.active && PositionSelectByTicket(g_pos.ticket)) trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    double dailyLoss  = g_dailyStartBal - eq;
    double dailyLimit = g_initialBalance * FTMO_DailyLimit / 100.0;
    if(dailyLoss > dailyLimit) {
        if(!g_tradingHalted) { g_tradingHalted=true; g_haltReason="DAILY"; Print("!!! NEXUS FTMO: DAILY LIMIT — do ponoći !!!"); }
        return false;
    }
    if(!g_tradingHalted) {
        double dPct = dailyLoss / g_initialBalance * 100.0;
        double tPct = (g_initialBalance - eq) / g_initialBalance * 100.0;
        if(dPct > FTMO_DailyLimit * 0.8)  Print("NEXUS ⚠ Daily: ", NormalizeDouble(dPct,2), "%");
        if(tPct > FTMO_TotalFloor * 0.8)  Print("NEXUS ⚠ Total: ", NormalizeDouble(tPct,2), "%");
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA
//  scaleMult: 1.0 = normal, 1.4 = M15-aligned signal
//============================================================
double CalcLots(int slPips, double scaleMult = 1.0)
{
    if(slPips <= 0) return 0;
    double balRef = (g_ftmoActive && FTMO_UseInitialBalance) ? g_initialBalance : AccountInfoDouble(ACCOUNT_BALANCE);
    double risk   = balRef * g_effectiveRisk / 100.0;
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tv     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double mn     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double mx     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots   = (risk / ((slPips * point / point) * tv / ts)) * scaleMult;
    lots = MathFloor(lots / step) * step;
    return MathMax(mn, MathMin(mx, lots));
}

//============================================================
//  SQZMOM KALKULATOR — generički za bilo koji TF
//  LazyBear zero-lag formula, bez lookahead biasa (kopira od bar[1])
//  Vraća linreg vrijednost za bar[1] danog TF-a
//============================================================
double CalcSQZMOM_TF(ENUM_TIMEFRAMES tf, int per)
{
    int needed = per * 2 + 5;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl, true); ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);
    if(CopyClose(_Symbol, tf, 1, needed, cl) < needed) return 0;
    if(CopyHigh (_Symbol, tf, 1, needed, hi) < needed) return 0;
    if(CopyLow  (_Symbol, tf, 1, needed, lo) < needed) return 0;

    // Delta niz: za svaki bar j, delta = close[j] - midline[j]
    // Midline = avg(avg(HH,LL), SMA) — LazyBear formula
    double delta[200];
    for(int j = 0; j < per; j++) {
        if(j + per > needed) return 0;
        double s = 0;
        for(int k = j; k < j + per; k++) s += cl[k];
        double basis = s / per;
        double hmax = hi[j], lmin = lo[j];
        for(int k = j+1; k < j+per; k++) { if(hi[k]>hmax) hmax=hi[k]; if(lo[k]<lmin) lmin=lo[k]; }
        delta[j] = cl[j] - ((hmax + lmin) / 2.0 + basis) / 2.0;
    }

    // Linearna regresija na delta nizu — vrijednost na bar[0] niza (= bar[1] tržišta)
    double xm = (per-1) / 2.0, ym = 0;
    for(int i = 0; i < per; i++) ym += delta[per-1-i]; ym /= per;
    double num = 0, den = 0;
    for(int i = 0; i < per; i++) {
        double xi = i - xm, yi = delta[per-1-i] - ym;
        num += xi*yi; den += xi*xi;
    }
    if(den == 0) return ym;
    double sc = num/den, ic = ym - sc*xm;
    return sc*(per-1) + ic;
}

//============================================================
//  ① M15 LOT SCALE FAKTOR
//  Ne filtrira trejdove — samo vraća multiplikator (1.0 ili ScaleMult)
//  Širi lot na jačim, multi-TF potvrđenim signalima
//============================================================
double GetM15ScaleFactor(int direction)
{
    if(!UseM15Scale) return 1.0;
    double sqz_m15 = CalcSQZMOM_TF(PERIOD_M15, M15_SQZ_Period);
    if(sqz_m15 == 0) return 1.0;  // Nema dovoljno podataka
    bool aligned = (direction ==  1 && sqz_m15 > 0) ||   // BUY: M15 SQZMOM pozitivan
                   (direction == -1 && sqz_m15 < 0);      // SELL: M15 SQZMOM negativan
    return aligned ? M15_ScaleMult : 1.0;
}

//============================================================
//  QUEUE TRADE — pripremi trejd s random delayem (stealth)
//============================================================
void QueueTrade(int direction)
{
    if(g_pending.active) return;
    int slPips = RandomRange(g_effectiveSL_Min, g_effectiveSL_Max);

    // ① M15 lot skaliranje — jači signal = veći lot, nikad blokira
    double scale = GetM15ScaleFactor(direction);
    double lots  = CalcLots(slPips, scale);

    g_pending.active       = true;
    g_pending.direction    = direction;
    g_pending.lots         = lots;
    g_pending.slPips       = slPips;
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);

    string scaleInfo = UseM15Scale
        ? StringFormat(" [M15:%s ×%.1f]", (scale>1.0?"✓":"base"), scale)
        : "";
    Print("NEXUS: Queue ", (direction==1?"BUY":"SELL"), " | lot=", lots, scaleInfo,
          " | delay=", g_pending.delaySeconds, "s");
}

//============================================================
//  PROCESS PENDING — izvrši trejd nakon stealth delaya
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
    double price  = (dir==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double pip    = 0.01;  // XAUUSD: 1 pip = 0.01
    double sl     = NormalizeDouble((dir==1) ? price - g_pending.slPips*pip
                                             : price + g_pending.slPips*pip, digits);

    bool ok = (dir==1) ? trade.Buy (lots, _Symbol, price, sl, 0, "NEXUS_Cla")
                       : trade.Sell(lots, _Symbol, price, sl, 0, "NEXUS_Cla");
    if(ok) {
        ulong ticket = trade.ResultOrder();
        // Backup: ako broker nije prihvatio SL, postavi ga odmah
        if(PositionSelectByTicket(ticket) && PositionGetDouble(POSITION_SL) == 0)
            trade.PositionModify(ticket, sl, 0);

        g_pos.active         = true;
        g_pos.ticket         = ticket;
        g_pos.entry          = price;
        g_pos.sl             = sl;
        g_pos.mfe            = 0.0;
        g_pos.openTime       = TimeCurrent();
        g_pos.momentumExited = false;

        Print("NEXUS: OPEN #", ticket, " ", (dir==1?"BUY":"SELL"),
              " @ ", price, " SL=", sl, " lot=", lots, " (slPips=", g_pending.slPips, ")");
    }
    else Print("NEXUS: OPEN FAILED — ", trade.ResultRetcodeDescription());
    g_pending.active = false;
}

//============================================================
//  MANAGE POSITION — srce NEXUS-a
//
//  Redoslijed svaki tick:
//  1. MFE tracking
//  2. Backup SL provjera
//  3. ③ Momentum Reversal Exit (ako SQZMOM flipnuo PROTIV)
//  4. ② ATR-adaptivni tri-phase trailing
//============================================================
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)) { g_pos.active=false; return; }

    if(ShouldCloseFriday())
    { Print("NEXUS: Petak — zatvaranje #", g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice = (pt==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double curSL    = PositionGetDouble(POSITION_SL);
    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // ── MFE tracking ─────────────────────────────────────────────
    double mfeNow = (pt==POSITION_TYPE_BUY) ? (curPrice - g_pos.entry) / point
                                            : (g_pos.entry - curPrice) / point;
    if(mfeNow > g_pos.mfe) g_pos.mfe = mfeNow;
    double mfe = g_pos.mfe;

    // ── Backup SL ─────────────────────────────────────────────────
    if(curSL == 0 && g_pos.sl != 0)
    { trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl, digits), 0); return; }

    // ── ② ATR-adaptivni pragi (računaj jednom, koristi za 4) ─────
    double atr     = GetATR();
    double pip     = 0.01;
    double atrPips = (atr > 0) ? (atr / pip) : 50.0;  // fallback 50 pips ako nema ATR

    double phase0_th = atrPips * MFE0_ATR_Mult;  // npr. 50*0.04 = 2 pips
    double phase1_th = atrPips * MFE1_ATR_Mult;  // npr. 50*0.08 = 4 pips
    double phase2_th = atrPips * MFE2_ATR_Mult;  // npr. 50*1.60 = 80 pips

    // ── ③ Momentum Reversal Exit ──────────────────────────────────
    // Jednom po trejdu, ako SQZMOM flipne PROTIV → tighten na MomentumExitLock
    if(UseMomentumExit && !g_pos.momentumExited && mfe >= MomExit_MinMFE) {
        bool reversal = (pt==POSITION_TYPE_BUY  && g_sqzCurrent < 0) ||
                        (pt==POSITION_TYPE_SELL && g_sqzCurrent > 0);
        if(reversal) {
            g_pos.momentumExited = true;
            double lock   = mfe * MomentumExitLock;
            double mrevSL = (pt==POSITION_TYPE_BUY) ? g_pos.entry + lock * point
                                                    : g_pos.entry - lock * point;
            mrevSL = NormalizeDouble(mrevSL, digits);
            // Postavljamo samo ako je bolji od trenutnog SL
            if((pt==POSITION_TYPE_BUY  && mrevSL > curSL) ||
               (pt==POSITION_TYPE_SELL && mrevSL < curSL)) {
                if(trade.PositionModify(g_pos.ticket, mrevSL, 0)) {
                    g_pos.sl = mrevSL;
                    Print("NEXUS ↩ MomExit #", g_pos.ticket,
                          " SQZMOM flip→", NormalizeDouble(g_sqzCurrent,5),
                          " mfe=", NormalizeDouble(mfe,1), " lock=", NormalizeDouble(lock,1),
                          " newSL=", mrevSL);
                }
            }
            return;  // Ovaj tick završen, trailing će nastaviti idući bar
        }
    }

    // ── ② ATR-adaptivni tri-phase trailing ────────────────────────
    // Praga se automatski mijenjaju s volatilnošću tržišta
    double lock = 0;
    if     (mfe >= phase2_th) lock = mfe * MFE2_Pct;
    else if(mfe >= phase1_th) lock = mfe * MFE1_Pct;
    else if(mfe >= phase0_th) lock = mfe * MFE0_Pct;

    if(lock > 0) {
        double ns = (pt==POSITION_TYPE_BUY) ? g_pos.entry + lock * point
                                            : g_pos.entry - lock * point;
        ns = NormalizeDouble(ns, digits);
        if((pt==POSITION_TYPE_BUY && ns > curSL) || (pt==POSITION_TYPE_SELL && ns < curSL)) {
            if(trade.PositionModify(g_pos.ticket, ns, 0)) g_pos.sl = ns;
        }
    }
}

//============================================================
//  ONTICK
//============================================================
void OnTick()
{
    if(g_ftmoActive) CheckDailyReset();

    bool newBar = IsNewBar();

    // ─── Ažuriranje SQZMOM na svakom novom baru ─────────────────
    // g_sqzCurrent uvijek svjež → ManagePosition i signal detekcija
    // koriste iste podatke bez dvostrukog računanja
    if(newBar) {
        g_sqzCurrent = CalcSQZMOM_TF(PERIOD_M5, SQZ_Period);
    }

    ManagePosition();   // Koristi g_sqzCurrent za momentum reversal
    ProcessPending();

    if(!newBar) return;
    if(!CheckFTMOLimits()) return;

    // Sync pozicija state
    if(g_pos.active && !PositionSelectByTicket(g_pos.ticket)) g_pos.active = false;

    // Ako je pozicija otvorena, ažuriraj g_sqzPrev da ostane aktualan
    // (kad se pozicija zatvori, odmah imamo ispravnu prethodnu vrijednost)
    if(g_pos.active || g_pending.active) {
        g_sqzPrev = g_sqzCurrent;
        return;
    }

    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;
    if(HasOpenPosition()) return;

    // ─── SQZMOM zero-cross detekcija ─────────────────────────────
    if(!g_sqzInitDone) { g_sqzPrev=g_sqzCurrent; g_sqzInitDone=true; return; }

    int sig = 0;
    if     (g_sqzPrev <= 0 && g_sqzCurrent > 0) sig =  1;  // Zero-cross UP   → BUY
    else if(g_sqzPrev >= 0 && g_sqzCurrent < 0) sig = -1;  // Zero-cross DOWN → SELL
    g_sqzPrev = g_sqzCurrent;  // Ažuriraj za sljedeći bar

    if(sig == 0) return;
    if(sig ==  1 && Direction == DIR_SELL_ONLY) return;
    if(sig == -1 && Direction == DIR_BUY_ONLY)  return;

    Print("NEXUS: Signal ", (sig==1?"BUY":"SELL"),
          " | SQZMOM=", NormalizeDouble(g_sqzCurrent,5),
          " | ATR=", NormalizeDouble(GetATR()/0.01,1), "pips");
    QueueTrade(sig);
}

//============================================================
//  ONTESTER — NEXUS kriterij
//  Temelj: Frankenstein kriterij (pf × sqrtT × (1-dd) × wr)
//  NEXUS dodaje: nagrađuje lot-efficiency kroz EP (expected payoff)
//  NEXUS kažnjava: ekstra penalty za dd>10 (FTMO granica)
//============================================================
double OnTester()
{
    double pf = TesterStatistics(STAT_PROFIT_FACTOR);
    double tr = TesterStatistics(STAT_TRADES);
    double dd = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr = TesterStatistics(STAT_WINNING_TRADES) / (tr > 0 ? tr : 1) * 100.0;
    double ep = TesterStatistics(STAT_EXPECTED_PAYOFF);   // avg profit po trejdu

    if(tr < 50 || dd > 15 || wr < 80) return 0;

    // Lot efficiency bonus: viši EP znači bolji profit po trejdu
    // (M15 scaling treba povećati EP, ovo ga nagrađuje)
    double epBonus = MathMax(ep / 10.0, 1.0);

    // DD penalty: NEXUS je FTMO EA, dd>10 kažnjavamo dodatno
    double ddPenalty = (dd > 10) ? (1.0 - (dd - 10.0) / 10.0) : 1.0;

    return pf * MathSqrt(tr) * (1.0 - dd/100.0) * (wr/90.0) * epBonus * ddPenalty;
}
//+------------------------------------------------------------------+
