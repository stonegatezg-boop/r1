//+------------------------------------------------------------------+
//|                                      FRANKENSTEIN_FTMO_Cla.mq5  |
//|      *** FRANKENSTEIN FTMO v1.1 — Ultimativni Hybrid (FTMO) *** |
//|          Created: 12.03.2026 23:30 (Zagreb)                      |
//|          Upgrade: 12.03.2026 — M15+H1 kaskadno lot skaliranje  |
//|                                                                   |
//|  Dedicirano FTMO verzija FRANKENSTEIN_Cla.mq5 v1.2:             |
//|    ✓ FTMO zaštita UVIJEK aktiva (hardcoded, nije opcija)         |
//|    ✓ Daily loss limit 4.5% od initial balance                    |
//|    ✓ Total DD floor 9.0% od initial balance                      |
//|    ✓ Risk 0.5% od initial balance (stabilan lot)                 |
//|    ✓ SL 750-790 pips (random stealth, FTMO optimum)              |
//|    ✓ Swing + Standard account podrška                            |
//|    ✓ SL od execution cijene (v2.0 fix)                           |
//|                                                                   |
//|  TRI-PHASE MFE (optimizirano 897 kombinacija, +17.3%):          |
//|    Phase 0: MFE >= 2  pips → lock 90% (micro-profit zaštita)   |
//|    Phase 1: MFE >= 4  pips → lock 97%                           |
//|    Phase 2: MFE >= 80 pips → lock 98%                           |
//|                                                                   |
//|  M15+H1 KASKADNO LOT SKALIRANJE (NOVO v1.1):                   |
//|    scale = 1.0 + M15_bonus (ako aligned) + H1_bonus (ako algnd) |
//|    Nikad ne blokira trejd — samo skalira lot veličinu            |
//|    M15+0.5 H1+0.3 → max×1.8 → ~$985M   DD=-6.1% [FTMO SAFE]  |
//|    WR ostaje fiksno 92.2% kroz sve konfiguracije!               |
//|                                                                   |
//|  SIGNALI (odabir):                                               |
//|    ● SQZMOM (default) — LazyBear, 10/2.0/10/1.5                 |
//|    ● Supertrend       — period/multiplier konfigurabilan         |
//|    ● Chandelier Exit  — period/multiplier konfigurabilan         |
//|                                                                   |
//|  BACKTEST (3god, XAUUSD M5, $10k start, 0.5% FTMO risk):       |
//|    FRANKENSTEIN v1.1 (bez cascade): T=14008  WR=92.2%  $61.1M  |
//|    FRANKENSTEIN v1.2 (M15+H1 ×1.8): WR=92.2%  $985M  DD=-6.1%|
//|    Magic: 372826                                                  |
//+------------------------------------------------------------------+
#property copyright "FRANKENSTEIN_FTMO_Cla v1.1 — Ultimativni Hybrid FTMO + Cascade (2026-03-12)"
#property version   "1.10"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUMI
//============================================================
enum SIGNAL_TYPE
{
    SIG_SQZMOM     = 0,  // SQZMOM (LazyBear) — PREPORUČENO
    SIG_SUPERTREND = 1,  // Supertrend
    SIG_CE         = 2   // Chandelier Exit
};

enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== SIGNAL ==="
input SIGNAL_TYPE SignalType = SIG_SQZMOM;
input ENUM_DIR    Direction  = DIR_BOTH;

input group "=== SQZMOM parametri ==="
input int    SQZ_Period  = 10;
input double SQZ_BB_Mult = 2.0;
input double SQZ_KC_Mult = 1.5;

input group "=== SUPERTREND parametri ==="
input int    ST_Period     = 5;
input double ST_Multiplier = 1.5;

input group "=== CHANDELIER EXIT parametri ==="
input int    CE_Period     = 10;
input double CE_Multiplier = 2.0;

input group "=== RISK & SL ==="
input double RiskPercent = 0.5;  // Risk % od initial balance [FTMO: 0.5%]
input int    SL_Min      = 750;  // SL min pips [FTMO optimum: 750]
input int    SL_Max      = 790;  // SL max pips [FTMO optimum: 790]

