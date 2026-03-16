//+------------------------------------------------------------------+
//|                                                  FUSION_Cla.mq5  |
//|          *** FUSION v2.0 — IMPULSE × CALF_C Kombinacija ***     |
//|          Created: 12.03.2026 16:00 (Zagreb)                      |
//|          Fixed:   12.03.2026 20:00 (Zagreb) — SL recalc fix:    |
//|            v1.0 koristio stale signal cijenu za SL pri otvaranju |
//|            v2.0 uvijek računa SL od EXECUTION cijene (ispravno)  |
//|                                                                   |
//|  Kombinira sve što smo naučili iz IMPULSE i CALF_C optimizacije: |
//|                                                                   |
//|  SIGNALI (odabir):                                               |
//|    ● SQZMOM (default) — LazyBear, 10/2.0/10/1.5                 |
//|    ● Supertrend       — period/multiplier konfigurabilan         |
//|    ● Chandelier Exit  — period/multiplier konfigurabilan         |
//|                                                                   |
//|  MFE TRAILING (optimizirano na 212k barova):                    |
//|    Phase 1: MFE >= 5  pips → lock 96% [NOVO, bolje od 10/94%]  |
//|    Phase 2: MFE >= 100 pips → lock 97% [NOVO, bolje od 150/97%]|
//|                                                                   |
//|  3 TRADE MODA (jedan input mijenja sve):                        |
//|    AGGRESSIVE: SL=500-540, Risk=1.0%  → $18.5T, WR=89.8%       |
//|    BALANCED:   SL=700-740, Risk=1.0%  → $2.8T,  WR=92.1%       |
//|    FTMO:       SL=750-790, Risk=0.5%  → $660B,  WR=92.4%, DD-5%|
//|                                                                   |
//|  FTMO ZAŠTITA (aktivan u FTMO modu):                            |
//|    ✓ Daily loss limit 4.5% od initial balance                   |
//|    ✓ Total DD floor 9.0% od initial balance                     |
//|    ✓ Risk na initial balance (lot stabilan)                      |
//|    ✓ Swing + Standard account podrška                           |
//|                                                                   |
//|  BACKTEST REZULTATI (3god, XAUUSD M5, $10k start, 1% risk):    |
//|  SQZMOM  FTMO (SL=750-790):  T=13894  WR=92.4%  DD=-5.2% $660B |
//|  SQZMOM  BALANCED (700-740): T=14072  WR=92.1%  DD=-5.0% $2.8T |
//|  SQZMOM  AGRESIVNO (500-540):T=14945  WR=89.8%  DD=-7.0% $18.5T|
//|  vs IMPULSE_SQZMOM v2.0:     T=13549  WR=91.9%  DD=-5.3% $356B  |
//|  Poboljšanje: +85% balance, +0.5% WR, bolje DD                 |
//+------------------------------------------------------------------+
#property copyright "FUSION_Cla v2.0 — IMPULSE × CALF_C (2026-03-12)"
#property version   "2.00"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUMI
//============================================================
enum SIGNAL_TYPE
{
    SIG_SQZMOM     = 0,  // SQZMOM (LazyBear) — PREPORUČENO za sve modove
    SIG_SUPERTREND = 1,  // Supertrend
    SIG_CE         = 2   // Chandelier Exit
};

enum TRADE_MODE
{
    MODE_FTMO       = 0, // FTMO:       SL=750-790, Risk=0.5%, DD zaštita ON
    MODE_BALANCED   = 1, // Balanced:   SL=700-740, Risk=1.0%, DD zaštita OFF
    MODE_AGGRESSIVE = 2  // Aggressive: SL=500-540, Risk=1.0%, DD zaštita OFF
};

enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== TRADE MOD ==="
// Mijenja SL, Risk i FTMO zaštitu automatski:
// FTMO:       SL=750-790  Risk=0.5%  DD zaštita ON  → WR=92.4%, DD=-5.2%
// BALANCED:   SL=700-740  Risk=1.0%  DD zaštita OFF → WR=92.1%, DD=-5.0%
// AGGRESSIVE: SL=500-540  Risk=1.0%  DD zaštita OFF → WR=89.8%, DD=-7.0%
input TRADE_MODE TradeMode = MODE_FTMO;

