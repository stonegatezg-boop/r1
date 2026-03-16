//+------------------------------------------------------------------+
//|                                           CALF_C_Multi_v4.mq5    |
//|                *** CALF C Multi-Signal v4.0 ***                  |
//|                Created: 12.03.2026 14:00 (Zagreb)                |
//|                                                                   |
//|  3 signala po izboru — isti Dual-Phase MFE trailing              |
//|                                                                   |
//|  BACKTEST REZULTATI (3god, SL=700-740, MFE 5/94% + 100/97%):   |
//|  Supertrend(5,1.5):   T=11010  WR=91.9%  DD=-6.7%  $38B        |
//|  Chandelier(10,2.0):  T=11955  WR=91.5%  DD=-6.5%  $91B        |
//|  SQZMOM(10,2.0,1.5):  T=14072  WR=92.1%  DD=-5.0%  $2.8T       |
//|                                                                   |
//|  SQZMOM SL=750-790: WR=92.4%, DD=-5.2% → FTMO preporučeno      |
//+------------------------------------------------------------------+
#property copyright "CALF_C Multi-Signal v4.0"
#property version   "4.00"
#property strict
#include <Trade\Trade.mqh>

//--- Enum za signal
enum SIGNAL_TYPE
{
    SIGNAL_SQZMOM       = 0,  // SQZMOM (LazyBear) — WR=92.1%, $2.8T
    SIGNAL_SUPERTREND   = 1,  // Supertrend       — WR=91.9%, $38B
    SIGNAL_CE           = 2   // Chandelier Exit  — WR=91.5%, $91B
};

input group "=== SIGNAL ODABIR ==="
input SIGNAL_TYPE SignalType = SIGNAL_SQZMOM; // Signal: SQZMOM / Supertrend / CE

input group "=== SUPERTREND (samo ako SignalType=SUPERTREND) ==="
input int    ST_Period     = 5;    // ST Period     [optimum: 5]
input double ST_Multiplier = 1.5;  // ST Multiplier [optimum: 1.5]

input group "=== CHANDELIER EXIT (samo ako SignalType=CE) ==="
input int    CE_Period     = 10;   // CE Period     [optimum: 10]
input double CE_Multiplier = 2.0;  // CE Multiplier [optimum: 2.0]

input group "=== SQZMOM (samo ako SignalType=SQZMOM) ==="
input int    SQZ_Period  = 10;   // BB/KC period  [optimum: 10]
input double SQZ_BB_Mult = 2.0;  // BB multiplier [optimum: 2.0]
input double SQZ_KC_Mult = 1.5;  // KC multiplier [optimum: 1.5]

input group "=== RISK MANAGEMENT ==="
input double RiskPercent = 1.0;   // Rizik po trejdu (%)
input int    SL_Min_Pips = 700;   // SL min (pips)  [FTMO: 750]
input int    SL_Max_Pips = 740;   // SL max (pips)

input group "=== DUAL-PHASE MFE TRAILING ==="
input int    MFE1_Act  = 5;     // Phase 1: aktivacija (pips) [optimum: 5]
input double MFE1_Pct  = 0.94;  // Phase 1: lock %           [optimum: 94%]
input int    MFE2_Act  = 100;   // Phase 2: aktivacija (pips) [optimum: 100]
input double MFE2_Pct  = 0.97;  // Phase 2: lock %           [optimum: 97%]

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;  // Large candle (×ATR)

input group "=== STEALTH ==="
input bool UseStealthMode = true;
input int  OpenDelayMin   = 0;
input int  OpenDelayMax   = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 100005;
input int   Slippage    = 30;

//--- Strukture
struct PendingTrade {
    bool             active;
    ENUM_ORDER_TYPE  type;
    double           lot;
    datetime         signalTime;
    int              delaySeconds;
};

struct OpenPosition {
    bool   active;
    ulong  ticket;
    double entry;
    double sl;
    double mfe;    // u PIPS
};

//--- Globalne
CTrade       trade;
int          g_atrHandle;
datetime     g_lastBar;
PendingTrade g_pending;
OpenPosition g_pos;

// SQZMOM state (bar-by-bar)
double       g_sqzLastVal = 0;
bool         g_sqzValSet  = false;

