//+------------------------------------------------------------------+
//|                                                        ClaX.mq5  |
//|                        *** ClaX v2.0 ***                         |
//|              Original Algorithm - No Standard Indicators          |
//|                   Created: 09.03.2026 15:00 (Zagreb)              |
//+------------------------------------------------------------------+
//| VLASTITI ALGORITAM - NEMA RSI, MACD, EMA, itd.                   |
//|                                                                    |
//| 1. PVI (Price Velocity Index) - brzina promjene cijene           |
//| 2. WDR (Wick Dominance Ratio) - omjer sjena = sentiment          |
//| 3. BMS (Body Momentum Score) - kumulativni momentum tijela       |
//| 4. RCF (Range Compression Factor) - sužavanje prije eksplozije   |
//| 5. VSR (Velocity Shift Reversal) - promjena smjera brzine        |
//+------------------------------------------------------------------+
#property copyright "ClaX v2.0 - Original Algorithm"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== ALGORITAM POSTAVKE ==="
input int      PVI_Period        = 8;            // Price Velocity Index period
input int      WDR_Period        = 12;           // Wick Dominance Ratio period
input int      BMS_Period        = 10;           // Body Momentum Score period
input int      RCF_ShortPeriod   = 5;            // Range Compression - kratki period
input int      RCF_LongPeriod    = 20;           // Range Compression - dugi period
input double   RCF_Threshold     = 0.65;         // Compression threshold (ispod = sužavanje)
input double   WDR_BuyThreshold  = 1.3;          // WDR za BUY (dominacija donjih sjena)
input double   WDR_SellThreshold = 0.7;          // WDR za SELL (dominacija gornjih sjena)
input double   BMS_Threshold     = 2.5;          // Minimalni Body Momentum Score
input double   PVI_Threshold     = 0.3;          // Minimalni Price Velocity (u pips/bar)

input group "=== TRADE MANAGEMENT ==="
input double   LotSize           = 0.01;         // Lot Size
input int      SL_Pips           = 800;          // Stop Loss (pips)
input int      MaxSpread         = 50;           // Max Spread (points)

input group "=== 3 TARGETS ==="
input int      Target1_Pips      = 300;          // Target 1 (33% close)
input int      Target2_Pips      = 500;          // Target 2 (50% close)
input int      Target3_Pips      = 800;          // Target 3 (close all)

input group "=== 2-LEVEL TRAILING ==="
input int      TrailStart1_Pips  = 500;          // Level 1: Move to BE + buffer
input int      TrailBuffer1_Pips = 40;           // Level 1: BE + this many pips
input int      TrailStart2_Pips  = 800;          // Level 2: Lock profit
input int      TrailLock2_Pips   = 180;          // Level 2: Lock this many pips

input group "=== FILTER ==="
input int      MinBarsAfterTrade = 3;            // Min barova između trejdova
input bool     UseRCF_Filter     = true;         // Koristi Range Compression Filter

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber       = 556688;       // Magic Number
input int      Slippage          = 30;           // Slippage (points)

//--- XAUUSD pip value
const double   PIP_VALUE         = 0.01;         // 1 pip = 0.01 for XAUUSD

//--- Global variables
CTrade         trade;
datetime       lastBarTime       = 0;
datetime       lastTradeBar      = 0;
int            barsSinceLastTrade = 999;

//--- Struktura za praćenje tradea
struct TradeData
{
    ulong    ticket;
    double   entryPrice;
    double   originalLot;
    int      targetHit;         // 0=none, 1=T1, 2=T2, 3=T3
    int      trailLevel;        // 0=none, 1=BE, 2=lock profit
};

TradeData      trades[];
int            tradesCount = 0;

