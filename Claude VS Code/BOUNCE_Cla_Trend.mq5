//+------------------------------------------------------------------+
//|                                            BOUNCE_Cla_Trend.mq5 |
//|              *** BOUNCE v2.1 — Mean Reversion + Trend Filter *** |
//|              Created: 12.03.2026 (Zagreb)                         |
//|              Upgrade: 16.03.2026 — v2.1: EMA Trend Filter ON    |
//|                                                                   |
//|  Razlika od BOUNCE_Cla.mq5 (v2.0):                              |
//|    UseTrendFilter = TRUE (default ON — bio FALSE)                |
//|    BUY  samo kad close > EMA(50) (bullish trend)                 |
//|    SELL samo kad close < EMA(50) (bearish trend)                 |
//|                                                                   |
//|  Zašto: 16.03.2026 BOUNCE otvorio SELL @ 5016.76 u uzlaznom    |
//|    trendu → SL udaren isti bar (High 5021.07 > SL 5020.32)      |
//|    EMA(50) filter bi blokirao taj SELL jer close > EMA(50)       |
//|                                                                   |
//|  Signal: RSI(7) crossover iz ekstremne zone (mean reversion)     |
//|    BUY:  RSI7 prelazi GORE kroz OS threshold + close > EMA(50)  |
//|    SELL: RSI7 prelazi DOLJE kroz OB threshold + close < EMA(50) |
//|                                                                   |
//|  Magic: 481371 (BOUNCE_Cla=481370, ne konfliktiraju)            |
//+------------------------------------------------------------------+
#property copyright "BOUNCE_Cla_Trend v2.1 — Mean Reversion + Trend Filter (2026-03-16)"
#property version   "2.10"
#property strict
#include <Trade\Trade.mqh>

//============================================================
//  ENUMI
//============================================================
enum ENUM_DIR { DIR_BOTH=0, DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//============================================================
//  INPUTI
//============================================================
input group "=== SIGNAL — RSI Mean Reversion ==="
input int    RSI_Period    = 7;    // RSI period [backtest optimum: 7]
input int    RSI_Oversold  = 40;   // RSI ispod = oversold → BUY signal [v2.0 optimum: 40]
input int    RSI_Overbought = 60;  // RSI iznad = overbought → SELL signal [v2.0 optimum: 60]
input ENUM_DIR Direction   = DIR_BOTH;

input group "=== TREND FILTER (EMA) ==="
input bool   UseTrendFilter  = true;  // [v2.1 DEFAULT ON] BUY samo >EMA, SELL samo <EMA
input int    TrendEMA_Period = 50;    // EMA period za trend smjer

input group "=== M15+H1 KASKADNO LOT SKALIRANJE ==="
input bool   UseM15Scale    = true;
input double M15_Bonus      = 0.5;
input int    M15_SQZ_Period = 10;
input bool   UseH1Scale     = true;
input double H1_Bonus       = 0.3;
input int    H1_SQZ_Period  = 10;

input group "=== TRI-PHASE MFE TRAILING ==="
input int    MFE0_Act = 0;    // Phase 0: DISABLED
input double MFE0_Pct = 0.95;
input int    MFE1_Act = 20;   // Phase 1: aktivacija (pips)
input double MFE1_Pct = 0.85;
input int    MFE2_Act = 150;  // Phase 2: aktivacija (pips)
input double MFE2_Pct = 0.98;

input group "=== RISK & SL ==="
input double RiskPercent = 0.5;
input int    SL_Min      = 400;
input int    SL_Max      = 440;
input bool   UseInitialBalance = true;

input group "=== FTMO ZAŠTITA ==="
input double FTMO_DailyLimit    = 4.5;
input double FTMO_TotalFloor    = 9.0;
input bool   FTMO_Active        = true;
input bool   FTMO_CloseOnFriday = false;
input int    FTMO_FridayHour    = 10;

input group "=== FILTERI ==="
input double LargeCandleATR = 3.0;
input double MaxSpread      = 50;

input group "=== STEALTH ==="
input int OpenDelayMin = 0;
input int OpenDelayMax = 4;

input group "=== OPĆE ==="
input ulong MagicNumber = 481371;  // BOUNCE_Cla_Trend (481370=BOUNCE_Cla)
input int   Slippage    = 30;

//============================================================
//  STRUKTURE
//============================================================
struct BouncePosition {
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
int             g_rsiHandle;
int             g_atrHandle;
int             g_emaHandle;
datetime        g_lastBar;
BouncePosition  g_pos;
PendingTrade    g_pending;

double   g_rsiLast      = 50;
bool     g_rsiSet       = false;

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

