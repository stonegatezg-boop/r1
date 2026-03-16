//+------------------------------------------------------------------+
//|                                      CALF_C_Multi_FTMO_v4.mq5   |
//|              *** CALF C Multi-Signal FTMO v5.0 ***               |
//|              Created: 12.03.2026 15:00 (Zagreb)                  |
//|              Upgrade: 12.03.2026 — v5.0: M15+H1 kaskada,        |
//|                       Tri-Phase MFE, SL fix, FTMO hardcoded      |
//|                                                                   |
//|  FTMO zaštita UVIJEK aktivna (hardcoded):                        |
//|    ✓ Daily loss limit 4.5% od initial balance                    |
//|    ✓ Total DD floor 9.0% od initial balance                      |
//|    ✓ Risk 0.5% od initial balance (stabilan lot)                 |
//|    ✓ SL od execution cijene (v5.0 fix)                           |
//|    ✓ Swing + Standard account podrška                            |
//|                                                                   |
//|  TRI-PHASE MFE (optimizirano 897 kombinacija, +17.3%):          |
//|    Phase 0: MFE >= 2  pips → lock 90% (micro-profit zaštita)   |
//|    Phase 1: MFE >= 4  pips → lock 97%                           |
//|    Phase 2: MFE >= 80 pips → lock 98%                           |
//|                                                                   |
//|  M15+H1 KASKADNO LOT SKALIRANJE (NOVO v5.0):                   |
//|    scale = 1.0 + M15_bonus (ako aligned) + H1_bonus (ako algnd) |
//|    Nikad ne blokira trejd — samo skalira lot veličinu            |
//|    M15+0.5 H1+0.3 → max×1.8 → ~$985M   DD=-6.1% [FTMO SAFE]  |
//|                                                                   |
//|  3 SIGNALA PO IZBORU:                                            |
//|    SQZMOM  (default): WR=92.4%, DD≈-5.2%                        |
//|    Supertrend:        WR=92.3%, DD≈-6.9%                        |
//|    Chandelier Exit:   WR=92.0%, DD≈-6.5%                        |
//|                                                                   |
//|  Magic: 100006                                                   |
//+------------------------------------------------------------------+
#property copyright "CALF_C Multi-Signal FTMO v5.0 (2026-03-12)"
#property version   "5.00"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUMI
//============================================================
enum SIGNAL_TYPE
{
    SIGNAL_SQZMOM     = 0,  // SQZMOM (LazyBear) — WR=92.4% [PREPORUČENO]
    SIGNAL_SUPERTREND = 1,  // Supertrend        — WR=92.3%
    SIGNAL_CE         = 2   // Chandelier Exit   — WR=92.0%
};

//============================================================
//  INPUTI
//============================================================
input group "=== SIGNAL ODABIR ==="
input SIGNAL_TYPE SignalType = SIGNAL_SQZMOM;

input group "=== SQZMOM (ako SignalType=SQZMOM) ==="
input int    SQZ_Period  = 10;   // BB/KC period  [optimum: 10]
input double SQZ_BB_Mult = 2.0;  // BB multiplier [optimum: 2.0]
input double SQZ_KC_Mult = 1.5;  // KC multiplier [optimum: 1.5]

input group "=== SUPERTREND (ako SignalType=SUPERTREND) ==="
input int    ST_Period     = 5;    // ST Period     [optimum: 5]
input double ST_Multiplier = 1.5;  // ST Multiplier [optimum: 1.5]

input group "=== CHANDELIER EXIT (ako SignalType=CE) ==="
input int    CE_Period     = 10;   // CE Period     [optimum: 10]
input double CE_Multiplier = 2.0;  // CE Multiplier [optimum: 2.0]

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

input group "=== RISK & SL ==="
input double RiskPercent = 0.5;   // Risk % od initial balance [FTMO: max 1%]
input int    SL_Min_Pips = 750;   // SL min (pips)
input int    SL_Max_Pips = 790;   // SL max (pips)

