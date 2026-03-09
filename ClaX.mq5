//+------------------------------------------------------------------+
//|                                                        ClaX.mq5  |
//|                        *** ClaX v1.0 ***                         |
//|                   CSV Signal Reader for XAUUSD                   |
//|                   Created: 09.03.2026 (Zagreb)                   |
//+------------------------------------------------------------------+
#property copyright "ClaX v1.0"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== TRADE MANAGEMENT ==="
input double   LotSize          = 0.01;         // Lot Size
input int      SL_Pips          = 1000;         // Stop Loss (pips)
input int      MaxSpread        = 50;           // Max Spread (points)

input group "=== TRAILING STOP ==="
input int      TrailActivatePips = 1000;        // Trailing aktivacija (pips profit)
input int      TrailDistancePips = 1000;        // Trailing distance (pips)

input group "=== CSV SETTINGS ==="
input string   SignalFileName   = "clax_signals.csv";  // Signal file name

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 556688;       // Magic Number
input int      Slippage         = 30;           // Slippage (points)

//--- XAUUSD pip value
const double   PIP_VALUE        = 0.01;         // 1 pip = 0.01 for XAUUSD

//--- Global variables
CTrade         trade;
datetime       lastBarTime      = 0;
datetime       lastSignalTime   = 0;

//--- Struktura za praćenje tradea
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    int      trailLevel;        // 0=none, 1=trailing active
};

TradeData      trades[];
int            tradesCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    ArrayResize(trades, 0);
    tradesCount = 0;

    Print("=== ClaX v1.0 inicijaliziran ===");
    Print("SL: ", SL_Pips, " pips (", SL_Pips * PIP_VALUE, ")");
    Print("Trailing: aktivacija na ", TrailActivatePips, " pips, distance ", TrailDistancePips, " pips");
    Print("Signal file: ", SignalFileName);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("ClaX deinicijaliziran");
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
// Trading Window: Nedjelja 00:01 - Petak 11:30 (server time)
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Nedjelja od 00:01
    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

    // Ponedjeljak - Četvrtak cijeli dan
    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
        return true;

    // Petak do 11:30
    if(dt.day_of_week == 5)
        return (dt.hour < 11 || (dt.hour == 11 && dt.min <= 30));

    return false;
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
void SyncTradesArray()
{
    for(int i = tradesCount - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(trades[i].ticket))
        {
            // Pozicija zatvorena - ukloni iz arraya
            for(int j = i; j < tradesCount - 1; j++)
            {
                trades[j] = trades[j + 1];
            }
            tradesCount--;
            ArrayResize(trades, tradesCount);
        }
    }
}

//+------------------------------------------------------------------+
int FindTradeIndex(ulong ticket)
{
    for(int i = 0; i < tradesCount; i++)
    {
        if(trades[i].ticket == ticket)
            return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double entry)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].trailLevel = 0;
    tradesCount++;
}

//+------------------------------------------------------------------+
double GetProfitPips(ulong ticket, double entryPrice)
{
    if(!PositionSelectByTicket(ticket)) return 0;

    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentPrice;

    if(posType == POSITION_TYPE_BUY)
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        return (currentPrice - entryPrice) / PIP_VALUE;
    }
    else
    {
        currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        return (entryPrice - currentPrice) / PIP_VALUE;
    }
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
    SyncTradesArray();

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL = PositionGetDouble(POSITION_SL);
        double profitPips = GetProfitPips(ticket, trades[i].entryPrice);

        // Trailing aktivacija na TrailActivatePips
        if(profitPips >= TrailActivatePips)
        {
            double newSL;
            double currentPrice;
            double trailDistance = TrailDistancePips * PIP_VALUE;

            if(posType == POSITION_TYPE_BUY)
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                newSL = currentPrice - trailDistance;
                newSL = NormalizeDouble(newSL, digits);

                // Pomakni SL samo ako je novi viši od trenutnog
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        double lockedPips = (newSL - trades[i].entryPrice) / PIP_VALUE;
                        Print("ClaX [", ticket, "] TRAIL: SL -> ", newSL, " (locked +", DoubleToString(lockedPips, 0), " pips)");
                        trades[i].trailLevel = 1;
                    }
                }
            }
            else // SELL
            {
                currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                newSL = currentPrice + trailDistance;
                newSL = NormalizeDouble(newSL, digits);

                // Pomakni SL samo ako je novi niži od trenutnog
                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        double lockedPips = (trades[i].entryPrice - newSL) / PIP_VALUE;
                        Print("ClaX [", ticket, "] TRAIL: SL -> ", newSL, " (locked +", DoubleToString(lockedPips, 0), " pips)");
                        trades[i].trailLevel = 1;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
void ReadSignalFile()
{
    if(!FileIsExist(SignalFileName, FILE_COMMON))
        return;

    int handle = FileOpen(SignalFileName, FILE_READ | FILE_CSV | FILE_COMMON, ',');
    if(handle == INVALID_HANDLE)
        return;

    // Čitaj header
    if(FileIsEnding(handle)) { FileClose(handle); return; }
    FileReadString(handle); // skip header line

    // Čitaj data
    if(FileIsEnding(handle)) { FileClose(handle); return; }

    string timestamp = FileReadString(handle);
    string action = FileReadString(handle);

    FileClose(handle);

    // Provjeri da li je nova odluka
    datetime signalTime = StringToTime(timestamp);
    if(signalTime <= lastSignalTime)
        return;

    lastSignalTime = signalTime;

    Print("ClaX Signal: ", action, " @ ", timestamp);

    // Obriši file
    FileDelete(SignalFileName, FILE_COMMON);

    // Provjere prije izvršenja
    if(!IsTradingWindow())
    {
        Print("ClaX: Outside trading window");
        return;
    }

    if(!CheckSpread())
    {
        Print("ClaX: Spread too high");
        return;
    }

    if(HasOpenPosition() && action != "CLOSE")
    {
        Print("ClaX: Already has open position");
        return;
    }

    // Izvršenje
    ExecuteSignal(action);
}

//+------------------------------------------------------------------+
void ExecuteSignal(string action)
{
    double price;
    double sl;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double slDistance = SL_Pips * PIP_VALUE;  // 1000 pips = 10.00

    if(action == "BUY")
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = NormalizeDouble(price - slDistance, digits);

        // PRAVI SL ODMAH pri otvaranju (stealth TP = 0)
        if(trade.Buy(LotSize, _Symbol, price, sl, 0, "ClaX BUY"))
        {
            ulong ticket = trade.ResultOrder();
            AddTrade(ticket, price);
            Print("ClaX BUY [", ticket, "]: ", LotSize, " @ ", price, " SL=", sl);
        }
    }
    else if(action == "SELL")
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = NormalizeDouble(price + slDistance, digits);

        // PRAVI SL ODMAH pri otvaranju (stealth TP = 0)
        if(trade.Sell(LotSize, _Symbol, price, sl, 0, "ClaX SELL"))
        {
            ulong ticket = trade.ResultOrder();
            AddTrade(ticket, price);
            Print("ClaX SELL [", ticket, "]: ", LotSize, " @ ", price, " SL=", sl);
        }
    }
    else if(action == "CLOSE")
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket))
            {
                if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                   PositionGetString(POSITION_SYMBOL) == _Symbol)
                {
                    trade.PositionClose(ticket);
                    Print("ClaX: Position closed");
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    // Uvijek upravljaj trailing stopom (svaki tick)
    ManageTrailing();

    // Čitaj signal file
    ReadSignalFile();
}
//+------------------------------------------------------------------+
