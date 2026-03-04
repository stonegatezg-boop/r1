//+------------------------------------------------------------------+
//|                                                    CALF_A_M.mq5  |
//|                        *** CALF A M - UT Bot + Market Protection |
//|                   + Stealth Mode v2.4 (PIP FIX)                  |
//|                   + NEWS FILTER & SPREAD FILTER                  |
//|                   + 3-LEVEL MFE TRAILING SYSTEM                  |
//|                   Based on CALF_A with Market Protection         |
//|                   Created: 2026-02-23                            |
//|                   Fixed: 03.03.2026 (Zagreb) - MFE Trailing v1.2 |
//|                   Fixed: 03.03.2026 22:30 (Zagreb) - REAL SL     |
//|                   Fixed: 04.03.2026 (Zagreb) - PIP FIX *10       |
//|                   - SL 789-811 pips (random) ODMAH               |
//+------------------------------------------------------------------+
#property copyright "CALF A M - MFE Trailing v2.4 PIP FIX"
#property version   "2.40"
#property strict

#include <Trade\Trade.mqh>

input group "=== UT BOT POSTAVKE ==="
input double   UTKey            = 2.0;
input int      UTAtrPeriod      = 10;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 3.0;
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
// SLDelayMin/Max uklonjeni - SL se postavlja ODMAH (v2.3)
input double   LargeCandleATR   = 2.0;      // 2x ATR Large Candle Filter

input group "=== 3-LEVEL TRAILING (MFE-based) ==="
input int      HardSL_Pips        = 800;      // Hard Stop Loss (stealth)
input int      Level1_Pips        = 500;      // L1: Aktivacija BE trailing
input int      Level1_BEPips      = 40;       // L1: SL = BE + ovo
input int      Level2_Pips        = 1000;     // L2: Aktivacija lock trailing
input int      Level2_LockPips    = 300;      // L2: Lock ovaj profit
input double   Level3_MFEPercent  = 30.0;     // L3: Trailing = MFE - X%
input double   FixedLotSize       = 0.01;     // Fiksni lot size

input group "=== NEWS FILTER (NOVO) ==="
input bool     UseNewsFilter       = true;  // Koristi News Filter
input int      NewsImportance      = 2;     // Min važnost vijesti (1=Low, 2=Medium, 3=High)
input int      NewsMinutesBefore   = 30;    // Minuta prije vijesti - ne trguj
input int      NewsMinutesAfter    = 30;    // Minuta nakon vijesti - ne trguj

input group "=== SPREAD FILTER (NOVO) ==="
input bool     UseSpreadFilter     = true;  // Koristi Spread Filter
input int      MaxSpreadPoints     = 50;    // Max spread u points (0 = disable)

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100011;   // Magic Number (različit od CALF_A!)
input int      Slippage         = 30;

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo {
    bool active;
    ulong ticket;
    double intendedSL;          // SL za backup retry
    double stealthTP;           // Stealth Take Profit cijena
    double entryPrice;          // Entry cijena
    datetime openTime;          // Vrijeme otvaranja
    int trailLevel;             // 0=none, 1=BE, 2=Lock, 3=MFE
    double maxProfitPoints;     // MFE tracking (Maximum Favorable Excursion)
};

CTrade trade;
int atrHandle;
double trailingStop[];
int utPosition[];
datetime lastBarTime;

PendingTradeInfo g_pendingTrade;
StealthPosInfo   g_positions[];
int              g_posCount = 0;