    g_rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 10);
    g_emaHandle = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);

    if(g_rsiHandle==INVALID_HANDLE||g_atrHandle==INVALID_HANDLE||g_emaHandle==INVALID_HANDLE)
    { Print("BOUNCE_TREND: Handle FAILED"); return INIT_FAILED; }

    g_lastBar=0; g_pos.active=false; g_pending.active=false;
    g_rsiSet=false; g_tradingHalted=false;
    g_initialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
    g_dailyStartBal   = g_initialBalance;
    g_lastDayReset    = TimeCurrent();
    MathSrand((uint)TimeCurrent()+(uint)GetTickCount());

    double maxScale = 1.0 + (UseM15Scale?M15_Bonus:0.0) + (UseH1Scale?H1_Bonus:0.0);
    Print("╔══════════════════════════════════════════════════╗");
    Print("║   BOUNCE_Cla_Trend v2.1 — Trend Filter ACTIVE   ║");
    Print("╠══════════════════════════════════════════════════╣");
    Print("║  Signal:  RSI(", RSI_Period, ") OS=", RSI_Oversold, " OB=", RSI_Overbought);
    Print("║  Trend:   EMA(", TrendEMA_Period, ") filter ", UseTrendFilter?"ON":"OFF");
    Print("║  SL:      ", SL_Min, "-", SL_Max, " pips");
    Print("║  Risk:    ", RiskPercent, "% | MaxScale: x", DoubleToString(maxScale,1));
    Print("║  M15:     ", UseM15Scale?"ON +"+DoubleToString(M15_Bonus,1):"OFF");
    Print("║  H1:      ", UseH1Scale?"ON +"+DoubleToString(H1_Bonus,1):"OFF");
    Print("║  MFE1:    ", MFE1_Act, "pips/", (int)(MFE1_Pct*100), "%");
    Print("║  MFE2:    ", MFE2_Act, "pips/", (int)(MFE2_Pct*100), "%");
    if(FTMO_Active) Print("║  FTMO:    Daily=",FTMO_DailyLimit,"% Total=",FTMO_TotalFloor,"%");
    Print("║  Magic:   ", MagicNumber);
    Print("╚══════════════════════════════════════════════════╝");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_rsiHandle!=INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
    if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
    if(g_emaHandle!=INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

//============================================================
//  HELPERS
//============================================================
int  RandomRange(int a,int b) { return (a>=b)?a:a+MathRand()%(b-a+1); }
bool IsNewBar()
{
    datetime t=iTime(_Symbol,PERIOD_CURRENT,0);
    if(t!=g_lastBar){g_lastBar=t;return true;}
    return false;
}

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
    if(!FTMO_Active||!FTMO_CloseOnFriday) return false;
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

double GetEMA()
{
    double buf[]; ArraySetAsSeries(buf,true);
    if(CopyBuffer(g_emaHandle,0,1,1,buf)<=0) return 0;
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
            if(PositionGetInteger(POSITION_MAGIC)==MagicNumber&&
               PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
    }
    return false;
}

//============================================================
//  TREND FILTER
//  BUY  : close[1] > EMA(50)[1]  — bullish trend
//  SELL : close[1] < EMA(50)[1]  — bearish trend
//============================================================
bool IsTrendAligned(int direction)
{
    if(!UseTrendFilter) return true;
    double ema = GetEMA();
    if(ema <= 0) return true;
    double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    if(direction == 1)  return (lastClose > ema);   // BUY samo u uzlaznom trendu
    if(direction == -1) return (lastClose < ema);   // SELL samo u silaznom trendu
    return true;
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
        Print("BOUNCE_TREND: Novi dan | P&L: ",NormalizeDouble(cb-g_dailyStartBal,2));
        g_dailyStartBal=cb; g_lastDayReset=TimeCurrent();
        if(g_tradingHalted&&g_haltReason=="DAILY")
        { g_tradingHalted=false; g_haltReason=""; Print("BOUNCE_TREND: Daily reset — nastavlja"); }
    }
}

