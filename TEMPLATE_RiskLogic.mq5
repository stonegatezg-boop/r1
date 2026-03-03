//+------------------------------------------------------------------+
//|                                          TEMPLATE_RiskLogic.mq5  |
//|                   TEMPLATE - Nova USD/PIP Risk Logika            |
//|                   Created: 03.03.2026 (Zagreb)                   |
//|                                                                  |
//|   OVAJ TEMPLATE SADRZI SAMO RISK MANAGEMENT LOGIKU:              |
//|   - Hard SL (800 pips)                                           |
//|   - MFE Tracking                                                 |
//|   - Trailing Stop (1000/500 pips)                                |
//|                                                                  |
//|   ENTRY LOGIKA NIJE UKLJUČENA - DODAJ SVOJU!                     |
//+------------------------------------------------------------------+
#property copyright "Risk Logic Template v1.0"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS - RISK MANAGEMENT                               |
//+------------------------------------------------------------------+
input group "=== RISK MANAGEMENT (PIPS) ==="
input int      HardSL_Pips           = 800;    // Hard Stop Loss (800 pips)
input int      TrailActivation_Pips  = 1000;   // Trailing aktivacija (1000 pips)
input int      TrailDistance_Pips    = 500;    // Trailing udaljenost (500 pips)
input double   FixedLotSize          = 0.01;   // Fiksni lot size

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode        = true;   // Stealth mode (ne šalje SL brokeru)

input group "=== OPCE ==="
input ulong    MagicNumber           = 123456; // PROMIJENI ZA SVAKI EA!
input int      Slippage              = 30;

//+------------------------------------------------------------------+
//| STRUCTURE - Position tracking with MFE                           |
//+------------------------------------------------------------------+
struct PositionInfo {
    bool active;                // Je li pozicija aktivna
    ulong ticket;               // Ticket broj
    double stealthTP;           // Stealth Take Profit cijena
    double entryPrice;          // Entry cijena
    datetime openTime;          // Vrijeme otvaranja
    double maxProfit;           // MFE - Maximum Favorable Excursion (pips)
    bool trailActive;           // Je li trailing aktiviran
    double lockedProfitPrice;   // Locked SL cijena iz trailing-a
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade trade;
PositionInfo g_positions[];
int g_posCount = 0;

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    ArrayResize(g_positions, 0);
    g_posCount = 0;