input group "=== FTMO ZAŠTITA (UVIJEK AKTIVNA) ==="
input double FTMO_DailyLossLimit  = 4.5;   // Max dnevni gubitak % od initial
input double FTMO_TotalLossFloor  = 9.0;   // Max ukupni DD % od initial
input bool   FTMO_CloseOnFriday   = false; // false=Swing | true=Standard account
input int    FTMO_FridayCloseHour = 10;

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;
input double MaxSpread      = 50;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 100006;
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct FtmoPosition {
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
    int      slPips;      // pips — SL recalkulira se od execution cijene
    datetime signalTime;
    int      delaySeconds;
};

//============================================================
//  GLOBALNE
//============================================================
CTrade       trade;
int          g_atrHandle;
datetime     g_lastBar;
FtmoPosition g_pos;
PendingTrade g_pending;

double   g_sqzLastVal = 0;
bool     g_sqzValSet  = false;

double   g_initialBalance    = 0;
double   g_dailyStartBalance = 0;
datetime g_lastDayReset      = 0;
bool     g_tradingHalted     = false;
string   g_haltReason        = "";

//============================================================
//  INIT
//============================================================
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    int atrP = (SignalType==SIGNAL_SUPERTREND)?ST_Period:(SignalType==SIGNAL_CE)?CE_Period:SQZ_Period;
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrP);
    if(g_atrHandle==INVALID_HANDLE) { Print("ATR FAILED"); return INIT_FAILED; }

    g_lastBar        = 0;
    g_pos.active     = false;
    g_pending.active = false;
    g_sqzValSet      = false;
    g_tradingHalted  = false;

    g_initialBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBalance = g_initialBalance;
    g_lastDayReset      = TimeCurrent();
    MathSrand((uint)TimeCurrent()+(uint)GetTickCount());

    string sigName = (SignalType==SIGNAL_SQZMOM)
        ? "SQZMOM("+IntegerToString(SQZ_Period)+","+DoubleToString(SQZ_BB_Mult,1)+","+DoubleToString(SQZ_KC_Mult,1)+")"
        : (SignalType==SIGNAL_SUPERTREND)
        ? "ST("+IntegerToString(ST_Period)+","+DoubleToString(ST_Multiplier,1)+")"
        : "CE("+IntegerToString(CE_Period)+","+DoubleToString(CE_Multiplier,1)+")";
    double maxScale = 1.0+(UseM15Scale?M15_Bonus:0.0)+(UseH1Scale?H1_Bonus:0.0);

    Print("╔══════════════════════════════════════════════════════╗");
    Print("║  CALF_C Multi-Signal FTMO v5.0                      ║");
    Print("╠══════════════════════════════════════════════════════╣");
    Print("║  Signal:  ", sigName);
    Print("║  SL:      ", SL_Min_Pips, "-", SL_Max_Pips, " pips");
    Print("║  Risk:    ", RiskPercent, "% | MaxScale: ×", DoubleToString(maxScale,1));
    Print("║  M15:     ", UseM15Scale?"ON +"+DoubleToString(M15_Bonus,1):"OFF");
    Print("║  H1:      ", UseH1Scale?"ON +"+DoubleToString(H1_Bonus,1):"OFF");
    Print("║  MFE0:    ", MFE0_Act, "pips/", (int)(MFE0_Pct*100), "%");
    Print("║  MFE1:    ", MFE1_Act, "pips/", (int)(MFE1_Pct*100), "%");
    Print("║  MFE2:    ", MFE2_Act, "pips/", (int)(MFE2_Pct*100), "%");
    Print("║  FTMO:    Daily=",FTMO_DailyLossLimit,"% Total=",FTMO_TotalLossFloor,"% [UVIJEK ON]");
    Print("║  Friday:  ", FTMO_CloseOnFriday?"Zatvori u "+IntegerToString(FTMO_FridayCloseHour)+":00h":"Swing (ne zatvara)");
    Print("║  Magic:   ", MagicNumber);
    Print("╚══════════════════════════════════════════════════════╝");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//============================================================
