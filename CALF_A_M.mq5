//+------------------------------------------------------------------+
//|                                                    CALF_A_M.mq5  |
//|                        *** CALF A M - UT Bot + Market Protection |
//|                   + Stealth Mode v2.1                            |
//|                   + NEWS FILTER & SPREAD FILTER                  |
//|                   Based on CALF_A with Market Protection         |
//|                   Version 1.0 - 2026-02-23                       |
//|                   Fixed: 03.03.2026 - Nova USD Risk Logika       |
//|                   Hard SL: -8 USD, Trail: 10 USD aktivacija      |
//|                   MFE tracking, lock profit = MFE - 5 USD        |
//+------------------------------------------------------------------+
#property copyright "CALF A M - UT Bot + Market Protected (2026-02-23)"
#property version   "1.00"
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
input int      SLDelayMin       = 7;
input int      SLDelayMax       = 13;
input double   LargeCandleATR   = 3.0;

input group "=== RISK MANAGEMENT (PIPS) ==="
input int      HardSL_Pips           = 800;    // Hard Stop Loss (800 pips = 8 USD za 0.01 lot)
input int      TrailActivation_Pips  = 1000;   // Trailing aktivacija (1000 pips = 10 USD)
input int      TrailDistance_Pips    = 500;    // Trailing udaljenost (500 pips = 5 USD)
input double   FixedLotSize          = 0.01;   // Fiksni lot size

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
// MFE = Maximum Favorable Excursion (najviši dosegnuti profit)
struct StealthPosInfo {
    bool active;
    ulong ticket;
    double stealthTP;           // Stealth Take Profit cijena
    double entryPrice;          // Entry cijena
    datetime openTime;          // Vrijeme otvaranja
    double maxProfit;           // MFE tracking - najviši dosegnuti profit (USD)
    bool trailActive;           // Je li trailing aktiviran
    double lockedProfitPrice;   // Trenutna SL cijena iz trailing-a
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
    Print("║       CALF A M v1.1 - USD RISK LOGIC                     ║");
    Print("╠══════════════════════════════════════════════════════════╣");
    Print("║ UT Bot Strategy + Stealth Mode");
    Print("║ HARD SL: -", HardSL_Pips, " pips (", HardSL_Pips/100.0, " USD za 0.01 lot)");
    Print("║ TRAIL ACTIVATION: ", TrailActivation_Pips, " pips (", TrailActivation_Pips/100.0, " USD)");
    Print("║ TRAIL DISTANCE: ", TrailDistance_Pips, " pips (", TrailDistance_Pips/100.0, " USD)");
    Print("║ NEWS FILTER: ", UseNewsFilter ? "ON" : "OFF", " | SPREAD FILTER: ", UseSpreadFilter ? "ON" : "OFF");
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
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // TP ostaje ATR-based (stealth)
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
    // SL se NE šalje brokeru - koristimo Hard SL u USD