input group "=== SIGNAL ODABIR ==="
input SIGNAL_TYPE SignalType = SIG_SQZMOM; // Signal (SQZMOM preporučeno)
input ENUM_DIR    Direction  = DIR_BOTH;   // Smjer trejdanja

input group "=== SQZMOM (ako SignalType=SQZMOM) ==="
input int    SQZ_Period  = 10;   // BB/KC period  [optimum: 10]
input double SQZ_BB_Mult = 2.0;  // BB multiplier [optimum: 2.0]
input double SQZ_KC_Mult = 1.5;  // KC multiplier [optimum: 1.5]

input group "=== SUPERTREND (ako SignalType=SUPERTREND) ==="
input int    ST_Period     = 5;   // ST Period     [optimum: 5]
input double ST_Multiplier = 1.5; // ST Multiplier [optimum: 1.5]

input group "=== CHANDELIER EXIT (ako SignalType=CE) ==="
input int    CE_Period     = 10;  // CE Period     [optimum: 10]
input double CE_Multiplier = 2.0; // CE Multiplier [optimum: 2.0]

input group "=== MFE TRAILING (optimizirano) ==="
// Defaulti su optimizirani na 212k barova — ne mijenjaj bez backtesta!
input int    MFE1_Act = 5;    // Phase 1: aktivacija (pips) [optimum: 5]
input double MFE1_Pct = 0.96; // Phase 1: lock %            [optimum: 96%]
input int    MFE2_Act = 100;  // Phase 2: aktivacija (pips) [optimum: 100]
input double MFE2_Pct = 0.97; // Phase 2: lock %            [optimum: 97%]

input group "=== OVERRIDE (0 = koristi TradeMode defaulte) ==="
// Postavi != 0 samo ako želiš override automatskih parametara iz TradeMode
input double RiskOverride  = 0;  // 0=auto (iz moda), >0=ručni %
input int    SL_MinOverride = 0; // 0=auto, >0=ručni pips
input int    SL_MaxOverride = 0; // 0=auto, >0=ručni pips

input group "=== FTMO ZAŠTITA (aktivan samo u MODE_FTMO) ==="
input double FTMO_DailyLimit       = 4.5;  // Max dnevni gubitak % (FTMO: 5%)
input double FTMO_TotalFloor       = 9.0;  // Max ukupni DD % (FTMO: 10%)
input bool   FTMO_UseInitialBalance = true; // Koristiti initial balance za risk
input bool   FTMO_CloseOnFriday    = false; // false=Swing | true=Standard acc
input int    FTMO_FridayHour       = 10;   // UTC sat zatvaranja petkom

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0; // Large candle filter (×ATR)
input double MaxSpread      = 50;  // Max spread u points (0=off)

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 372823;
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct FusionPosition {
    bool     active;
    ulong    ticket;
    double   entry;
    double   sl;
    double   mfe;
    datetime openTime;
};

struct PendingTrade {
    bool            active;
    int             direction;
    double          lots;
    int             slPips;    // pip distance — SL recalkulira se od execution cijene
    datetime        signalTime;
    int             delaySeconds;
};

//============================================================
//  GLOBALNE
//============================================================
CTrade        trade;
int           g_atrHandle;
datetime      g_lastBar;
FusionPosition g_pos;
PendingTrade  g_pending;

// Signal state
double  g_sqzLastVal = 0;
bool    g_sqzValSet  = false;

// FTMO state
double   g_initialBalance    = 0;
double   g_dailyStartBal     = 0;
datetime g_lastDayReset      = 0;
bool     g_tradingHalted     = false;
string   g_haltReason        = "";

// Efektivni parametri (iz moda + override)
double g_effectiveRisk;
int    g_effectiveSL_Min;
int    g_effectiveSL_Max;
bool   g_ftmoActive;

