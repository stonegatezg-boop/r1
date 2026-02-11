//+------------------------------------------------------------------+
//|                                              XAUUSD_M5_EA.mq5    |
//|                        *** CALF ***                              |
//|                        AlphaTrend + UT Bot + Session Filter      |
//+------------------------------------------------------------------+
#property copyright "CALF - AlphaTrend + UT Bot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== ALPHATREND POSTAVKE ==="
input int      AlphaPeriod      = 14;       // AlphaTrend Period (optimalno: 7-14)
input double   AlphaCoeff       = 1.0;      // AlphaTrend Coefficient (optimalno: 0.8-1.5)

input group "=== UT BOT POSTAVKE ==="
input double   UTKey            = 2.0;      // UT Bot Key Value (optimalno: 1.5-2.0)
input int      UTAtrPeriod      = 14;       // UT Bot ATR Period (optimalno: 10-14)

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 1.5;      // Stop Loss (x ATR)
input double   TPMultiplier     = 2.5;      // Take Profit (x ATR)
input int      ATRPeriod        = 20;       // ATR Period za SL/TP
input int      MaxBarsInTrade   = 48;       // Max barova u tradeu (4 sata na M5)
input double   RiskPercent      = 1.0;      // Risk % od Balance-a

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;     // Koristi session filter
input int      LondonStart      = 2;        // London početak (UTC sat)
input int      LondonEnd        = 5;        // London kraj
input int      NYAMStart        = 9;        // NY AM početak
input int      NYAMEnd          = 11;       // NY AM kraj
input int      NYPMStart        = 13;       // NY PM početak
input int      NYPMEnd          = 17;       // NY PM kraj

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 123456;   // Magic Number
input int      Slippage         = 30;       // Slippage (points)
input bool     TradeOnNewBar    = true;     // Trade samo na novom baru (preporučeno)

//--- Global variables
CTrade         trade;
int            atrHandle;
int            rsiHandle;
double         alphaLine[];
double         trailingStop[];
int            alphaTrend[];
int            utPosition[];
datetime       lastBarTime;
int            barsInCurrentTrade;
ulong          currentTicket;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Initialize trade object
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    //--- Create indicator handles
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, AlphaPeriod, PRICE_CLOSE);

    if(atrHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    //--- Initialize arrays
    ArraySetAsSeries(alphaLine, true);
    ArraySetAsSeries(trailingStop, true);
    ArraySetAsSeries(alphaTrend, true);
    ArraySetAsSeries(utPosition, true);

    ArrayResize(alphaLine, 3);
    ArrayResize(trailingStop, 3);
    ArrayResize(alphaTrend, 3);
    ArrayResize(utPosition, 3);

    //--- Initialize values
    lastBarTime = 0;
    barsInCurrentTrade = 0;
    currentTicket = 0;

    Print("=== CALF EA inicijaliziran ===");
    Print("AlphaTrend(", AlphaPeriod, ",", AlphaCoeff, ") + UT Bot(", UTKey, ",", UTAtrPeriod, ")");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
}

//+------------------------------------------------------------------+
//| Check if new bar formed                                           |
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
//| Check if current hour is in good trading session                  |
//+------------------------------------------------------------------+
bool IsGoodSession()
{
    if(!UseSessionFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    // London session
    if(hour >= LondonStart && hour < LondonEnd) return true;

    // NY AM session
    if(hour >= NYAMStart && hour < NYAMEnd) return true;

    // NY PM session
    if(hour >= NYPMStart && hour < NYPMEnd) return true;

    return false;
}

//+------------------------------------------------------------------+
//| Calculate AlphaTrend indicator                                     |
//+------------------------------------------------------------------+
void CalculateAlphaTrend(int shift)
{
    double close[], high[], low[], atr[], rsi[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(atr, true);
    ArraySetAsSeries(rsi, true);

    int bars = AlphaPeriod + 10;
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);

    //--- Calculate ATR manually for AlphaTrend
    double sumTR = 0;
    for(int i = 1; i <= AlphaPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i],
                    MathMax(MathAbs(high[i] - close[i+1]),
                            MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double alphaATR = sumTR / AlphaPeriod;

    //--- Get RSI
    double rsiBuffer[];
    ArraySetAsSeries(rsiBuffer, true);
    CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer);

    //--- Calculate AlphaTrend for shifts 0, 1, 2
    for(int s = 2; s >= 0; s--)
    {
        double up = close[s] - AlphaCoeff * alphaATR;
        double dn = close[s] + AlphaCoeff * alphaATR;

        double prevAlpha = (s < 2) ? alphaLine[s+1] : close[s];

        if(rsiBuffer[s] >= 50)
        {
            alphaLine[s] = MathMax(up, prevAlpha);
            alphaTrend[s] = 1;
        }
        else
        {
            alphaLine[s] = MathMin(dn, prevAlpha);
            alphaTrend[s] = -1;
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate UT Bot indicator                                         |
//+------------------------------------------------------------------+
void CalculateUTBot(int shift)
{
    double close[], high[], low[];
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);

    int bars = UTAtrPeriod + 10;
    CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
    CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
    CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);

    //--- Calculate ATR for UT Bot
    double sumTR = 0;
    for(int i = 1; i <= UTAtrPeriod; i++)
    {
        double tr = MathMax(high[i] - low[i],
                    MathMax(MathAbs(high[i] - close[i+1]),
                            MathAbs(low[i] - close[i+1])));
        sumTR += tr;
    }
    double utATR = sumTR / UTAtrPeriod;
    double nLoss = UTKey * utATR;

    //--- Calculate trailing stop for shifts 0, 1, 2
    for(int s = 2; s >= 0; s--)
    {
        double src = close[s];
        double srcPrev = close[s+1];
        double prevTS = (s < 2) ? trailingStop[s+1] : close[s];

        if(src > prevTS && srcPrev > prevTS)
            trailingStop[s] = MathMax(prevTS, src - nLoss);
        else if(src < prevTS && srcPrev < prevTS)
            trailingStop[s] = MathMin(prevTS, src + nLoss);
        else if(src > prevTS)
            trailingStop[s] = src - nLoss;
        else
            trailingStop[s] = src + nLoss;

        //--- Position
        if(srcPrev < prevTS && src > prevTS)
            utPosition[s] = 1;
        else if(srcPrev > prevTS && src < prevTS)
            utPosition[s] = -1;
        else
            utPosition[s] = (s < 2) ? utPosition[s+1] : 0;
    }
}

//+------------------------------------------------------------------+
//| Get ATR value                                                      |
//+------------------------------------------------------------------+
double GetATR(int shift = 1)
{
    double atrBuffer[];
    ArraySetAsSeries(atrBuffer, true);
    if(CopyBuffer(atrHandle, 0, shift, 1, atrBuffer) <= 0)
        return 0;
    return atrBuffer[0];
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * RiskPercent / 100.0;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    double slPoints = slDistance / point;
    double lotSize = riskAmount / (slPoints * tickValue / tickSize);

    //--- Normalize lot size
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Check if we have an open position                                  |
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
            {
                currentTicket = ticket;
                return true;
            }
        }
    }
    currentTicket = 0;
    return false;
}