    Print("╔══════════════════════════════════════════════════════════╗");
    Print("║           RISK LOGIC TEMPLATE v1.0                       ║");
    Print("╠══════════════════════════════════════════════════════════╣");
    Print("║ HARD SL: -", HardSL_Pips, " pips");
    Print("║ TRAIL ACTIVATION: ", TrailActivation_Pips, " pips");
    Print("║ TRAIL DISTANCE: ", TrailDistance_Pips, " pips");
    Print("║ STEALTH MODE: ", UseStealthMode ? "ON" : "OFF");
    Print("╚══════════════════════════════════════════════════════════╝");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE - Otvori poziciju                                  |
//| Pozovi ovu funkciju kada dobijes signal za ulaz                  |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double tp)
{
    double price = (type == ORDER_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    tp = NormalizeDouble(tp, digits);

    bool ok;

    // STEALTH: Ne saljemo SL brokeru - koristimo interni Hard SL
    if(UseStealthMode)
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(FixedLotSize, _Symbol, price, 0, 0, "STEALTH") :
             trade.Sell(FixedLotSize, _Symbol, price, 0, 0, "STEALTH");
    else
        ok = (type == ORDER_TYPE_BUY) ?
             trade.Buy(FixedLotSize, _Symbol, price, 0, tp, "BUY") :
             trade.Sell(FixedLotSize, _Symbol, price, 0, tp, "SELL");

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
        g_positions[g_posCount].trailActive = false;     // Trailing not active yet
        g_positions[g_posCount].lockedProfitPrice = 0;   // No locked profit yet
        g_posCount++;

        Print("OPENED #", ticket, " @ ", price,
              " | Hard SL: -", HardSL_Pips, " pips",
              " | Trail: ", TrailActivation_Pips, "/", TrailDistance_Pips, " pips");
    }
}

//+------------------------------------------------------------------+
//| MANAGE POSITIONS - Pozovi svaki tick!                            |
//| Ova funkcija upravlja Hard SL, TP i Trailing                     |
//+------------------------------------------------------------------+
void ManagePositions()
{
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for(int i = g_posCount - 1; i >= 0; i--)
    {
        if(!g_positions[i].active) continue;

        ulong ticket = g_positions[i].ticket;
        if(!PositionSelectByTicket(ticket))
        {
            g_positions[i].active = false;
            continue;
        }

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Izracunaj trenutni profit u PIPS
        double profitPips = (posType == POSITION_TYPE_BUY) ?
                            (currentPrice - g_positions[i].entryPrice) / point :
                            (g_positions[i].entryPrice - currentPrice) / point;

        //=============================================================
        // 1. HARD STOP LOSS
        //    Zatvori poziciju odmah ako loss premasi HardSL_Pips
        //=============================================================
        if(profitPips <= -HardSL_Pips)
        {
            trade.PositionClose(ticket);
            Print("HARD SL HIT #", ticket, " | Loss: ", DoubleToString(profitPips, 0), " pips");
            g_positions[i].active = false;
            continue;
        }

        //=============================================================
        // 2. STEALTH TP
        //    Zatvori ako cijena dotakne TP
        //=============================================================
        if(g_positions[i].stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                         (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print("TP HIT #", ticket, " | Profit: ", DoubleToString(profitPips, 0), " pips");
                g_positions[i].active = false;
                continue;
            }
        }

        //=============================================================
        // 3. MFE TRACKING
        //    Prati najvisi dosegnuti profit
        //=============================================================
        if(profitPips > g_positions[i].maxProfit)
        {
            g_positions[i].maxProfit = profitPips;
        }

        //=============================================================
        // 4. TRAILING STOP
        //    - Aktivira se SAMO kada profit >= TrailActivation_Pips
        //    - Lock profit = MFE - TrailDistance_Pips
        //    - SL se NIKAD ne vraca nazad
        //=============================================================
        if(g_positions[i].maxProfit >= TrailActivation_Pips)
        {
            // Izracunaj lock level: MFE - TrailDistance
            double lockPips = g_positions[i].maxProfit - TrailDistance_Pips;

            // Izracunaj novu SL cijenu
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
                if(posType == POSITION_TYPE_BUY && newSLPrice > g_positions[i].lockedProfitPrice)
                    shouldMove = true;
                else if(posType == POSITION_TYPE_SELL && newSLPrice < g_positions[i].lockedProfitPrice)
                    shouldMove = true;
            }

            if(shouldMove)
            {
                g_positions[i].lockedProfitPrice = newSLPrice;

                if(!g_positions[i].trailActive)
                {
                    g_positions[i].trailActive = true;
                    Print("TRAIL ACTIVATED #", ticket,
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
                    Print("TRAIL SL HIT #", ticket,
                          " | Locked: +", DoubleToString(lockedPips, 0), " pips",
                          " | MFE was: ", DoubleToString(g_positions[i].maxProfit, 0), " pips");
                    g_positions[i].active = false;
                    continue;
                }
            }
        }
    }

    // Cleanup inactive positions
    CleanupPositions();
}

//+------------------------------------------------------------------+
//| CLEANUP - Ukloni neaktivne pozicije iz arraya                    |
//+------------------------------------------------------------------+
void CleanupPositions()
{
    int newCount = 0;
    for(int i = 0; i < g_posCount; i++)
    {
        if(g_positions[i].active)
        {
            if(i != newCount)
                g_positions[newCount] = g_positions[i];
            newCount++;
        }
    }
    if(newCount != g_posCount)
    {
        g_posCount = newCount;
        ArrayResize(g_positions, g_posCount);
    }
}

//+------------------------------------------------------------------+
//| HAS OPEN POSITION - Provjeri ima li otvorenih pozicija           |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| ON TICK - PRIMJER UPOTREBE                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    // OBAVEZNO: Pozovi ManagePositions() svaki tick!
    ManagePositions();

    // TVOJA ENTRY LOGIKA IDE OVDJE:
    // if(BuySignal && !HasOpenPosition())
    // {
    //     double tp = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + 1000 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    //     ExecuteTrade(ORDER_TYPE_BUY, tp);
    // }
    // if(SellSignal && !HasOpenPosition())
    // {
    //     double tp = SymbolInfoDouble(_Symbol, SYMBOL_BID) - 1000 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    //     ExecuteTrade(ORDER_TYPE_SELL, tp);
    // }
}
//+------------------------------------------------------------------+