// ST / CE direction state
int          g_prevDir1   = 0;  // bar[1] direction
int          g_prevDir2   = 0;  // bar[2] direction

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    int atrPeriod = (SignalType==SIGNAL_SUPERTREND) ? ST_Period :
                    (SignalType==SIGNAL_CE)         ? CE_Period : SQZ_Period;
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    if(g_atrHandle == INVALID_HANDLE) { Print("ATR handle FAILED"); return INIT_FAILED; }

    g_lastBar        = 0;
    g_pending.active = false;
    g_pos.active     = false;
    g_sqzValSet      = false;
    g_prevDir1       = 0; g_prevDir2 = 0;

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());

    string sigName = (SignalType==SIGNAL_SQZMOM) ? "SQZMOM("+IntegerToString(SQZ_Period)+","+
                     DoubleToString(SQZ_BB_Mult,1)+","+DoubleToString(SQZ_KC_Mult,1)+")" :
                     (SignalType==SIGNAL_SUPERTREND) ? "ST("+IntegerToString(ST_Period)+","+
                     DoubleToString(ST_Multiplier,1)+")" :
                     "CE("+IntegerToString(CE_Period)+","+DoubleToString(CE_Multiplier,1)+")";
    Print("=== CALF_C Multi v4.0 | ", sigName, " | SL=", SL_Min_Pips, "-", SL_Max_Pips,
          " | MFE ", MFE1_Act, "/", (int)(MFE1_Pct*100), "% + ", MFE2_Act, "/", (int)(MFE2_Pct*100), "% ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
int  RandomRange(int a, int b)   { return (a>=b) ? a : a + MathRand()%(b-a+1); }
bool IsNewBar()                  { datetime t=iTime(_Symbol,PERIOD_CURRENT,0); if(t!=g_lastBar){g_lastBar=t;return true;} return false; }

bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if(dt.day_of_week==6) return false;
    if(dt.day_of_week==0) return (dt.hour>0 || dt.min>=1);
    if(dt.day_of_week==5) return (dt.hour<11);
    return true;
}

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

bool IsLargeCandle()
{
    double atr = GetATR();
    if(atr <= 0) return false;
    return (iHigh(_Symbol,PERIOD_CURRENT,1) - iLow(_Symbol,PERIOD_CURRENT,1)) > LargeCandleATR*atr;
}

bool HasOpenPosition()
{
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t))
            if(PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
               PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
    }
    return false;
}

double CalcLots(int slPips)
{
    if(slPips<=0) return 0;
    double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk   = bal * RiskPercent / 100.0;
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tv     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double mn     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double mx     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots   = risk / ((slPips * point / point) * tv / ts);
    lots = MathFloor(lots/step)*step;
    return MathMax(mn, MathMin(mx, lots));
}

//+------------------------------------------------------------------+
//| SQZMOM val za bar[1] (zadnji zatvoreni)                          |
//+------------------------------------------------------------------+
double CalcSQZMOM_Val()
{
    int per      = SQZ_Period;
    int barsNeeded = per*2 + 5;
    double cl[], hi[], lo[];
    ArraySetAsSeries(cl,true); ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
    if(CopyClose(_Symbol,PERIOD_CURRENT,1,barsNeeded,cl) < barsNeeded) return 0;
    if(CopyHigh (_Symbol,PERIOD_CURRENT,1,barsNeeded,hi) < barsNeeded) return 0;
    if(CopyLow  (_Symbol,PERIOD_CURRENT,1,barsNeeded,lo) < barsNeeded) return 0;
    double delta[200];
    for(int j=0; j<per; j++)
    {
        if(j+per > barsNeeded) return 0;
        double s=0;
        for(int k=j; k<j+per; k++) s+=cl[k];
        double basis=s/per;
        double hmax=hi[j], lmin=lo[j];
        for(int k=j+1; k<j+per; k++) { if(hi[k]>hmax) hmax=hi[k]; if(lo[k]<lmin) lmin=lo[k]; }
        delta[j] = cl[j] - (((hmax+lmin)/2.0 + basis)/2.0);
    }
    double xm=(per-1)/2.0, ym=0;
    for(int i=0; i<per; i++) ym+=delta[per-1-i];
    ym/=per;
    double num=0, den=0;
    for(int i=0; i<per; i++) { double xi=i-xm, yi=delta[per-1-i]-ym; num+=xi*yi; den+=xi*xi; }
    if(den==0) return ym;
    double slope=num/den, intercept=ym-slope*xm;
    return slope*(per-1)+intercept;
}