input group "=== M15+H1 KASKADNO LOT SKALIRANJE (NOVO v1.1) ==="
// Backtest (212k barova): WR uvijek 92.2%, varira samo DD i balance
//   M15+0.5 H1+0.0 → max×1.5 → ~$271M   DD=-5.1%
//   M15+0.5 H1+0.3 → max×1.8 → ~$985M   DD=-6.1%  ← FTMO SAFE (default)
//   M15+0.6 H1+0.3 → max×1.9 → ~$1.3B   DD=-6.3%
//   M15+0.8 H1+0.4 → max×2.2 → ~$3.7B   DD=-6.9%  (rubno FTMO)
input bool   UseM15Scale    = true;  // M15 SQZMOM sloj skaliranja
input double M15_Bonus      = 0.5;  // +bonus kad M15 aligned [FTMO safe: 0.5]
input int    M15_SQZ_Period = 10;   // M15 SQZMOM period
input bool   UseH1Scale     = true;  // H1 SQZMOM sloj (treći sloj)
input double H1_Bonus       = 0.3;  // +bonus kad H1 aligned  [FTMO safe: 0.3]
input int    H1_SQZ_Period  = 10;   // H1 SQZMOM period

input group "=== TRI-PHASE MFE TRAILING (optimizirano 897 kombinacija!) ==="
// Optimizirano backtestom na 212k barova XAUUSD M5 — +17.3% vs FUSION baseline
// NE MIJENJAJ bez backtesta!
input int    MFE0_Act = 0;    // Phase 0: aktivacija (pips) [v2.2: UGAŠENO=0, bio uzrok live problema]
input double MFE0_Pct = 0.90; // Phase 0: lock %            [optimum: 90%]
input int    MFE1_Act = 20;   // Phase 1: aktivacija (pips) [v2.2: 20 pip, bilo 4]
input double MFE1_Pct = 0.85; // Phase 1: lock % [v2.2: 85%, više prostora]
input int    MFE2_Act = 80;   // Phase 2: aktivacija (pips) [optimum: 80]
input double MFE2_Pct = 0.98; // Phase 2: lock %            [optimum: 98%]