bool CheckFTMOLimits()
{
    if(!FTMO_Active) return true;
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    double floor=g_initialBalance*(1.0-FTMO_TotalFloor/100.0);
    if(eq<floor)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="TOTAL";
            Print("!!! BOUNCE_TREND FTMO: TOTAL DD — ZAUSTAVLJENO !!!");
            if(g_pos.active&&PositionSelectByTicket(g_pos.ticket)) trade.PositionClose(g_pos.ticket);
        }
        return false;
    }
    double dailyLoss=g_dailyStartBal-eq;
    double dailyLimit=g_initialBalance*FTMO_DailyLimit/100.0;
    if(dailyLoss>dailyLimit)
    {
        if(!g_tradingHalted){
            g_tradingHalted=true; g_haltReason="DAILY";
            Print("!!! BOUNCE_TREND FTMO: DAILY LIMIT — zaustavljeno do ponoći !!!");
        }
        return false;
    }
    return !g_tradingHalted;
}

//============================================================
//  LOT KALKULACIJA
//============================================================
double CalcLots(int slPips, double scaleMult=1.0)
{
    if(slPips<=0) return 0;
    double balRef=UseInitialBalance?g_initialBalance:AccountInfoDouble(ACCOUNT_BALANCE);
    double risk=balRef*RiskPercent/100.0*scaleMult;
    double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
    double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
    double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
    double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double lots=risk/((slPips*point/point)*tv/ts);
    lots=MathFloor(lots/step)*step;
    return MathMax(mn,MathMin(mx,lots));
}

//============================================================
//  SQZMOM za bilo koji TF
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
//  RSI SIGNAL DETEKCIJA
//============================================================
int DetectSignal()
{
    double rsi[]; ArraySetAsSeries(rsi,true);
    if(CopyBuffer(g_rsiHandle,0,1,2,rsi)<2) return 0;
    double rsi1=rsi[0];  // bar[1]
    double rsi2=rsi[1];  // bar[2]

    if(!g_rsiSet){g_rsiLast=rsi1;g_rsiSet=true;return 0;}

    int sig=0;
    if(rsi2 <= RSI_Oversold   && rsi1 > RSI_Oversold)  sig=1;
    if(rsi2 >= RSI_Overbought && rsi1 < RSI_Overbought) sig=-1;

    g_rsiLast=rsi1;
    return sig;
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
    if(scale>1.0) Print("BOUNCE_TREND: Cascade x",DoubleToString(scale,2)," lot=",g_pending.lots);
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

    bool ok=(dir==1)?trade.Buy(lots,_Symbol,price,sl,0,"BOUNCE_Trend")
                    :trade.Sell(lots,_Symbol,price,sl,0,"BOUNCE_Trend");
    if(ok)
    {
        ulong ticket=trade.ResultOrder();
        if(PositionSelectByTicket(ticket)&&PositionGetDouble(POSITION_SL)==0)
            trade.PositionModify(ticket,sl,0);
        g_pos.active=true; g_pos.ticket=ticket; g_pos.entry=price;
        g_pos.sl=sl; g_pos.mfe=0.0; g_pos.openTime=TimeCurrent();

        double ema=GetEMA();
        Print("BOUNCE_TREND ",(dir==1?"BUY":"SELL")," #",ticket," @ ",price,
              " SL=",sl," lot=",lots," EMA50=",DoubleToString(ema,2));
    }
    else Print("BOUNCE_TREND: OPEN FAILED — ",trade.ResultRetcodeDescription());
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
    { Print("BOUNCE_TREND: Petkom zatvaranje #",g_pos.ticket); trade.PositionClose(g_pos.ticket); return; }

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
    if(FTMO_Active) CheckDailyReset();
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

    // TREND FILTER — ključna promjena vs BOUNCE_Cla
    if(!IsTrendAligned(sig))
    {
        double ema=GetEMA();
        double lastClose=iClose(_Symbol,PERIOD_CURRENT,1);
        Print("BOUNCE_TREND: Signal ",(sig==1?"BUY":"SELL")," BLOKIRAN — trend filter",
              " close=",DoubleToString(lastClose,2)," EMA50=",DoubleToString(ema,2));
        return;
    }

    Print("BOUNCE_TREND: Signal ",(sig==1?"BUY":"SELL")," RSI7 crossover + trend OK");
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
    if(tr<50||dd>10||wr<80) return 0;
    return pf * MathSqrt(tr) * (1.0-dd/100.0) * (wr/86.0) * MathMax(ep/10.0,1.0);
}
//+------------------------------------------------------------------+