//+------------------------------------------------------------------+
//| Close position by ticket                                           |
//+------------------------------------------------------------------+
void ClosePosition()
{
    if(currentTicket > 0)
    {
        trade.PositionClose(currentTicket);
        currentTicket = 0;
        barsInCurrentTrade = 0;
    }
}

//+------------------------------------------------------------------+
//| Check time-based exit                                              |
//+------------------------------------------------------------------+
void CheckTimeExit()
{
    if(HasOpenPosition() && barsInCurrentTrade >= MaxBarsInTrade)
    {
        Print("Time exit - ", barsInCurrentTrade, " barova u tradeu");
        ClosePosition();
    }
}

//+------------------------------------------------------------------+
//| Open buy position                                                  |
//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr = GetATR(1);
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = price - SLMultiplier * atr;
    double tp = price + TPMultiplier * atr;
    double slDistance = SLMultiplier * atr;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    //--- Normalize prices
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if(trade.Buy(lots, _Symbol, price, sl, tp, "CALF BUY"))
    {
        Print("CALF BUY: ", lots, " @ ", price, " SL=", sl, " TP=", tp);
        barsInCurrentTrade = 0;
    }
    else
    {
        Print("Greška pri otvaranju BUY: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Open sell position                                                 |
//+------------------------------------------------------------------+
void OpenSell()
{
    double atr = GetATR(1);
    if(atr <= 0) return;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = price + SLMultiplier * atr;
    double tp = price - TPMultiplier * atr;
    double slDistance = SLMultiplier * atr;

    double lots = CalculateLotSize(slDistance);
    if(lots <= 0) return;

    //--- Normalize prices
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if(trade.Sell(lots, _Symbol, price, sl, tp, "CALF SELL"))
    {
        Print("CALF SELL: ", lots, " @ ", price, " SL=", sl, " TP=", tp);
        barsInCurrentTrade = 0;
    }
    else
    {
        Print("Greška pri otvaranju SELL: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check for new bar (recommended to avoid noise)
    if(TradeOnNewBar && !IsNewBar())
    {
        //--- Still increment bars counter if in trade
        return;
    }

    //--- If in trade, increment counter
    if(HasOpenPosition())
    {
        barsInCurrentTrade++;
        CheckTimeExit();

        if(HasOpenPosition()) return;  // Still in trade after time check
    }

    //--- Check session
    if(!IsGoodSession())
    {
        return;
    }

    //--- Calculate indicators using PREVIOUS BAR [1] - no repaint!
    CalculateAlphaTrend(1);
    CalculateUTBot(1);

    //--- Check AlphaTrend direction (filter)
    int alphaTrendDir = alphaTrend[1];  // 1 = bullish, -1 = bearish

    //--- Check UT Bot CROSSOVER on CONFIRMED bar [1]
    bool utCrossUp = (utPosition[1] == 1 && utPosition[2] == -1);
    bool utCrossDown = (utPosition[1] == -1 && utPosition[2] == 1);

    //--- Generate signals: UT Bot crossover + AlphaTrend filter
    bool buySignal = utCrossUp && (alphaTrendDir == 1);
    bool sellSignal = utCrossDown && (alphaTrendDir == -1);

    //--- Execute trades
    if(buySignal && !HasOpenPosition())
    {
        Print("CALF BUY SIGNAL");
        OpenBuy();
    }
    else if(sellSignal && !HasOpenPosition())
    {
        Print("CALF SELL SIGNAL");
        OpenSell();
    }
}

//+------------------------------------------------------------------+
//| Tester function for optimization                                   |
//+------------------------------------------------------------------+
double OnTester()
{
    double profit = TesterStatistics(STAT_PROFIT);
    double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    double winRate = TesterStatistics(STAT_TRADES) > 0 ?
                     TesterStatistics(STAT_PROFIT_TRADES) / TesterStatistics(STAT_TRADES) * 100 : 0;

    //--- Custom optimization criterion
    //--- Preferira visok PF s dovoljno trgovina
    if(trades < 100) return 0;  // Premalo trgovina

    return profitFactor * MathSqrt(trades);
}
//+------------------------------------------------------------------+