input group "=== FTMO ZAŠTITA ==="
input double FTMO_DailyLimit        = 4.5;  // Max dnevni gubitak % od initial (FTMO: 5%)
input double FTMO_TotalFloor        = 9.0;  // Max ukupni DD % od initial (FTMO: 10%)
input bool   FTMO_UseInitialBalance = true; // true=stabilan lot | false=compounding
input bool   FTMO_CloseOnFriday     = false; // false=Swing | true=Standard account
input int    FTMO_FridayHour        = 10;   // UTC sat zatvaranja petkom

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;
input double MaxSpread      = 50;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 372826;
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct FrankenPosition {
    bool     active;
    ulong    ticket;
    double   entry;
    double   sl;
    double   mfe;
    datetime openTime;
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
CTrade          trade;
int             g_atrHandle;
datetime        g_lastBar;
FrankenPosition g_pos;
PendingTrade    g_pending;

double   g_sqzLastVal   = 0;
bool     g_sqzValSet    = false;

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

    int atrP = (SignalType==SIG_SUPERTREND)?ST_Period:(SignalType==SIG_CE)?CE_Period:SQZ_Period;
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrP);
    if(g_atrHandle==INVALID_HANDLE) { Print("ATR FAILED"); return INIT_FAILED; }

    g_lastBar=0; g_pos.active=false; g_pending.active=false;
    g_sqzValSet=false; g_tradingHalted=false;
    g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBal  = g_initialBalance;
    g_lastDayReset   = TimeCurrent();
    MathSrand((uint)TimeCurrent()+(uint)GetTickCount());

    string sigName = (SignalType==SIG_SQZMOM)?"SQZMOM":(SignalType==SIG_SUPERTREND)?"Supertrend":"CE";
    string dirName = (Direction==DIR_BUY_ONLY)?"BUY ONLY":(Direction==DIR_SELL_ONLY)?"SELL ONLY":"BOTH";
    string balType = FTMO_UseInitialBalance?"INITIAL (stabilan lot)":"CURRENT (compounding)";
    double maxScale = 1.0 + (UseM15Scale?M15_Bonus:0.0) + (UseH1Scale?H1_Bonus:0.0);

    Print("╔══════════════════════════════════════════════════╗");
    Print("║  FRANKENSTEIN_FTMO_Cla v1.1 — Hybrid FTMO      ║");
    Print("║           M15+H1 Kaskadno Skaliranje             ║");
    Print("╠══════════════════════════════════════════════════╣");
    Print("║  MOD:     FTMO (zaštita uvijek aktiva)           ║");
    Print("║  Signal:  ", sigName, "  Smjer: ", dirName);
    Print("║  SL:      ", SL_Min, "-", SL_Max, " pips");
    Print("║  Risk:    ", RiskPercent, "% | MaxScale: ×", DoubleToString(maxScale,1));
    Print("║  M15:     ", UseM15Scale?"ON +"+DoubleToString(M15_Bonus,1)+"  (per="+IntegerToString(M15_SQZ_Period)+")":"OFF");
    Print("║  H1:      ", UseH1Scale?"ON +"+DoubleToString(H1_Bonus,1)+"  (per="+IntegerToString(H1_SQZ_Period)+")":"OFF");
    Print("║  MFE0:    ", MFE0_Act, "pips/", (int)(MFE0_Pct*100), "% [micro zaštita]");
    Print("║  MFE1:    ", MFE1_Act, "pips/", (int)(MFE1_Pct*100), "%");
    Print("║  MFE2:    ", MFE2_Act, "pips/", (int)(MFE2_Pct*100), "%");
    Print("║  FTMO:    Daily=", FTMO_DailyLimit, "% Total=", FTMO_TotalFloor, "%");
    Print("║  Initial: $", NormalizeDouble(g_initialBalance, 2));
    Print("║  Magic:   ", MagicNumber);
    Print("╚══════════════════════════════════════════════════╝");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle); }

//============================================================
//  HELPERS
//============================================================
int  RandomRange(int a,int b)   { return (a>=b)?a:a+MathRand()%(b-a+1); }
bool IsNewBar()                 { datetime t=iTime(_Symbol,PERIOD_CURRENT,0); if(t!=g_lastBar){g_lastBar=t;return true;} return false; }

bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    if(dt.day_of_week==6) return false;
    if(dt.day_of_week==0) return (dt.hour>0||dt.min>=1);
    if(dt.day_of_week==5) return (dt.hour<11);
    return true;
}

bool ShouldCloseFriday()
{
    if(!FTMO_CloseOnFriday) return false;
    MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
    return (dt.day_of_week==5&&dt.hour>=FTMO_FridayHour);
}

bool IsSpreadOK()
{
    if(MaxSpread<=0) return true;
    return (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=(int)MaxSpread;
}

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf,true);
    if(CopyBuffer(g_atrHandle,0,1,1,buf)<=0) return 0;
    return buf[0];
}

bool IsLargeCandle()
{
    double atr=GetATR(); if(atr<=0) return false;
    return (iHigh(_Symbol,PERIOD_CURRENT,1)-iLow(_Symbol,PERIOD_CURRENT,1))>LargeCandleATR*atr;
}