    if(UseStealthMode)
    {
        g_pendingTrade.active = true;
        g_pendingTrade.type = type;
        g_pendingTrade.lot = FixedLotSize;
        g_pendingTrade.intendedSL = 0;  // Nema broker SL - koristimo USD hard SL
        g_pendingTrade.intendedTP = tp;
        g_pendingTrade.signalTime = TimeCurrent();
        g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
        Print("CALF_A_M: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
    }
    else
    {
        ExecuteTrade(type, FixedLotSize, 0, tp);
    }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    tp = NormalizeDouble(tp, digits);
    bool ok;

    // STEALTH: Ne šaljemo SL brokeru - koristimo USD Hard SL
    if(UseStealthMode)
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_A_M") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_A_M");
    else
        ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, tp, "CALF_A_M BUY") : trade.Sell(lot, _Symbol, price, 0, tp, "CALF_A_M SELL");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].maxProfit = 0;           // MFE starts at 0
        g_positions[g_posCount].trailActive = false;     // Trailing not yet active
        g_positions[g_posCount].lockedProfitPrice = 0;   // No locked profit yet
        g_posCount++;
        Print("✓ CALF_A_M: Opened #", ticket, " @ ", price, " | Hard SL: -", HardSL_Pips, " pips | Trail: ", TrailActivation_Pips, "/", TrailDistance_Pips, " pips");
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
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Izračunaj trenutni profit u PIPS
        double profitPips = (posType == POSITION_TYPE_BUY) ?
                            (currentPrice - g_positions[i].entryPrice) / point :
                            (g_positions[i].entryPrice - currentPrice) / point;

        //=================================================================
        // 1. HARD STOP LOSS (-800 pips = -8 USD za 0.01 lot)
        //    Zatvori poziciju odmah ako loss premaši HardSL_Pips
        //=================================================================
        if(profitPips <= -HardSL_Pips)
        {
            trade.PositionClose(ticket);
            Print("✗ CALF_A_M HARD SL HIT #", ticket, " | Loss: ", DoubleToString(profitPips, 0), " pips");
            g_positions[i].active = false;
            continue;
        }

        //=================================================================
        // 2. STEALTH TP - Zatvori ako cijena dotakne TP
        //=================================================================
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("✓ CALF_A_M TP HIT #", ticket, " | Profit: ", DoubleToString(profitPips, 0), " pips");
                g_positions[i].active = false;
                continue;
            }
        }

        //=================================================================
        // 3. MFE TRACKING - Prati najviši dosegnuti profit
        //=================================================================
        if(profitPips > g_positions[i].maxProfit)
        {
            g_positions[i].maxProfit = profitPips;
        }

        //=================================================================
        // 4. TRAILING STOP (aktivacija na 1000 pips, udaljenost 500 pips)
        //    - Aktivira se SAMO kada profit >= TrailActivation_Pips
        //    - Lock profit = MFE - TrailDistance_Pips
        //    - SL se NIKAD ne vraća nazad
        //=================================================================
        if(g_positions[i].maxProfit >= TrailActivation_Pips)
        {
            // Izračunaj lock level: MFE - 500 pips
            double lockPips = g_positions[i].maxProfit - TrailDistance_Pips;

            // Izračunaj novu SL cijenu
            double newSLPrice;
            if(posType == POSITION_TYPE_BUY)
                newSLPrice = g_positions[i].entryPrice + lockPips * point;
            else
                newSLPrice = g_positions[i].entryPrice - lockPips * point;

            newSLPrice = NormalizeDouble(newSLPrice, digits);

            // Provjeri treba li pomaknuti SL (samo naprijed, nikad nazad)
            bool shouldMove = false;
            if(g_positions[i].lockedProfitPrice == 0)
            {
                shouldMove = true;  // Prvi put postavljamo trailing SL
            }
            else
            {
                // SL se pomiče samo ako je novi SL bolji
                if(posType == POSITION_TYPE_BUY && newSLPrice > g_positions[i].lockedProfitPrice)
                    shouldMove = true;
                else if(posType == POSITION_TYPE_SELL && newSLPrice < g_positions[i].lockedProfitPrice)
                    shouldMove = true;
            }

            if(shouldMove)
            {
                // STEALTH: NE šaljemo pravi SL brokeru - pratimo interno
                // Ako cijena padne ispod lockPips, zatvaramo poziciju
                g_positions[i].lockedProfitPrice = newSLPrice;

                if(!g_positions[i].trailActive)
                {
                    g_positions[i].trailActive = true;
                    Print("▶ CALF_A_M TRAIL ACTIVATED #", ticket,
                          " | MFE: ", DoubleToString(g_positions[i].maxProfit, 0), " pips",
                          " | Lock: +", DoubleToString(lockPips, 0), " pips");
                }
                else
                {
                    Print("▶ CALF_A_M TRAIL UPDATE #", ticket,
                          " | MFE: ", DoubleToString(g_positions[i].maxProfit, 0), " pips",
                          " | Lock: +", DoubleToString(lockPips, 0), " pips");
                }
            }

            // Provjeri je li cijena pala ispod locked profita (trailing SL hit)
            if(g_positions[i].trailActive && g_positions[i].lockedProfitPrice > 0)
            {
                bool trailSLHit = false;
                if(posType == POSITION_TYPE_BUY && currentPrice <= g_positions[i].lockedProfitPrice)
                    trailSLHit = true;
                else if(posType == POSITION_TYPE_SELL && currentPrice >= g_positions[i].lockedProfitPrice)
                    trailSLHit = true;

                if(trailSLHit)
                {
                    trade.PositionClose(ticket);
                    double lockedPips = (posType == POSITION_TYPE_BUY) ?
                                        (g_positions[i].lockedProfitPrice - g_positions[i].entryPrice) / point :
                                        (g_positions[i].entryPrice - g_positions[i].lockedProfitPrice) / point;
                    Print("✓ CALF_A_M TRAIL SL HIT #", ticket,
                          " | Locked: +", DoubleToString(lockedPips, 0), " pips",
                          " | MFE was: ", DoubleToString(g_positions[i].maxProfit, 0), " pips");
                    g_positions[i].active = false;
                    continue;
                }
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