//+------------------------------------------------------------------+
//| VLASTITI INDIKATOR 1: Price Velocity Index (PVI)                 |
//| Mjeri brzinu promjene cijene u pips po baru                      |
//+------------------------------------------------------------------+
double CalculatePVI()
{
    if(Bars(_Symbol, PERIOD_CURRENT) < PVI_Period + 1) return 0;

    double close0 = iClose(_Symbol, PERIOD_CURRENT, 1);  // Zadnji zatvoreni
    double closeN = iClose(_Symbol, PERIOD_CURRENT, PVI_Period);

    // Velocity = promjena cijene / broj barova (u pips)
    double velocity = (close0 - closeN) / PIP_VALUE / PVI_Period;

    return velocity;
}

//+------------------------------------------------------------------+
//| VLASTITI INDIKATOR 2: Wick Dominance Ratio (WDR)                 |
//| Mjeri dominaciju donjih vs gornjih sjena                         |
//| WDR > 1 = kupci apsorbiraju pritisak (bullish)                   |
//| WDR < 1 = prodavači dominiraju (bearish)                         |
//+------------------------------------------------------------------+
double CalculateWDR()
{
    if(Bars(_Symbol, PERIOD_CURRENT) < WDR_Period + 1) return 1.0;

    double upperWicks = 0;
    double lowerWicks = 0;

    for(int i = 1; i <= WDR_Period; i++)
    {
        double high = iHigh(_Symbol, PERIOD_CURRENT, i);
        double low = iLow(_Symbol, PERIOD_CURRENT, i);
        double open = iOpen(_Symbol, PERIOD_CURRENT, i);
        double close = iClose(_Symbol, PERIOD_CURRENT, i);

        double body_top = MathMax(open, close);
        double body_bottom = MathMin(open, close);

        upperWicks += (high - body_top);
        lowerWicks += (body_bottom - low);
    }

    // Izbjegni dijeljenje s nulom
    if(upperWicks < 0.0001) upperWicks = 0.0001;
    if(lowerWicks < 0.0001) lowerWicks = 0.0001;

    // WDR = donje sjene / gornje sjene
    // > 1 znači da kupci apsorbiraju selling pressure
    return lowerWicks / upperWicks;
}

//+------------------------------------------------------------------+
//| VLASTITI INDIKATOR 3: Body Momentum Score (BMS)                  |
//| Kumulativni momentum tijela svijeća                              |
//| Veća tijela imaju veću težinu                                    |
//+------------------------------------------------------------------+
double CalculateBMS()
{
    if(Bars(_Symbol, PERIOD_CURRENT) < BMS_Period + 1) return 0;

    // Izračunaj prosječnu veličinu tijela za normalizaciju
    double avgBody = 0;
    for(int i = 1; i <= BMS_Period; i++)
    {
        double open = iOpen(_Symbol, PERIOD_CURRENT, i);
        double close = iClose(_Symbol, PERIOD_CURRENT, i);
        avgBody += MathAbs(close - open);
    }
    avgBody /= BMS_Period;
    if(avgBody < 0.01) avgBody = 0.01;  // min za XAUUSD

    double momentum = 0;

    for(int i = 1; i <= BMS_Period; i++)
    {
        double open = iOpen(_Symbol, PERIOD_CURRENT, i);
        double close = iClose(_Symbol, PERIOD_CURRENT, i);
        double body = close - open;  // Pozitivno = bullish, negativno = bearish

        // Težina = veličina tijela relativno na prosječno
        double weight = MathAbs(body) / avgBody;

        // Noviji barovi imaju veću težinu
        double timeWeight = (double)(BMS_Period - i + 1) / BMS_Period;

        if(body > 0)
            momentum += weight * timeWeight;  // Bullish
        else
            momentum -= weight * timeWeight;  // Bearish
    }

    return momentum;
}