//+------------------------------------------------------------------+
//| Supertrend za bar[1] i bar[2]                                    |
//+------------------------------------------------------------------+
void CalcSupertrend(int &dir1, int &dir2)
{
    int bars = ST_Period + 10;
    double hi[], lo[], cl[];
    ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
    CopyHigh (_Symbol,PERIOD_CURRENT,0,bars,hi);
    CopyLow  (_Symbol,PERIOD_CURRENT,0,bars,lo);
    CopyClose(_Symbol,PERIOD_CURRENT,0,bars,cl);
    double sumTR=0;
    for(int i=1; i<=ST_Period; i++) {
        double tr=MathMax(hi[i]-lo[i], MathMax(MathAbs(hi[i]-cl[i+1]), MathAbs(lo[i]-cl[i+1])));
        sumTR+=tr;
    }
    double atr=sumTR/ST_Period;
    double stLine[6]; int stDir[6];
    for(int s=5; s>=0; s--) {
        double hl2=(hi[s]+lo[s])/2.0, ub=hl2+ST_Multiplier*atr, lb=hl2-ST_Multiplier*atr;
        double ps=(s<5)?stLine[s+1]:hl2; int pd=(s<5)?stDir[s+1]:1;
        if(pd==1) { if(cl[s]<ps){stLine[s]=ub;stDir[s]=-1;} else {stLine[s]=MathMax(lb,ps);stDir[s]=1;} }
        else      { if(cl[s]>ps){stLine[s]=lb;stDir[s]=1;}  else {stLine[s]=MathMin(ub,ps);stDir[s]=-1;} }
    }
    dir1=stDir[1]; dir2=stDir[2];
}

//+------------------------------------------------------------------+
//| Chandelier Exit za bar[1] i bar[2]                               |
//+------------------------------------------------------------------+
void CalcChandelierExit(int &dir1, int &dir2)
{
    int bars = CE_Period * 3 + 5;
    double hi[], lo[], cl[];
    ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
    CopyHigh (_Symbol,PERIOD_CURRENT,0,bars,hi);
    CopyLow  (_Symbol,PERIOD_CURRENT,0,bars,lo);
    CopyClose(_Symbol,PERIOD_CURRENT,0,bars,cl);
    // ATR = SMA za CE_Period barova (recentnih, bar[1..CE_Period])
    double sumTR=0;
    for(int i=1; i<=CE_Period; i++) {
        double tr=MathMax(hi[i]-lo[i], MathMax(MathAbs(hi[i]-cl[i+1]), MathAbs(lo[i]-cl[i+1])));
        sumTR+=tr;
    }
    double atr=sumTR/CE_Period;
    // Compute CE direction for bars 1 and 2
    // For each of the last 3 bars, compute long/short CE and direction
    int dirArr[4]; // dirArr[3]=oldest, dirArr[1]=bar[1]
    dirArr[3]=1; // init
    for(int s=3; s>=1; s--) {
        // Highest high over CE_Period ending at bar s
        double hmax=hi[s]; double lmin=lo[s];
        for(int k=s+1; k<s+CE_Period && k<bars; k++) { if(hi[k]>hmax) hmax=hi[k]; if(lo[k]<lmin) lmin=lo[k]; }
        double ceLong  = hmax - CE_Multiplier*atr;
        double ceShort = lmin + CE_Multiplier*atr;
        int prevD=(s<3)?dirArr[s+1]:1;
        if(prevD==1)  dirArr[s]=(cl[s]<=ceLong)  ? -1 : 1;
        else          dirArr[s]=(cl[s]>=ceShort)  ?  1 : -1;
    }
    dir1=dirArr[1]; dir2=dirArr[2];
}

//+------------------------------------------------------------------+
//| Detektira signal (BUY=1, SELL=-1, nema=0)                       |
//+------------------------------------------------------------------+
int DetectSignal()
{
    if(SignalType == SIGNAL_SQZMOM)
    {
        double val = CalcSQZMOM_Val();
        if(!g_sqzValSet) { g_sqzLastVal=val; g_sqzValSet=true; return 0; }
        int sig = 0;
        if(g_sqzLastVal<=0 && val>0) sig = 1;
        else if(g_sqzLastVal>=0 && val<0) sig = -1;
        g_sqzLastVal = val;
        return sig;
    }
    else if(SignalType == SIGNAL_SUPERTREND)
    {
        int d1, d2; CalcSupertrend(d1, d2);
        if(d1==1 && d2==-1) return 1;
        if(d1==-1 && d2==1) return -1;
        return 0;
    }
    else  // CE
    {
        int d1, d2; CalcChandelierExit(d1, d2);
        if(d1==1 && d2==-1) return 1;
        if(d1==-1 && d2==1) return -1;
        return 0;
    }
}

//+------------------------------------------------------------------+
void QueueTrade(ENUM_ORDER_TYPE type)
{
    int slPips = RandomRange(SL_Min_Pips, SL_Max_Pips);
    g_pending.active       = true;
    g_pending.type         = type;
    g_pending.lot          = CalcLots(slPips);
    g_pending.signalTime   = TimeCurrent();
    g_pending.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
}