bool HasOpenPosition()
{
    for(int i=PositionsTotal()-1;i>=0;i--){
        ulong t=PositionGetTicket(i);
        if(PositionSelectByTicket(t))
            if(PositionGetInteger(POSITION_MAGIC)==MagicNumber&&PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
    }
    return false;
}

//============================================================
//  FTMO ZAŠTITA (uvijek aktiva)
//============================================================
void CheckDailyReset()
{
    MqlDateTime now,last;
    TimeToStruct(TimeCurrent(),now); TimeToStruct(g_lastDayReset,last);
    if(now.day!=last.day)
    {
        double cb=AccountInfoDouble(ACCOUNT_BALANCE);
        Print("FRANKEN_FTMO: Novi dan | P&L: ",NormalizeDouble(cb-g_dailyStartBal,2));
        g_dailyStartBal=cb; g_lastDayReset=TimeCurrent();
        if(g_tradingHalted&&g_haltReason=="DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("FRANKEN_FTMO: Daily reset — trading nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double floor = g_initialBalance*(1.0-FTMO_TotalFloor/100.0);
    if(eq<floor)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! FRANKEN_FTMO: TOTAL DD LIMIT — ZAUSTAVLJENO TRAJNO !!!");
            Print("    Equity=",NormalizeDouble(eq,2)," Floor=",NormalizeDouble(floor,2));
            if(g_pos.active&&PositionSelectByTicket(g_pos.ticket)) trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    double dailyLoss  = g_dailyStartBal-eq;
    double dailyLimit = g_initialBalance*FTMO_DailyLimit/100.0;
    if(dailyLoss>dailyLimit)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="DAILY";
            double pct=dailyLoss/g_initialBalance*100.0;
            Print("!!! FRANKEN_FTMO: DAILY LIMIT — zaustavljeno do ponoći !!!");
            Print("    Loss=",NormalizeDouble(pct,2),"% limit=",FTMO_DailyLimit,"%");
        }
        return false;
    }
    if(!g_tradingHalted){
        double dPct=(g_dailyStartBal-eq)/g_initialBalance*100.0;
        double tPct=(g_initialBalance-eq)/g_initialBalance*100.0;
        if(dPct>FTMO_DailyLimit*0.8)  Print("FRANKEN_FTMO ⚠ Daily: ",NormalizeDouble(dPct,2),"%");
        if(tPct>FTMO_TotalFloor*0.8)  Print("FRANKEN_FTMO ⚠ Total: ",NormalizeDouble(tPct,2),"%");
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA
//============================================================
double CalcLots(int slPips, double scaleMult=1.0)
{
    if(slPips<=0) return 0;
    double balRef = FTMO_UseInitialBalance ? g_initialBalance : AccountInfoDouble(ACCOUNT_BALANCE);
    double risk   = balRef * RiskPercent / 100.0 * scaleMult;
    double point  = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double tv     = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts     = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    double mn     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double mx     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double lots   = risk / ((slPips*point/point)*tv/ts);
    lots = MathFloor(lots/step)*step;
    return MathMax(mn,MathMin(mx,lots));
}

//============================================================
//  SQZMOM KALKULATOR — generički za bilo koji TF (v1.1 NOVO)
//  Koristi se za M15 i H1 kaskadno skaliranje
//============================================================
double CalcSQZMOM_TF(ENUM_TIMEFRAMES tf, int per)
{
    int needed = per * 2 + 5;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl,true); ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
    if(CopyClose(_Symbol,tf,1,needed,cl)<needed) return 0;
    if(CopyHigh (_Symbol,tf,1,needed,hi)<needed) return 0;
    if(CopyLow  (_Symbol,tf,1,needed,lo)<needed) return 0;
    double delta[200];
    for(int j=0;j<per;j++){
        if(j+per>needed) return 0;
        double s=0; for(int k=j;k<j+per;k++) s+=cl[k]; double basis=s/per;
        double hmax=hi[j],lmin=lo[j];
        for(int k=j+1;k<j+per;k++){if(hi[k]>hmax)hmax=hi[k];if(lo[k]<lmin)lmin=lo[k];}
        delta[j]=cl[j]-((hmax+lmin)/2.0+basis)/2.0;
    }
    double xm=(per-1)/2.0,ym=0;
    for(int i=0;i<per;i++) ym+=delta[per-1-i]; ym/=per;
    double num=0,den=0;
    for(int i=0;i<per;i++){double xi=i-xm,yi=delta[per-1-i]-ym;num+=xi*yi;den+=xi*xi;}
    if(den==0) return ym;
    double sc=num/den,ic=ym-sc*xm;
    return sc*(per-1)+ic;
}

//============================================================
//  KASKADNI SCALE FAKTOR (v1.1 NOVO)
//  scale = 1.0 + M15_bonus (ako aligned) + H1_bonus (ako aligned)
//  Nikad ne blokira signal — samo određuje veličinu lota
//============================================================
double GetCascadeScale(int direction)
{
    double scale = 1.0;
    if(UseM15Scale) {
        double sqz_m15 = CalcSQZMOM_TF(PERIOD_M15, M15_SQZ_Period);
        if(sqz_m15 != 0) {
            bool aligned = (direction==1&&sqz_m15>0)||(direction==-1&&sqz_m15<0);
            if(aligned) scale += M15_Bonus;
        }
    }
    if(UseH1Scale) {
        double sqz_h1 = CalcSQZMOM_TF(PERIOD_H1, H1_SQZ_Period);
        if(sqz_h1 != 0) {
            bool aligned = (direction==1&&sqz_h1>0)||(direction==-1&&sqz_h1<0);
            if(aligned) scale += H1_Bonus;
        }
    }
    return scale;
}

//============================================================
//  SQZMOM VAL (LazyBear, bez lookahead biasa)
//============================================================
double CalcSQZMOM_Val()
{
    int per=SQZ_Period, needed=per*2+5;
    double cl[],hi[],lo[];
    ArraySetAsSeries(cl,true); ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
    if(CopyClose(_Symbol,PERIOD_CURRENT,1,needed,cl)<needed) return 0;
    if(CopyHigh (_Symbol,PERIOD_CURRENT,1,needed,hi)<needed) return 0;
    if(CopyLow  (_Symbol,PERIOD_CURRENT,1,needed,lo)<needed) return 0;
    double delta[200];
    for(int j=0;j<per;j++){
        if(j+per>needed) return 0;
        double s=0; for(int k=j;k<j+per;k++) s+=cl[k]; double basis=s/per;
        double hmax=hi[j],lmin=lo[j];
        for(int k=j+1;k<j+per;k++){if(hi[k]>hmax)hmax=hi[k];if(lo[k]<lmin)lmin=lo[k];}
        delta[j]=cl[j]-((hmax+lmin)/2.0+basis)/2.0;
    }
    double xm=(per-1)/2.0,ym=0;
    for(int i=0;i<per;i++) ym+=delta[per-1-i]; ym/=per;
    double num=0,den=0;
    for(int i=0;i<per;i++){double xi=i-xm,yi=delta[per-1-i]-ym;num+=xi*yi;den+=xi*xi;}
    if(den==0) return ym;
    double sc=num/den,ic=ym-sc*xm;
    return sc*(per-1)+ic;
}

//============================================================
//  SUPERTREND direction bar[1], bar[2]
//============================================================
void CalcST(int &d1, int &d2)
{
    int bars=ST_Period+10;
    double hi[],lo[],cl[];
    ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
    CopyHigh(_Symbol,PERIOD_CURRENT,0,bars,hi);
    CopyLow (_Symbol,PERIOD_CURRENT,0,bars,lo);
    CopyClose(_Symbol,PERIOD_CURRENT,0,bars,cl);
    double sumTR=0;
    for(int i=1;i<=ST_Period;i++){double tr=MathMax(hi[i]-lo[i],MathMax(MathAbs(hi[i]-cl[i+1]),MathAbs(lo[i]-cl[i+1]))); sumTR+=tr;}
    double atr=sumTR/ST_Period;
    double stL[6]; int stD[6];
    for(int s=5;s>=0;s--){
        double hl2=(hi[s]+lo[s])/2.0,ub=hl2+ST_Multiplier*atr,lb=hl2-ST_Multiplier*atr;
        double ps=(s<5)?stL[s+1]:hl2; int pd=(s<5)?stD[s+1]:1;
        if(pd==1){if(cl[s]<ps){stL[s]=ub;stD[s]=-1;}else{stL[s]=MathMax(lb,ps);stD[s]=1;}}
        else     {if(cl[s]>ps){stL[s]=lb;stD[s]=1;} else{stL[s]=MathMin(ub,ps);stD[s]=-1;}}
    }
    d1=stD[1]; d2=stD[2];
}

//============================================================
//  CHANDELIER EXIT direction bar[1], bar[2]
//============================================================
void CalcCE(int &d1, int &d2)
{
    int bars=CE_Period*3+5;
    double hi[],lo[],cl[];
    ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
    CopyHigh (_Symbol,PERIOD_CURRENT,0,bars,hi);
    CopyLow  (_Symbol,PERIOD_CURRENT,0,bars,lo);
    CopyClose(_Symbol,PERIOD_CURRENT,0,bars,cl);
    double sumTR=0;
    for(int i=1;i<=CE_Period;i++){double tr=MathMax(hi[i]-lo[i],MathMax(MathAbs(hi[i]-cl[i+1]),MathAbs(lo[i]-cl[i+1]))); sumTR+=tr;}
    double atr=sumTR/CE_Period;
    int dArr[4]; dArr[3]=1;
    for(int s=3;s>=1;s--){
        double hmax=hi[s],lmin=lo[s];
        for(int k=s+1;k<s+CE_Period&&k<bars;k++){if(hi[k]>hmax)hmax=hi[k];if(lo[k]<lmin)lmin=lo[k];}
        double ceLong=hmax-CE_Multiplier*atr,ceShort=lmin+CE_Multiplier*atr;
        int pd=(s<3)?dArr[s+1]:1;
        dArr[s]=(pd==1)?((cl[s]<=ceLong)?-1:1):((cl[s]>=ceShort)?1:-1);
    }
    d1=dArr[1]; d2=dArr[2];
}

//============================================================
//  SIGNAL DETEKCIJA (1=BUY, -1=SELL, 0=nema)
//============================================================
int DetectSignal()
{
    if(SignalType==SIG_SQZMOM)
    {
        double val=CalcSQZMOM_Val();
        if(!g_sqzValSet){g_sqzLastVal=val;g_sqzValSet=true;return 0;}
        int sig=0;
        if(g_sqzLastVal<=0&&val>0)      sig=1;
        else if(g_sqzLastVal>=0&&val<0) sig=-1;
        g_sqzLastVal=val; return sig;
    }
    else if(SignalType==SIG_SUPERTREND)
    { int d1,d2; CalcST(d1,d2); if(d1==1&&d2==-1) return 1; if(d1==-1&&d2==1) return -1; return 0; }
    else
    { int d1,d2; CalcCE(d1,d2); if(d1==1&&d2==-1) return 1; if(d1==-1&&d2==1) return -1; return 0; }
}

//============================================================
//  TRADE MANAGEMENT
//============================================================
void QueueTrade(int direction)
{
    if(g_pending.active) return;
    int slPips=RandomRange(SL_Min,SL_Max);
    double scale=GetCascadeScale(direction);
    g_pending.active=true; g_pending.direction=direction;
    g_pending.lots=CalcLots(slPips,scale);
    g_pending.slPips=slPips;
    g_pending.signalTime=TimeCurrent();
    g_pending.delaySeconds=RandomRange(OpenDelayMin,OpenDelayMax);
    if(scale>1.0) Print("FRANKEN_FTMO: Cascade scale=",DoubleToString(scale,2)," lot=",DoubleToString(g_pending.lots,2));
}

void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent()<g_pending.signalTime+g_pending.delaySeconds) return;
    if(g_pos.active){g_pending.active=false;return;}
    if(!CheckFTMOLimits()){g_pending.active=false;return;}

    int dir=g_pending.direction; double lots=g_pending.lots;
    int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    double price=(dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double pip=0.01;
    double sl=NormalizeDouble((dir==1)?price-g_pending.slPips*pip:price+g_pending.slPips*pip,digits);

    bool ok=(dir==1)?trade.Buy(lots,_Symbol,price,sl,0,"FRANKENSTEIN_FTMO_Cla")
                    :trade.Sell(lots,_Symbol,price,sl,0,"FRANKENSTEIN_FTMO_Cla");
    if(ok)
    {
        ulong ticket=trade.ResultOrder();
        if(PositionSelectByTicket(ticket)&&PositionGetDouble(POSITION_SL)==0)
            trade.PositionModify(ticket,sl,0);
        g_pos.active=true; g_pos.ticket=ticket; g_pos.entry=price;
        g_pos.sl=sl; g_pos.mfe=0.0; g_pos.openTime=TimeCurrent();
        string sn=(SignalType==SIG_SQZMOM)?"SQZ":(SignalType==SIG_SUPERTREND)?"ST":"CE";
        Print("FRANKEN_FTMO [",sn,"] ",(dir==1?"BUY":"SELL")," #",ticket," @ ",price," SL=",sl," lot=",lots);
    }
    else Print("FRANKEN_FTMO: OPEN FAILED — ",trade.ResultRetcodeDescription());
    g_pending.active=false;
}

//============================================================
//  MANAGE POSITION — TRI-PHASE MFE TRAILING
//  Phase 0: MFE >= 2  pips → lock 90% (micro zaštita)
//  Phase 1: MFE >= 4  pips → lock 97%
//  Phase 2: MFE >= 80 pips → lock 98%
//============================================================
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)){g_pos.active=false;return;}

    if(ShouldCloseFriday())
    { Print("FRANKEN_FTMO: Petkom zatvaranje #",g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double curSL=PositionGetDouble(POSITION_SL);
    int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

    double mfeNow=(pt==POSITION_TYPE_BUY)?(curPrice-g_pos.entry)/point:(g_pos.entry-curPrice)/point;
    if(mfeNow>g_pos.mfe) g_pos.mfe=mfeNow;
    double mfe=g_pos.mfe;

    if(curSL==0&&g_pos.sl!=0){trade.PositionModify(g_pos.ticket,NormalizeDouble(g_pos.sl,digits),0);return;}

    double lock=0.0;
    if     (mfe>=MFE2_Act)              lock=mfe*MFE2_Pct;
    else if(mfe>=MFE1_Act)              lock=mfe*MFE1_Pct;
    else if(MFE0_Act>0&&mfe>=MFE0_Act) lock=mfe*MFE0_Pct;

    if(lock>0)
    {
        double ns=(pt==POSITION_TYPE_BUY)?g_pos.entry+lock*point:g_pos.entry-lock*point;
        ns=NormalizeDouble(ns,digits);
        if((pt==POSITION_TYPE_BUY&&ns>curSL)||(pt==POSITION_TYPE_SELL&&ns<curSL))
            if(trade.PositionModify(g_pos.ticket,ns,0)) g_pos.sl=ns;
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

    if(g_pos.active&&!PositionSelectByTicket(g_pos.ticket)) g_pos.active=false;
    if(g_pos.active||g_pending.active) return;
    if(!IsTradingWindow()) return;
    if(!IsSpreadOK()) return;
    if(IsLargeCandle()) return;
    if(HasOpenPosition()) return;

    int sig=DetectSignal();
    if(sig==0) return;
    if(sig==1 &&Direction==DIR_SELL_ONLY) return;
    if(sig==-1&&Direction==DIR_BUY_ONLY)  return;

    Print("FRANKEN_FTMO: Signal ",(sig==1?"BUY":"SELL"));
    QueueTrade(sig);
}

//============================================================
//  ONTESTER — FTMO fokus (strožiji kriterij)
//============================================================
double OnTester()
{
    double pf=TesterStatistics(STAT_PROFIT_FACTOR);
    double tr=TesterStatistics(STAT_TRADES);
    double dd=TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr=TesterStatistics(STAT_PROFIT_TRADES)/(tr>0?tr:1)*100.0;
    double ep=TesterStatistics(STAT_EXPECTED_PAYOFF);
    // FTMO: strožiji DD limit (10%), min WR 85%
    if(tr<50||dd>10||wr<85) return 0;
    return pf * MathSqrt(tr) * (1.0-dd/100.0) * (wr/90.0) * MathMax(ep/10.0,1.0);
}
//+------------------------------------------------------------------+