//+------------------------------------------------------------------+
//| VLASTITI INDIKATOR 4: Range Compression Factor (RCF)             |
//| Detektira sužavanje raspona prije eksplozivnog pokreta           |
//| RCF < threshold = range se sužava = priprema za breakout         |
//+------------------------------------------------------------------+
double CalculateRCF()
{
    if(Bars(_Symbol, PERIOD_CURRENT) < RCF_LongPeriod + 1) return 1.0;

    // Kratki period - prosječni range
    double shortRange = 0;
    for(int i = 1; i <= RCF_ShortPeriod; i++)
    {
        shortRange += iHigh(_Symbol, PERIOD_CURRENT, i) - iLow(_Symbol, PERIOD_CURRENT, i);
    }
    shortRange /= RCF_ShortPeriod;

    // Dugi period - prosječni range
    double longRange = 0;
    for(int i = 1; i <= RCF_LongPeriod; i++)
    {
        longRange += iHigh(_Symbol, PERIOD_CURRENT, i) - iLow(_Symbol, PERIOD_CURRENT, i);
    }
    longRange /= RCF_LongPeriod;

    if(longRange < 0.01) longRange = 0.01;

    // RCF = kratki / dugi
    // < 1 znači da se range sužava
    return shortRange / longRange;
}

//+------------------------------------------------------------------+
//| VLASTITI INDIKATOR 5: Velocity Shift Detection (VSD)             |
//| Detektira promjenu smjera brzine (akceleracija)                  |
//+------------------------------------------------------------------+
int DetectVelocityShift()
{
    if(Bars(_Symbol, PERIOD_CURRENT) < PVI_Period * 2 + 2) return 0;

    // Brzina u zadnjem periodu
    double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    double closeM = iClose(_Symbol, PERIOD_CURRENT, PVI_Period);
    double velocity1 = (close1 - closeM) / PVI_Period;

    // Brzina u prethodnom periodu
    double closeM1 = iClose(_Symbol, PERIOD_CURRENT, PVI_Period + 1);
    double closeM2 = iClose(_Symbol, PERIOD_CURRENT, PVI_Period * 2);
    double velocity2 = (closeM1 - closeM2) / PVI_Period;

    // Akceleracija = promjena brzine
    double acceleration = velocity1 - velocity2;

    // Detektuj shift
    if(velocity2 < 0 && velocity1 > 0 && acceleration > PVI_VALUE * PVI_Threshold)
        return 1;   // Shift u bullish
    if(velocity2 > 0 && velocity1 < 0 && acceleration < -PVI_VALUE * PVI_Threshold)
        return -1;  // Shift u bearish

    return 0;  // Nema shifta
}

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    ArrayResize(trades, 0);
    tradesCount = 0;

    Print("=== ClaX v2.0 - Original Algorithm ===");
    Print("PVI Period: ", PVI_Period);
    Print("WDR Period: ", WDR_Period, " | BUY threshold: ", WDR_BuyThreshold, " | SELL threshold: ", WDR_SellThreshold);
    Print("BMS Period: ", BMS_Period, " | Threshold: ", BMS_Threshold);
    Print("RCF: ", RCF_ShortPeriod, "/", RCF_LongPeriod, " | Threshold: ", RCF_Threshold);
    Print("SL: ", SL_Pips, " pips | Targets: ", Target1_Pips, "/", Target2_Pips, "/", Target3_Pips);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("ClaX v2.0 deinicijaliziran");
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        barsSinceLastTrade++;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.day_of_week == 0)
        return (dt.hour > 0 || (dt.hour == 0 && dt.min >= 1));

    if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
        return true;

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
void AddTrade(ulong ticket, double entry, double lot)
{
    ArrayResize(trades, tradesCount + 1);
    trades[tradesCount].ticket = ticket;
    trades[tradesCount].entryPrice = entry;
    trades[tradesCount].originalLot = lot;
    trades[tradesCount].targetHit = 0;
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
void ManageTargets()
{
    SyncTradesArray();

    for(int i = tradesCount - 1; i >= 0; i--)
    {
        ulong ticket = trades[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        double profitPips = GetProfitPips(ticket, trades[i].entryPrice);
        double currentLot = PositionGetDouble(POSITION_VOLUME);

        // Target 3 - zatvori sve (stealth TP)
        if(profitPips >= Target3_Pips && trades[i].targetHit < 3)
        {
            trade.PositionClose(ticket);
            Print("ClaX [", ticket, "] TARGET 3 HIT! Closed at +", DoubleToString(profitPips, 0), " pips");
            continue;
        }

        // Target 2 - zatvori 50% preostalog
        if(profitPips >= Target2_Pips && trades[i].targetHit < 2)
        {
            double closeLot = NormalizeDouble(currentLot * 0.5, 2);
            if(closeLot >= 0.01)
            {
                trade.PositionClosePartial(ticket, closeLot);
                Print("ClaX [", ticket, "] TARGET 2: Closed ", closeLot, " lots at +", DoubleToString(profitPips, 0), " pips");
            }
            trades[i].targetHit = 2;
        }
        // Target 1 - zatvori 33%
        else if(profitPips >= Target1_Pips && trades[i].targetHit < 1)
        {
            double closeLot = NormalizeDouble(trades[i].originalLot * 0.33, 2);
            if(closeLot >= 0.01)
            {
                trade.PositionClosePartial(ticket, closeLot);
                Print("ClaX [", ticket, "] TARGET 1: Closed ", closeLot, " lots at +", DoubleToString(profitPips, 0), " pips");
            }
            trades[i].targetHit = 1;
        }
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

        // Level 2: Lock profit (800+ pips)
        if(profitPips >= TrailStart2_Pips && trades[i].trailLevel < 2)
        {
            double newSL;
            double lockDistance = TrailLock2_Pips * PIP_VALUE;

            if(posType == POSITION_TYPE_BUY)
            {
                newSL = trades[i].entryPrice + lockDistance;
                newSL = NormalizeDouble(newSL, digits);

                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        Print("ClaX [", ticket, "] TRAIL L2: Locked +", TrailLock2_Pips, " pips");
                        trades[i].trailLevel = 2;
                    }
                }
            }
            else
            {
                newSL = trades[i].entryPrice - lockDistance;
                newSL = NormalizeDouble(newSL, digits);

                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        Print("ClaX [", ticket, "] TRAIL L2: Locked +", TrailLock2_Pips, " pips");
                        trades[i].trailLevel = 2;
                    }
                }
            }
        }
        // Level 1: Move to BE + buffer (500+ pips)
        else if(profitPips >= TrailStart1_Pips && trades[i].trailLevel < 1)
        {
            double newSL;
            double bufferDistance = TrailBuffer1_Pips * PIP_VALUE;

            if(posType == POSITION_TYPE_BUY)
            {
                newSL = trades[i].entryPrice + bufferDistance;
                newSL = NormalizeDouble(newSL, digits);

                if(newSL > currentSL)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        Print("ClaX [", ticket, "] TRAIL L1: BE +", TrailBuffer1_Pips, " pips");
                        trades[i].trailLevel = 1;
                    }
                }
            }
            else
            {
                newSL = trades[i].entryPrice - bufferDistance;
                newSL = NormalizeDouble(newSL, digits);

                if(newSL < currentSL || currentSL == 0)
                {
                    if(trade.PositionModify(ticket, newSL, 0))
                    {
                        Print("ClaX [", ticket, "] TRAIL L1: BE +", TrailBuffer1_Pips, " pips");
                        trades[i].trailLevel = 1;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| GLAVNI SIGNAL GENERATOR - Vlastiti algoritam                     |
//+------------------------------------------------------------------+
int GenerateSignal()
{
    // Izračunaj sve vlastite indikatore
    double pvi = CalculatePVI();
    double wdr = CalculateWDR();
    double bms = CalculateBMS();
    double rcf = CalculateRCF();
    int vsd = DetectVelocityShift();

    // Debug info
    static datetime lastDebug = 0;
    if(TimeCurrent() - lastDebug > 300)  // Svakih 5 minuta
    {
        Print("ClaX Indicators: PVI=", DoubleToString(pvi, 2),
              " | WDR=", DoubleToString(wdr, 2),
              " | BMS=", DoubleToString(bms, 2),
              " | RCF=", DoubleToString(rcf, 2),
              " | VSD=", vsd);
        lastDebug = TimeCurrent();
    }

    // RCF filter - treba kompresija za bolji signal
    bool compressionOK = true;
    if(UseRCF_Filter)
    {
        compressionOK = (rcf < RCF_Threshold);
    }

    //--------------------------------------------------------------
    // BUY SIGNAL
    //--------------------------------------------------------------
    // 1. WDR > threshold (kupci apsorbiraju selling pressure)
    // 2. BMS > threshold (bullish momentum)
    // 3. PVI > 0 (cijena se kreće gore)
    // 4. VSD = 1 (velocity shift u bullish) ILI jake vrijednosti ostalih
    //--------------------------------------------------------------
    if(wdr > WDR_BuyThreshold && bms > BMS_Threshold && pvi > PVI_Threshold * PIP_VALUE)
    {
        if(compressionOK || vsd == 1)
        {
            Print("ClaX BUY SIGNAL: WDR=", DoubleToString(wdr, 2),
                  " BMS=", DoubleToString(bms, 2),
                  " PVI=", DoubleToString(pvi/PIP_VALUE, 1), " pips/bar");
            return 1;  // BUY
        }
    }

    //--------------------------------------------------------------
    // SELL SIGNAL
    //--------------------------------------------------------------
    // 1. WDR < threshold (prodavači dominiraju)
    // 2. BMS < -threshold (bearish momentum)
    // 3. PVI < 0 (cijena se kreće dolje)
    // 4. VSD = -1 (velocity shift u bearish) ILI jake vrijednosti ostalih
    //--------------------------------------------------------------
    if(wdr < WDR_SellThreshold && bms < -BMS_Threshold && pvi < -PVI_Threshold * PIP_VALUE)
    {
        if(compressionOK || vsd == -1)
        {
            Print("ClaX SELL SIGNAL: WDR=", DoubleToString(wdr, 2),
                  " BMS=", DoubleToString(bms, 2),
                  " PVI=", DoubleToString(pvi/PIP_VALUE, 1), " pips/bar");
            return -1;  // SELL
        }
    }

    return 0;  // NO SIGNAL
}

//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
    double price;
    double sl;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double slDistance = SL_Pips * PIP_VALUE;

    if(signal == 1)  // BUY
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = NormalizeDouble(price - slDistance, digits);

        // PRAVI SL ODMAH pri otvaranju (stealth TP = 0)
        if(trade.Buy(LotSize, _Symbol, price, sl, 0, "ClaX BUY"))
        {
            ulong ticket = trade.ResultOrder();
            AddTrade(ticket, price, LotSize);
            barsSinceLastTrade = 0;
            Print("ClaX BUY [", ticket, "]: ", LotSize, " @ ", price, " SL=", sl);
        }
    }
    else if(signal == -1)  // SELL
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = NormalizeDouble(price + slDistance, digits);

        // PRAVI SL ODMAH pri otvaranju (stealth TP = 0)
        if(trade.Sell(LotSize, _Symbol, price, sl, 0, "ClaX SELL"))
        {
            ulong ticket = trade.ResultOrder();
            AddTrade(ticket, price, LotSize);
            barsSinceLastTrade = 0;
            Print("ClaX SELL [", ticket, "]: ", LotSize, " @ ", price, " SL=", sl);
        }
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    // Upravljanje otvorenim pozicijama - svaki tick
    ManageTargets();
    ManageTrailing();

    // Signal provjera - samo na novom baru
    if(!IsNewBar()) return;

    // Filteri
    if(!IsTradingWindow()) return;
    if(!CheckSpread()) return;
    if(HasOpenPosition()) return;
    if(barsSinceLastTrade < MinBarsAfterTrade) return;

    // Generiraj signal
    int signal = GenerateSignal();

    // Izvrši trade
    if(signal != 0)
    {
        ExecuteTrade(signal);
    }
}
//+------------------------------------------------------------------+