void ExecuteTrade()
{
    if(!g_pending.active) return;
    if(TimeCurrent() < g_pending.signalTime + g_pending.delaySeconds) return;
    ENUM_ORDER_TYPE type = g_pending.type;
    double lot = g_pending.lot;
    g_pending.active = false;

    double price  = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
    int    slPips = RandomRange(SL_Min_Pips, SL_Max_Pips);
    double point  = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double sl     = (type==ORDER_TYPE_BUY) ? price-slPips*point : price+slPips*point;
    int    digits = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);

    bool ok = (type==ORDER_TYPE_BUY) ? trade.Buy(lot,_Symbol,price,sl,0,"CALFCM_v4")
                                     : trade.Sell(lot,_Symbol,price,sl,0,"CALFCM_v4");
    if(!ok) { Print("CALF_C Multi: OPEN FAILED - ", trade.ResultRetcodeDescription()); return; }

    ulong ticket = trade.ResultOrder();
    // Backup SL
    if(PositionSelectByTicket(ticket) && PositionGetDouble(POSITION_SL)==0)
        trade.PositionModify(ticket, sl, 0);

    g_pos.active = true;
    g_pos.ticket = ticket;
    g_pos.entry  = price;
    g_pos.sl     = sl;
    g_pos.mfe    = 0.0;

    string sigName = (SignalType==SIGNAL_SQZMOM)?"SQZMOM":(SignalType==SIGNAL_SUPERTREND)?"ST":"CE";
    Print("CALF_C Multi v4.0 [",sigName,"]: ", (type==ORDER_TYPE_BUY?"BUY":"SELL"),
          " #",ticket," @ ",price," SL=",sl," (",slPips,"pips) lot=",lot);
}

//+------------------------------------------------------------------+
//| MFE Dual-Phase Trailing                                          |
//+------------------------------------------------------------------+
void ManagePosition()
{
    if(!g_pos.active) return;
    if(!PositionSelectByTicket(g_pos.ticket)) { g_pos.active=false; return; }

    ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double curPrice = (pt==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double point    = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double curSL    = PositionGetDouble(POSITION_SL);
    int    digits   = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

    // MFE update (u pips)
    double mfeNow = (pt==POSITION_TYPE_BUY) ? (curPrice-g_pos.entry)/point : (g_pos.entry-curPrice)/point;
    if(mfeNow > g_pos.mfe) g_pos.mfe = mfeNow;
    double mfe = g_pos.mfe;

    // Backup SL
    if(curSL==0 && g_pos.sl!=0) { trade.PositionModify(g_pos.ticket, NormalizeDouble(g_pos.sl,digits), 0); return; }

    double newSL = curSL;
    if(mfe >= MFE2_Act)
    {
        double lock = mfe * MFE2_Pct;
        double ns   = (pt==POSITION_TYPE_BUY) ? g_pos.entry+lock*point : g_pos.entry-lock*point;
        ns = NormalizeDouble(ns, digits);
        if((pt==POSITION_TYPE_BUY && ns>curSL) || (pt==POSITION_TYPE_SELL && ns<curSL)) newSL=ns;
    }
    else if(mfe >= MFE1_Act)
    {
        double lock = mfe * MFE1_Pct;
        double ns   = (pt==POSITION_TYPE_BUY) ? g_pos.entry+lock*point : g_pos.entry-lock*point;
        ns = NormalizeDouble(ns, digits);
        if((pt==POSITION_TYPE_BUY && ns>curSL) || (pt==POSITION_TYPE_SELL && ns<curSL)) newSL=ns;
    }

    if(newSL != curSL) { if(trade.PositionModify(g_pos.ticket,newSL,0)) g_pos.sl=newSL; }
}

//+------------------------------------------------------------------+
void OnTick()
{
    ExecuteTrade();
    ManagePosition();

    if(!IsNewBar()) return;

    if(g_pos.active && !PositionSelectByTicket(g_pos.ticket)) g_pos.active=false;
    if(g_pos.active)     return;
    if(g_pending.active) return;
    if(!IsTradingWindow()) return;
    if(IsLargeCandle())    return;
    if(HasOpenPosition())  return;

    int sig = DetectSignal();
    if(sig == 0) return;

    Print("CALF_C Multi v4.0: Signal ", (sig==1?"BUY":"SELL"));
    if(UseStealthMode) QueueTrade(sig==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
    else { g_pending.active=true; g_pending.type=(sig==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
           g_pending.lot=CalcLots(RandomRange(SL_Min_Pips,SL_Max_Pips));
           g_pending.signalTime=TimeCurrent(); g_pending.delaySeconds=0; ExecuteTrade(); }
}
//+------------------------------------------------------------------+
