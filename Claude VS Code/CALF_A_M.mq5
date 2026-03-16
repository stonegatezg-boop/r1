//+------------------------------------------------------------------+
//|                                                    CALF_A_M.mq5  |
//|                        *** CALF A M - UT Bot + Market Protection |
//|                   + Stealth Mode v3.0 CLAUDE.md                  |
//|                   Fixed: 10.03.2026 (Zagreb) - CLAUDE.md STANDARD|
//|                   - SL ODMAH random 988-1054 pips                |
//|                   - Stealth TP (TP=0)                            |
//|                   - BE+ @ 1000 pips (offset 41-46)               |
//|                   - Trailing 1000 pips                           |
//|                   - Friday close 11:00                           |
//+------------------------------------------------------------------+
#property copyright "CALF A M v3.0 CLAUDE.md (2026-03-10)"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== UT BOT POSTAVKE ==="
input double   UTKey            = 2.0;
input int      UTAtrPeriod      = 10;

input group "=== TRADE MANAGEMENT ==="
input double   TPMultiplier     = 3.0;        // TP = ATR x (stealth)
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;
input double   FixedLotSize     = 0.01;       // Fiksni lot size

input group "=== RANDOM SL (CLAUDE.md) ==="
input int      InitialSL_Min    = 988;        // SL min pips (random)
input int      InitialSL_Max    = 1054;       // SL max pips (random)

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input double   LargeCandleATR   = 2.0;        // 2x ATR Large Candle Filter

input group "=== TRAILING (CLAUDE.md STANDARD) ==="
input int      TrailingStartBE  = 1000;       // BE+ aktivacija (pips)
input int      BEOffset_Min     = 41;         // BE+ offset min pips
input int      BEOffset_Max     = 46;         // BE+ offset max pips
input int      TrailingDistance = 1000;       // Trailing udaljenost (pips)

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

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; };
struct StealthPosInfo {
    bool active;
    ulong ticket;
    double intendedSL;          // SL za backup retry
    double stealthTP;           // Stealth Take Profit cijena
    double entryPrice;          // Entry cijena
    datetime openTime;          // Vrijeme otvaranja
    int randomBEOffset;         // BE+ offset (41-46 pips)
    double highestProfit;       // Za trailing
    bool beActivated;           // BE+ aktiviran
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

    Print("=== CALF A M v3.0 (CLAUDE.md) ===");
    Print("SL: Random ", InitialSL_Min, "-", InitialSL_Max, " pips (ODMAH!)");
    Print("TP: Stealth (ATR x ", TPMultiplier, ")");
    Print("BE+: ", BEOffset_Min, "-", BEOffset_Max, " pips @ ", TrailingStartBE, " pips profit");
    Print("Trail: ", TrailingDistance, " pips distance");
    Print("Vrijeme: 0-24, petak stop 11:00");
    Print("NEWS: ", UseNewsFilter ? "ON" : "OFF", " | SPREAD: ", UseSpreadFilter ? "ON" : "OFF", " (", MaxSpreadPoints, "pt)");

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
    // Vikend - ne trejdaj
    if(dt.day_of_week == 0) return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));  // Nedjelja od 00:01
    if(dt.day_of_week == 6) return false;  // Subota
    // Petak - stop novih trejdova u 11:00
    if(dt.day_of_week == 5) return (dt.hour < 11);
    // Pon-Čet: 0-24
    return true;
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
    double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // CLAUDE.md: Random SL 988-1054 pips
    int slPips = RandomRange(InitialSL_Min, InitialSL_Max);
    double slDistance = slPips * pipValue;
    double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
    sl = NormalizeDouble(sl, digits);

    // TP ostaje ATR-based (stealth)
    double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr;
    tp = NormalizeDouble(tp, digits);

    // CLAUDE.md: Otvori ODMAH, nema delay
    g_pendingTrade.active = true;
    g_pendingTrade.type = type;
    g_pendingTrade.lot = FixedLotSize;
    g_pendingTrade.intendedSL = sl;
    g_pendingTrade.intendedTP = tp;
    g_pendingTrade.signalTime = TimeCurrent();

    Print("CALF_A_M: Trade queued, SL=", slPips, " pips ODMAH");
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);
    bool ok;

    // CLAUDE.md: SL ODMAH, TP=0 (stealth)
    ok = (type == ORDER_TYPE_BUY) ?
         trade.Buy(lot, _Symbol, price, sl, 0, "CALF_A_M") :
         trade.Sell(lot, _Symbol, price, sl, 0, "CALF_A_M");

    if(ok)
    {
        ulong ticket = trade.ResultOrder();

        // Random BE+ offset (41-46 pips)
        int beOffset = RandomRange(BEOffset_Min, BEOffset_Max);

        ArrayResize(g_positions, g_posCount + 1);
        g_positions[g_posCount].active = true;
        g_positions[g_posCount].ticket = ticket;
        g_positions[g_posCount].intendedSL = sl;
        g_positions[g_posCount].stealthTP = tp;
        g_positions[g_posCount].entryPrice = price;
        g_positions[g_posCount].openTime = TimeCurrent();
        g_positions[g_posCount].randomBEOffset = beOffset;
        g_positions[g_posCount].highestProfit = 0;
        g_positions[g_posCount].beActivated = false;
        g_posCount++;

        Print("=== CALF_A_M ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " (SL ODMAH) ===");
        Print("Entry: ", price, " | Lots: ", lot);
        Print("SL: ", sl, " ODMAH!");
        Print("TP: ", tp, " STEALTH");
        Print("Trail: BE+", beOffset, " @ ", TrailingStartBE, " pips, trail ", TrailingDistance);
    }
    else
    {
        Print("CALF_A_M ERROR: Trade failed - ", trade.ResultRetcode());
    }
}