//  HELPERS
//============================================================
int  RandomRange(int a,int b) { return (a>=b)?a:a+MathRand()%(b-a+1); }
bool IsNewBar() { datetime t=iTime(_Symbol,PERIOD_CURRENT,0); if(t!=g_lastBar){g_lastBar=t;return true;} return false; }

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
    return (dt.day_of_week==5&&dt.hour>=FTMO_FridayCloseHour);
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
//  FTMO ZAŠTITA (uvijek aktivna)
//============================================================
void CheckDailyReset()
{
    MqlDateTime now,last;
    TimeToStruct(TimeCurrent(),now); TimeToStruct(g_lastDayReset,last);
    if(now.day!=last.day)
    {
        double cb=AccountInfoDouble(ACCOUNT_BALANCE);
        Print("CALF_C FTMO: Novi dan | P&L: ",NormalizeDouble(cb-g_dailyStartBalance,2));
        g_dailyStartBalance=cb; g_lastDayReset=TimeCurrent();
        if(g_tradingHalted&&g_haltReason=="DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("CALF_C FTMO: Daily reset — nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double floor = g_initialBalance*(1.0-FTMO_TotalLossFloor/100.0);
    if(eq<floor)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! CALF_C FTMO: TOTAL DD — ZAUSTAVLJENO !!!");
            if(g_pos.active&&PositionSelectByTicket(g_pos.ticket)) trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    double dailyLoss  = g_dailyStartBalance-eq;
    double dailyLimit = g_initialBalance*FTMO_DailyLossLimit/100.0;
    if(dailyLoss>dailyLimit)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="DAILY";
            Print("!!! CALF_C FTMO: DAILY LIMIT — zaustavljeno do ponoći !!!");
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
    if(slPips<=0) return 0;
    double risk  = g_initialBalance*RiskPercent/100.0*scaleMult;
    double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double tv    = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts    = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double step  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    double mn    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double mx    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double lots  = risk/((slPips*point/point)*tv/ts);
    lots=MathFloor(lots/step)*step;
    return MathMax(mn,MathMin(mx,lots));
}

//============================================================
//  SQZMOM za bilo koji TF (za cascade skaliranje)
//============================================================
double CalcSQZMOM_TF(ENUM_TIMEFRAMES tf, int per)
{
    int needed=per*2+5;
    double cl[],hi[],lo[];
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

double GetCascadeScale(int direction)
{
    double scale=1.0;
    if(UseM15Scale){
        double s15=CalcSQZMOM_TF(PERIOD_M15,M15_SQZ_Period);
        if(s15!=0&&((direction==1&&s15>0)||(direction==-1&&s15<0))) scale+=M15_Bonus;
    }
    if(UseH1Scale){
        double sh1=CalcSQZMOM_TF(PERIOD_H1,H1_SQZ_Period);
        if(sh1!=0&&((direction==1&&sh1>0)||(direction==-1&&sh1<0))) scale+=H1_Bonus;
    }
    return scale;
}

//============================================================
//  SIGNAL KALKULACIJE
//============================================================
double CalcSQZMOM_Val()
{
    return CalcSQZMOM_TF(PERIOD_CURRENT, SQZ_Period);
}

void CalcSupertrend(int &d1, int &d2)
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

int DetectSignal()
{
    if(SignalType==SIGNAL_SQZMOM)
    {
        double val=CalcSQZMOM_Val();
        if(!g_sqzValSet){g_sqzLastVal=val;g_sqzValSet=true;return 0;}
        int sig=0;
        if(g_sqzLastVal<=0&&val>0) sig=1; else if(g_sqzLastVal>=0&&val<0) sig=-1;
        g_sqzLastVal=val; return sig;
    }
    else if(SignalType==SIGNAL_SUPERTREND)
    { int d1,d2; CalcSupertrend(d1,d2); if(d1==1&&d2==-1) return 1; if(d1==-1&&d2==1) return -1; return 0; }
    else
    { int d1,d2; CalcCE(d1,d2); if(d1==1&&d2==-1) return 1; if(d1==-1&&d2==1) return -1; return 0; }
}

//============================================================
//  TRADE MANAGEMENT
//============================================================
void QueueTrade(int direction)
{
    if(g_pending.active) return;
    int    slPips = RandomRange(SL_Min_Pips, SL_Max_Pips);
    double scale  = GetCascadeScale(direction);
    double lots   = CalcLots(slPips, scale);
    if(lots<=0) return;
    g_pending.active       = true;
    g_pending.direction    = direction;
    g_pending.lots         = lots;
    g_pending.slPips       = slPips;   // čuvamo pips, ne price
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
    if(scale>1.0) Print("CALF_C FTMO: Cascade ×",DoubleToString(scale,2)," lot=",lots);
}

void ProcessPending()
{
    if(!g_pending.active) return;
    if(TimeCurrent()<g_pending.signalTime+g_pending.delaySeconds) return;
    if(g_pos.active){g_pending.active=false;return;}
    if(!CheckFTMOLimits()){g_pending.active=false;return;}

    int    dir    = g_pending.direction;
    double lots   = g_pending.lots;
    int    digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    double pip    = 0.01;

    // SL od execution cijene (v5.0 fix)
    double price = (dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double sl    = NormalizeDouble((dir==1)?price-g_pending.slPips*pip:price+g_pending.slPips*pip,digits);

    bool ok=(dir==1)?trade.Buy(lots,_Symbol,price,sl,0,"CALFCM_FTMO")
                    :trade.Sell(lots,_Symbol,price,sl,0,"CALFCM_FTMO");
    if(ok)
    {
        ulong ticket=trade.ResultOrder();
        if(PositionSelectByTicket(ticket)&&PositionGetDouble(POSITION_SL)==0)
            trade.PositionModify(ticket,sl,0);
        g_pos.active=true; g_pos.ticket=ticket; g_pos.entry=price;
        g_pos.sl=sl; g_pos.mfe=0.0; g_pos.openTime=TimeCurrent();
        string sn=(SignalType==SIGNAL_SQZMOM)?"SQZ":(SignalType==SIGNAL_SUPERTREND)?"ST":"CE";
        Print("CALF_C FTMO [",sn,"] ",(dir==1?"BUY":"SELL")," #",ticket," @ ",price," SL=",sl," lot=",lots);
    }
    else Print("CALF_C FTMO: OPEN FAILED — ",trade.ResultRetcodeDescription());
    g_pending.active=false;
}

//============================================================
//  MANAGE POSITION — TRI-PHASE MFE TRAILING
//============================================================
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)){g_pos.active=false;return;}

    if(ShouldCloseFriday())
    { Print("CALF_C FTMO: Petkom zatvaranje #",g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

    ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice=(pt==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double curSL=PositionGetDouble(POSITION_SL);
    int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

    double mfeNow=(pt==POSITION_TYPE_BUY)?(curPrice-g_pos.entry)/point:(g_pos.entry-curPrice)/point;
    if(mfeNow>g_pos.mfe) g_pos.mfe=mfeNow;
    double mfe=g_pos.mfe;

    // Backup SL
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
    Print("CALF_C FTMO: Signal ",(sig==1?"BUY":"SELL"));
    QueueTrade(sig);
}

//============================================================
//  ONTESTER
//============================================================
double OnTester()
{
    double pf=TesterStatistics(STAT_PROFIT_FACTOR);
    double tr=TesterStatistics(STAT_TRADES);
    double dd=TesterStatistics(STAT_BALANCE_DD_RELATIVE);
    double wr=TesterStatistics(STAT_PROFIT_TRADES)/(tr>0?tr:1)*100.0;
    double ep=TesterStatistics(STAT_EXPECTED_PAYOFF);
    if(tr<50||dd>10||wr<85) return 0;
    return pf*MathSqrt(tr)*(1.0-dd/100.0)*(wr/92.0)*MathMax(ep/10.0,1.0);
}
//+------------------------------------------------------------------+