// Statistika filtera
int              newsBlockedCount = 0;
int              spreadBlockedCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;
    ArraySetAsSeries(trailingStop, true);
    ArraySetAsSeries(utPosition, true);
    ArrayResize(trailingStop, 3);
    ArrayResize(utPosition, 3);
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0);
    g_posCount = 0;

    Print("╔══════════════════════════════════════════════════════════╗");
    Print("║       CALF A M v1.2 - MFE TRAILING SYSTEM                ║");
    Print("╠══════════════════════════════════════════════════════════╣");
    Print("║ UT Bot Strategy + Stealth Mode + MFE Trailing");
    Print("║ Large Candle: ", LargeCandleATR, "x ATR");
    Print("║ Hard SL: -", HardSL_Pips, " pips (stealth)");
    Print("║ L1: +", Level1_Pips, " pips → BE+", Level1_BEPips);
    Print("║ L2: +", Level2_Pips, " pips → Lock ", Level2_LockPips, " pips");
    Print("║ L3: MFE - ", Level3_MFEPercent, "% (Dynamic)");
    Print("║ NEWS: ", UseNewsFilter ? "ON" : "OFF", " | SPREAD: ", UseSpreadFilter ? "ON" : "OFF", " (", MaxSpreadPoints, "pt)");
    Print("╚══════════════════════════════════════════════════════════╝");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);

    Print("═══ CALF A M STATISTIKA ═══");
    Print("Blokirano zbog NEWS: ", newsBlockedCount);
    Print("Blokirano zbog SPREAD: ", spreadBlockedCount);
}

//+------------------------------------------------------------------+
//| NEWS FILTER - Provjera ekonomskog kalendara                      |
//+------------------------------------------------------------------+
bool HasActiveNews()
{
    if(!UseNewsFilter) return false;

    // Dohvati valute iz simbola
    string symbol = _Symbol;
    string currency1 = StringSubstr(symbol, 0, 3);
    string currency2 = StringSubstr(symbol, 3, 3);

    // Provjeri obje valute
    if(HasCurrencyNews(currency1)) return true;
    if(HasCurrencyNews(currency2)) return true;

    return false;
}

bool HasCurrencyNews(string currency)
{
    datetime currentTime = TimeTradeServer();
    datetime checkFrom = currentTime - NewsMinutesBefore * 60;
    datetime checkTo = currentTime + NewsMinutesAfter * 60;

    MqlCalendarValue values[];
    int count = CalendarValueHistory(values, checkFrom, checkTo, NULL, currency);

    if(count <= 0) return false;

    for(int i = 0; i < count; i++)
    {
        MqlCalendarEvent event;
        if(!CalendarEventById(values[i].event_id, event)) continue;

        // Provjeri važnost vijesti
        if(event.importance >= NewsImportance)
        {
            datetime eventTime = values[i].time;
            datetime blockStart = eventTime - NewsMinutesBefore * 60;
            datetime blockEnd = eventTime + NewsMinutesAfter * 60;

            if(currentTime >= blockStart && currentTime <= blockEnd)
            {
                PrintFormat("⚠ NEWS BLOCK: %s (%s) @ %s [Importance: %d]",
                           event.name, currency, TimeToString(eventTime), event.importance);
                return true;
            }
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| SPREAD FILTER - Provjera trenutnog spreada                       |
//+------------------------------------------------------------------+
bool IsSpreadTooHigh()
{
    if(!UseSpreadFilter || MaxSpreadPoints <= 0) return false;

    int currentSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

    if(currentSpread > MaxSpreadPoints)
    {
        PrintFormat("⚠ SPREAD BLOCK: Current %d > Max %d points", currentSpread, MaxSpreadPoints);
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
int RandomRange(int minVal, int maxVal)
{
    if(minVal >= maxVal) return minVal;
    return minVal + (MathRand() % (maxVal - minVal + 1));
}

bool IsTradingWindow()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    // Sunday from 00:01
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));
    // Mon-Thu all day
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
    // Friday until 11:30
    if(dt.day_of_week == 5) return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));
    return false;
}

bool IsBlackoutPeriod()
{
    // v2.1: No blackout periods
    return false;
}

bool IsLargeCandle()
{
    if(!UseStealthMode) return false;
    double atr[]; ArraySetAsSeries(atr, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
    double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double low  = iLow(_Symbol, PERIOD_CURRENT, 1);
    return ((high - low) > LargeCandleATR * atr[0]);
}

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(t != lastBarTime) { lastBarTime = t; return true; }
    return false;
}