void ProcessPendingTrade()
{
    if(!g_pendingTrade.active) return;
    // CLAUDE.md: ODMAH, nema delay
    ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
    g_pendingTrade.active = false;
}

void ManageStealthPositions()
{
    double pipValue = 0.01;  // XAUUSD: 1 pip = 0.01
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

        // Profit u PIPS
        double profitPips = (posType == POSITION_TYPE_BUY) ?
                            (currentPrice - g_positions[i].entryPrice) / pipValue :
                            (g_positions[i].entryPrice - currentPrice) / pipValue;

        // Update highest profit
        if(profitPips > g_positions[i].highestProfit)
            g_positions[i].highestProfit = profitPips;

        //=== 1. BACKUP SL CHECK ===
        if(currentSL == 0 && g_positions[i].intendedSL != 0)
        {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
                Print("CALF_A_M BACKUP [", ticket, "]: SL postavljen na ", sl);
        }

        //=== 2. STEALTH TP ===
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("CALF_A_M TP [", ticket, "]: STEALTH TP HIT @ ", currentPrice);
                g_positions[i].active = false;
                continue;
            }
        }

        //=== 3. CLAUDE.md TRAILING: BE+ at 1000 pips, trail 1000 ===
        // BE+ aktivacija na 1000 pips
        if(!g_positions[i].beActivated && profitPips >= TrailingStartBE)
        {
            double newSL;
            if(posType == POSITION_TYPE_BUY)
            {
                newSL = g_positions[i].entryPrice + g_positions[i].randomBEOffset * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        g_positions[i].beActivated = true;
                        Print("CALF_A_M BE+ [", ticket, "]: SL na BE+", g_positions[i].randomBEOffset, " pips");
                    }
                }
            }
            else
            {
                newSL = g_positions[i].entryPrice - g_positions[i].randomBEOffset * pipValue;
                newSL = NormalizeDouble(newSL, digits);
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        g_positions[i].beActivated = true;
                        Print("CALF_A_M BE+ [", ticket, "]: SL na BE+", g_positions[i].randomBEOffset, " pips");
                    }
                }
            }
        }
        // Trailing nakon BE+ - prati na 1000 pips udaljenosti
        else if(g_positions[i].beActivated && profitPips >= TrailingStartBE)
        {
            double trailPips = g_positions[i].highestProfit - TrailingDistance;
            if(trailPips > g_positions[i].randomBEOffset)  // Samo ako je bolji od BE+
            {
                double newSL;
                if(posType == POSITION_TYPE_BUY)
                {
                    newSL = g_positions[i].entryPrice + trailPips * pipValue;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL > currentSL)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                            Print("CALF_A_M TRAIL [", ticket, "]: SL na +", (int)trailPips, " pips (high: ", (int)g_positions[i].highestProfit, ")");
                    }
                }
                else
                {
                    newSL = g_positions[i].entryPrice - trailPips * pipValue;
                    newSL = NormalizeDouble(newSL, digits);
                    if(newSL < currentSL || currentSL == 0)
                    {
                        if(trade.PositionModify(ticket, newSL, 0))
                            Print("CALF_A_M TRAIL [", ticket, "]: SL na +", (int)trailPips, " pips (high: ", (int)g_positions[i].highestProfit, ")");
                    }
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