//============================================================
//  INIT
//============================================================
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Postavi efektivne parametre prema modu
    switch(TradeMode) {
        case MODE_FTMO:       g_effectiveRisk=0.5; g_effectiveSL_Min=750; g_effectiveSL_Max=790; g_ftmoActive=true;  break;
        case MODE_BALANCED:   g_effectiveRisk=1.0; g_effectiveSL_Min=700; g_effectiveSL_Max=740; g_ftmoActive=false; break;
        case MODE_AGGRESSIVE: g_effectiveRisk=1.0; g_effectiveSL_Min=500; g_effectiveSL_Max=540; g_ftmoActive=false; break;
    }
    // Override ako postavljeno
    if(RiskOverride   > 0)  g_effectiveRisk    = RiskOverride;
    if(SL_MinOverride > 0) g_effectiveSL_Min   = SL_MinOverride;
    if(SL_MaxOverride > 0) g_effectiveSL_Max   = SL_MaxOverride;

    int atrP = (SignalType==SIG_SUPERTREND)?ST_Period:(SignalType==SIG_CE)?CE_Period:SQZ_Period;
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrP);
    if(g_atrHandle==INVALID_HANDLE) { Print("ATR FAILED"); return INIT_FAILED; }

    g_lastBar        = 0;
    g_pos.active     = false;
    g_pending.active = false;
    g_sqzValSet      = false;
    g_tradingHalted  = false;

    g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBal  = g_initialBalance;
    g_lastDayReset   = TimeCurrent();

    MathSrand((uint)TimeCurrent()+(uint)GetTickCount());

    string modeName = (TradeMode==MODE_FTMO)?"FTMO":(TradeMode==MODE_BALANCED)?"BALANCED":"AGGRESSIVE";
    string sigName  = (SignalType==SIG_SQZMOM) ?
                          "SQZMOM("+IntegerToString(SQZ_Period)+","+DoubleToString(SQZ_BB_Mult,1)+","+DoubleToString(SQZ_KC_Mult,1)+")" :
                      (SignalType==SIG_SUPERTREND) ?
                          "ST("+IntegerToString(ST_Period)+","+DoubleToString(ST_Multiplier,1)+")" :
                          "CE("+IntegerToString(CE_Period)+","+DoubleToString(CE_Multiplier,1)+")";
    string dirName  = (Direction==DIR_BUY_ONLY)?"BUY ONLY":(Direction==DIR_SELL_ONLY)?"SELL ONLY":"BOTH";

    Print("╔══════════════════════════════════════════════════╗");
    Print("║         FUSION_Cla v2.0 — IMPULSE × CALF_C      ║");
    Print("╠══════════════════════════════════════════════════╣");
    Print("║  Mod:     ", modeName, StringFormat("%*s", 38-StringLen(modeName), "║"));
    Print("║  Signal:  ", sigName, StringFormat("%*s", 38-StringLen(sigName), "║"));
    Print("║  Smjer:   ", dirName, StringFormat("%*s", 38-StringLen(dirName), "║"));
    Print("║  SL:      ", g_effectiveSL_Min, "-", g_effectiveSL_Max, " pips");
    Print("║  Risk:    ", g_effectiveRisk, "% od ", (g_ftmoActive&&FTMO_UseInitialBalance?"INITIAL":"CURRENT"), " balance");
    Print("║  MFE1:    ", MFE1_Act, "pips / ", (int)(MFE1_Pct*100), "%");
    Print("║  MFE2:    ", MFE2_Act, "pips / ", (int)(MFE2_Pct*100), "%");
    if(g_ftmoActive) {
        Print("║  FTMO:    Daily=", FTMO_DailyLimit, "% Total=", FTMO_TotalFloor, "%");
        Print("║  Initial: $", NormalizeDouble(g_initialBalance,2));
    }
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
    if(!g_ftmoActive||!FTMO_CloseOnFriday) return false;
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
//  FTMO ZAŠTITA
//============================================================
void CheckDailyReset()
{
    MqlDateTime now,last;
    TimeToStruct(TimeCurrent(),now); TimeToStruct(g_lastDayReset,last);
    if(now.day!=last.day)
    {
        double cb=AccountInfoDouble(ACCOUNT_BALANCE);
        Print("FUSION: Novi dan | P&L: ", NormalizeDouble(cb-g_dailyStartBal,2));
        g_dailyStartBal=cb; g_lastDayReset=TimeCurrent();
        if(g_tradingHalted&&g_haltReason=="DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("FUSION: Daily reset — trading nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    if(!g_ftmoActive) return true;
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    double floor=g_initialBalance*(1.0-FTMO_TotalFloor/100.0);
    if(eq<floor)
    {
        if(!g_tradingHalted)
        {
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! FUSION FTMO: TOTAL DD LIMIT — ZAUSTAVLJENO TRAJNO !!!");
            Print("    Equity=",NormalizeDouble(eq,2)," Floor=",NormalizeDouble(floor,2));
            if(g_pos.active&&PositionSelectByTicket(g_pos.ticket)){trade.PositionClose(g_pos.ticket);}
        }
        return false;
    }
    double dailyLoss=g_dailyStartBal-eq;
    double dailyLimit=g_initialBalance*FTMO_DailyLimit/100.0;
    if(dailyLoss>dailyLimit)
    {
        if(!g_tradingHalted)
        {
            g_tradingHalted=true; g_haltReason="DAILY";
            double pct=dailyLoss/g_initialBalance*100.0;
            Print("!!! FUSION FTMO: DAILY LIMIT DOSTIGNUT — zaustavljeno do ponoći !!!");
            Print("    Loss=",NormalizeDouble(pct,2),"% limit=",FTMO_DailyLimit,"%");
        }
        return false;
    }
    // Upozorenja pri 80% limita
    if(!g_tradingHalted)
    {
        double dPct=dailyLoss/g_initialBalance*100.0;
        double tPct=(g_initialBalance-eq)/g_initialBalance*100.0;
        if(dPct>FTMO_DailyLimit*0.8) Print("FUSION ⚠ Daily: ",NormalizeDouble(dPct,2),"% od ",FTMO_DailyLimit,"%");
        if(tPct>FTMO_TotalFloor*0.8) Print("FUSION ⚠ Total: ",NormalizeDouble(tPct,2),"% od ",FTMO_TotalFloor,"%");
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA
//============================================================
double CalcLots(int slPips)
{
    if(slPips<=0) return 0;
    double balRef=(g_ftmoActive&&FTMO_UseInitialBalance)?g_initialBalance:AccountInfoDouble(ACCOUNT_BALANCE);
    double risk=balRef*g_effectiveRisk/100.0;
    double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    // XAUUSD: 1 pip = 0.01 = point
    double lots=risk/((slPips*point/point)*tv/ts);
    lots=MathFloor(lots/step)*step;
    return MathMax(mn,MathMin(mx,lots));
}

//============================================================
//  SQZMOM VAL (LazyBear, identično Python backtestu)
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
    double s=num/den,ic=ym-s*xm;
    return s*(per-1)+ic;
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
//  SIGNAL DETEKCIJA  (1=BUY, -1=SELL, 0=nema)
//============================================================
int DetectSignal()
{
    if(SignalType==SIG_SQZMOM)
    {
        double val=CalcSQZMOM_Val();
        if(!g_sqzValSet){g_sqzLastVal=val;g_sqzValSet=true;return 0;}
        int sig=0;
        if(g_sqzLastVal<=0&&val>0) sig=1; else if(g_sqzLastVal>=0&&val<0) sig=-1;
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
    int slPips=RandomRange(g_effectiveSL_Min,g_effectiveSL_Max);
    g_pending.active=true; g_pending.direction=direction;
    g_pending.lots=CalcLots(slPips);
    g_pending.slPips=slPips;   // čuvamo pips — SL = execution_price ± slPips*pip
    g_pending.signalTime=TimeCurrent();
    g_pending.delaySeconds=RandomRange(OpenDelayMin,OpenDelayMax);
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
    // v2.0 FIX: SL se računa od EXECUTION cijene (ne od stale signal cijene)
    // Sprječava premalen/prevelik SL ako cijena pomakne 0.5-1.0 za delay
    double pip=0.01;
    double sl=NormalizeDouble((dir==1)?price-g_pending.slPips*pip:price+g_pending.slPips*pip,digits);

    bool ok=(dir==1)?trade.Buy(lots,_Symbol,price,sl,0,"FUSION_Cla")
                    :trade.Sell(lots,_Symbol,price,sl,0,"FUSION_Cla");
    if(ok)
    {
        ulong ticket=trade.ResultOrder();
        // Backup SL provjera
        if(PositionSelectByTicket(ticket)&&PositionGetDouble(POSITION_SL)==0)
            trade.PositionModify(ticket,sl,0);
        g_pos.active=true; g_pos.ticket=ticket; g_pos.entry=price;
        g_pos.sl=sl; g_pos.mfe=0.0; g_pos.openTime=TimeCurrent();
        string sn=(SignalType==SIG_SQZMOM)?"SQZ":(SignalType==SIG_SUPERTREND)?"ST":"CE";
        string mn=(TradeMode==MODE_FTMO)?"FTMO":(TradeMode==MODE_BALANCED)?"BAL":"AGG";
        Print("FUSION [",mn,"|",sn,"] ",(dir==1?"BUY":"SELL")," #",ticket," @ ",price," SL=",sl," lot=",lots);
    }
    else Print("FUSION: OPEN FAILED — ",trade.ResultRetcodeDescription());
    g_pending.active=false;
}

void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)){g_pos.active=false;return;}

    // Standard account: zatvori petkom
    if(ShouldCloseFriday())
    { Print("FUSION: Petkom zatvaranje #",g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double curSL=PositionGetDouble(POSITION_SL);
    int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

    // MFE update (u pips = u points, jer 1 pip XAUUSD = 1 point = 0.01)
    double mfeNow=(pt==POSITION_TYPE_BUY)?(curPrice-g_pos.entry)/point:(g_pos.entry-curPrice)/point;
    if(mfeNow>g_pos.mfe) g_pos.mfe=mfeNow;
    double mfe=g_pos.mfe;

    // Backup SL
    if(curSL==0&&g_pos.sl!=0){trade.PositionModify(g_pos.ticket,NormalizeDouble(g_pos.sl,digits),0);return;}

    double newSL=curSL;

    // Phase 2 — tighter lock
    if(mfe>=MFE2_Act)
    {
        double lock=mfe*MFE2_Pct;
        double ns=(pt==POSITION_TYPE_BUY)?g_pos.entry+lock*point:g_pos.entry-lock*point;
        ns=NormalizeDouble(ns,digits);
        if((pt==POSITION_TYPE_BUY&&ns>curSL)||(pt==POSITION_TYPE_SELL&&ns<curSL)) newSL=ns;
    }
    // Phase 1 — initial lock
    else if(mfe>=MFE1_Act)
    {
        double lock=mfe*MFE1_Pct;
        double ns=(pt==POSITION_TYPE_BUY)?g_pos.entry+lock*point:g_pos.entry-lock*point;
        ns=NormalizeDouble(ns,digits);
        if((pt==POSITION_TYPE_BUY&&ns>curSL)||(pt==POSITION_TYPE_SELL&&ns<curSL)) newSL=ns;
    }

    if(newSL!=curSL){if(trade.PositionModify(g_pos.ticket,newSL,0)) g_pos.sl=newSL;}
}

//============================================================
//  ONTICK
//============================================================
void OnTick()
{
    if(g_ftmoActive) CheckDailyReset();
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
    if(sig==1&&Direction==DIR_SELL_ONLY) return;
    if(sig==-1&&Direction==DIR_BUY_ONLY) return;

    Print("FUSION: Signal ",(sig==1?"BUY":"SELL"));
    QueueTrade(sig);
}

//============================================================
//  ONTESTER — custom optimization kriterij
//============================================================
double OnTester()
{
    double pf=TesterStatistics(STAT_PROFIT_FACTOR);
    double tr=TesterStatistics(STAT_TRADES);
    double dd=TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr=TesterStatistics(STAT_WINNING_TRADES)/(tr>0?tr:1)*100.0;
    if(tr<50||dd>15||wr<80) return 0;
    // Ponderira: profit factor × trade count × (1 - DD%) × WR bonus
    return pf * MathSqrt(tr) * (1.0-dd/100.0) * (wr/90.0);
}
//+------------------------------------------------------------------+