void CalculateUTBot()
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true); ArraySetAsSeries(high, true); ArraySetAsSeries(low, true);
    int copied = CopyClose(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, UTAtrPeriod + 10, low);
    if(copied < UTAtrPeriod + 5) return;
    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i+1]), MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double atr = sumTR / UTAtrPeriod;
    if(atr <= 0) return;
    double nLoss = UTKey * atr;
    double ts[5]; int pos[5];
    ArrayInitialize(ts, 0); ArrayInitialize(pos, 0);
    ts[4] = close[4]; pos[4] = (close[4] > close[5]) ? 1 : -1;
    for(int i = 3; i >= 0; i--)
    {
        double src = close[i]; double prevTS = ts[i+1]; int prevPos = pos[i+1];
        if(prevPos == 1) { ts[i] = MathMax(prevTS, src - nLoss); if(src < ts[i]) { ts[i] = src + nLoss; pos[i] = -1; } else { pos[i] = 1; } }
        else { ts[i] = MathMin(prevTS, src + nLoss); if(src > ts[i]) { ts[i] = src - nLoss; pos[i] = 1; } else { pos[i] = -1; } }
    }
    for(int i = 0; i < 3; i++) { trailingStop[i] = ts[i]; utPosition[i] = pos[i]; }
}

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

double CalculateLotSize(double slDist)
{
    if(slDist <= 0) return 0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt = balance * RiskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lots = riskAmt / ((slDist / point) * tickVal / tickSize);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
    }
    return false;
}

void QueueTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR(); if(atr <= 0) return;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // TP ostaje ATR-based (stealth)
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
    // v2.4: SL se računa random 789-811 pips u ExecuteTrade()
    double slDist = HardSL_Pips * point;  // ISPRAVNO: bez * 10
    double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;

    if(UseStealthMode)
    {
        g_pendingTrade.active = true;
        g_pendingTrade.type = type;
        g_pendingTrade.lot = FixedLotSize;
        g_pendingTrade.intendedSL = sl;  // v2.2: PRAVI SL
        g_pendingTrade.intendedTP = tp;
        g_pendingTrade.signalTime = TimeCurrent();
        g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
        Print("CALF_A_M: Trade queued, SL=", HardSL_Pips, " pips");
    }
    else
    {
        ExecuteTrade(type, FixedLotSize, sl, tp);
    }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // v2.4 FIX: Random SL 789-811 pips (1 pip = 0.01 za XAUUSD)
    int randomSLPips = RandomRange(789, 811);
    double slDistance = randomSLPips * point;  // ISPRAVNO: bez * 10
    sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);
    bool ok;

    // v2.3: Otvori BEZ SL-a, pa ODMAH postavi s PositionModify
    if(UseStealthMode)
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_A_M") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_A_M");
    else
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_A_M BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_A_M SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        // v2.3: ODMAH postavi SL
        if(UseStealthMode)
        {
            if(trade.PositionModify(ticket, sl, 0))
                Print("✓ CALF_A_M: Opened #", ticket, " + SL ODMAH @ ", sl, " (", randomSLPips, " pips)");
            else
                Print("⚠ CALF_A_M: SL FAILED #", ticket, " - will retry!");
        }
        else
            Print("✓ CALF_A_M: Opened #", ticket, " SL=", sl);
        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = sl;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].trailLevel = 0;
        g_positions[g_posCount].maxProfitPoints = 0;
        g_posCount++;
    }
}

void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;
    if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
    {
        ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
        g_pendingTrade.active = false;
    }
}

void ManageStealthPositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;
        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Profit u POINTS
        double profitPoints = (posType == POSITION_TYPE_BUY) ?
                              (currentPrice - g_positions[i].entryPrice) / point :
                              (g_positions[i].entryPrice - currentPrice) / point;

        // Ažuriraj MFE (Maximum Favorable Excursion)
        if(profitPoints > g_positions[i].maxProfitPoints)
            g_positions[i].maxProfitPoints = profitPoints;

        //=== 1. BACKUP SL RETRY ===
        // v2.3: Ako SL nije postavljen, pokušaj ponovo
        if(currentSL == 0 && g_positions[i].intendedSL != 0)
        {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
                Print("✓ CALF_A_M BACKUP: SL RETRY uspješan #", ticket, " @ ", sl);
        }
        // Ako SL još uvijek nije postavljen i gubitak prevelik, zatvori
        if(PositionGetDouble(POSITION_SL) == 0 && profitPoints <= -HardSL_Pips)
        {
            trade.PositionClose(ticket);
            Print("✗ CALF_A_M BACKUP SL CLOSE #", ticket, " | Loss: ", NormalizeDouble(profitPoints, 1), " pips");
            g_positions[i].active = false;
            continue;
        }

        //=== 2. STEALTH TP ===
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("✓ CALF_A_M TP HIT #", ticket, " | Profit: ", NormalizeDouble(profitPoints, 1), " pips");
                g_positions[i].active = false;
                continue;
            }
        }

        //=== 3. LEVEL 1: +500 pips → BE+40 ===
        if(g_positions[i].trailLevel < 1 && profitPoints >= Level1_Pips)
        {
            double newSL = (posType == POSITION_TYPE_BUY) ?
                           g_positions[i].entryPrice + Level1_BEPips * point :
                           g_positions[i].entryPrice - Level1_BEPips * point;
            newSL = NormalizeDouble(newSL, digits);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && (currentSL == 0 || newSL < currentSL));
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_positions[i].trailLevel = 1;
                Print("✓ L1: BE+", Level1_BEPips, " pips #", ticket, " (profit: ", NormalizeDouble(profitPoints, 1), " pips)");
            }
        }

        //=== 4. LEVEL 2: +1000 pips → Lock 300 ===
        if(g_positions[i].trailLevel == 1 && profitPoints >= Level2_Pips)
        {
            double newSL = (posType == POSITION_TYPE_BUY) ?
                           g_positions[i].entryPrice + Level2_LockPips * point :
                           g_positions[i].entryPrice - Level2_LockPips * point;
            newSL = NormalizeDouble(newSL, digits);
            currentSL = PositionGetDouble(POSITION_SL);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_positions[i].trailLevel = 2;
                Print("✓ L2: Lock +", Level2_LockPips, " pips #", ticket, " (profit: ", NormalizeDouble(profitPoints, 1), " pips)");
            }
        }

        //=== 5. LEVEL 3: MFE - 30% (Dinamički trailing) ===
        if(g_positions[i].trailLevel >= 2 && g_positions[i].maxProfitPoints > Level2_Pips)
        {
            double mfeKeep = g_positions[i].maxProfitPoints * (1.0 - Level3_MFEPercent / 100.0);
            double newSL = (posType == POSITION_TYPE_BUY) ?
                           g_positions[i].entryPrice + mfeKeep * point :
                           g_positions[i].entryPrice - mfeKeep * point;
            newSL = NormalizeDouble(newSL, digits);
            currentSL = PositionGetDouble(POSITION_SL);
            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
                g_positions[i].trailLevel = 3;
                Print("✓ L3 MFE: Trail to +", NormalizeDouble(mfeKeep, 1), " pips (MFE=", NormalizeDouble(g_positions[i].maxProfitPoints, 1), ") #", ticket);
            }
        }
    }

    CleanupPositions();
}

void CleanupPositions()
{
    int newCount = 0;
    for(int i = 0; i < g_posCount; i++) { if(g_positions[i].active) { if(i != newCount) g_positions[newCount] = g_positions[i]; newCount++; } }
    if(newCount != g_posCount) { g_posCount = newCount; ArrayResize(g_positions, g_posCount); }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPositions();

    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(g_pendingTrade.active) return;

    //=== NOVI FILTERI ===

    // NEWS FILTER - Izbjegavaj trading oko važnih vijesti
    if(HasActiveNews())
    {
        newsBlockedCount++;
        return;
    }

    // SPREAD FILTER - Izbjegavaj širok spread
    if(IsSpreadTooHigh())
    {
        spreadBlockedCount++;
        return;
    }

    //=== SIGNAL LOGIC ===
    CalculateUTBot();
    bool buySignal = (utPosition[1] == 1 && utPosition[2] == -1);
    bool sellSignal = (utPosition[1] == -1 && utPosition[2] == 1);

    if(buySignal)
    {
        Print("CALF_A_M BUY SIGNAL (Spread=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), ")");
        QueueTrade(ORDER_TYPE_BUY);
    }
    else if(sellSignal)
    {
        Print("CALF_A_M SELL SIGNAL (Spread=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), ")");
        QueueTrade(ORDER_TYPE_SELL);
    }
}
//+------------------------------------------------------------------+
