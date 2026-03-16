//+------------------------------------------------------------------+
//|                                                  BTC_Cla_V1.mq5  |
//|              *** BTC Scalper v1.0 ***                            |
//|   Multi-Timeframe EMA(9/21) + RSI + ADX Strategy for BTCUSD M5  |
//|   H1 EMA(50) trend filter | ATR-based SL/TP | Session filter     |
//|   Based on: documented BTC M5 research (2018-2024 backtests)     |
//|   Created: 16.03.2026 20:45 (Zagreb)                             |
//+------------------------------------------------------------------+
//
// STRATEGY:
//   Entry signal (M5):
//     - EMA(9) crosses EMA(21) → direction
//     - RSI(14) > 50 for longs, < 50 for shorts (momentum bias)
//     - ADX(14) > 20 (trend exists, not choppy)
//   Trend filter (H1):
//     - H1 close above EMA(50) → only longs
//     - H1 close below EMA(50) → only shorts
//   Filters:
//     - ATR: MinATR < ATR < MaxATR (active but not spiking market)
//     - Spread < MaxSpread_USD
//     - Session: 07:00-20:00 UTC (London open to NY close)
//     - Max 3 trades/day, max 3% daily loss cap
//   Exits:
//     - SL: 1.2 * ATR set IMMEDIATELY at entry
//     - TP: stealth close at 2.4 * ATR (1:2 RR)
//     - Trail L1: move SL to BE+30 pips when profit >= 1.2*ATR
//     - Trail L2: trail at 1.0*ATR when profit >= 2.4*ATR
//
// RESEARCH BASIS:
//   - Bitcoin Scalping MT5: PF 2.27, WR 85%, 6yr backtest IC Markets
//   - Academic: RSI-based systems best across crypto (2023, RQFA)
//   - ATR trailing: 108-116% in 6 months bull, DD < 2.34% (2023)
//   - EMA 9/21 + RSI50 bias: most documented BTC M5 combo
//
//+------------------------------------------------------------------+
#property copyright "BTC_Cla_V1 (2026-03-16)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//─── INPUT PARAMETERS ──────────────────────────────────────────────

input group "=== SIGNAL (M5) ==="
input int      FastEMA          = 9;          // Fast EMA period
input int      SlowEMA          = 21;         // Slow EMA period
input int      RSI_Period       = 14;         // RSI period
input bool     UseEMA200Filter  = true;       // Also filter by M5 EMA(200)

input group "=== TREND FILTER (H1) ==="
input bool     UseH1Trend       = true;       // H1 EMA trend filter (recommended ON)
input int      H1_EMA_Period    = 50;         // H1 EMA period

input group "=== ADX FILTER ==="
input bool     UseADX           = true;       // ADX filter (avoid choppy markets)
input int      ADX_Period       = 14;         // ADX period
input double   ADX_Min          = 20.0;       // Min ADX value to allow entry

input group "=== ATR & VOLATILITY ==="
input int      ATR_Period       = 14;         // ATR period
input double   MinATR_USD       = 50.0;       // Min ATR in USD (ignore dead markets)
input double   MaxATR_USD       = 600.0;      // Max ATR in USD (ignore extreme spikes)
input double   SL_ATR_Multi     = 1.2;        // SL distance = ATR * this value
input double   TP_ATR_Multi     = 2.4;        // Stealth TP = ATR * this value (1:2 RR)

input group "=== TRAILING STOP ==="
input double   Trail_L1_ATR     = 1.2;        // Activate BE trail at X*ATR profit
input int      Trail_BE_Min     = 25;         // Min extra pips above BE (random)
input int      Trail_BE_Max     = 35;         // Max extra pips above BE (random)
input double   Trail_L2_ATR     = 2.0;        // Activate L2 trail at X*ATR profit
input double   Trail_L2_Dist    = 1.0;        // L2: trail at Y*ATR from current price

input group "=== SPREAD & EXECUTION ==="
input double   MaxSpread_USD    = 20.0;       // Max spread in USD
input int      Slippage         = 300;        // Slippage in points (BTC: high)

input group "=== SESSION FILTER ==="
input int      SessionStart_UTC = 7;          // Session start hour (UTC) — London open
input int      SessionEnd_UTC   = 20;         // Session end hour (UTC) — NY close
input int      FridayStop_UTC   = 11;         // Friday: stop new trades after this UTC hour

input group "=== RISK & DAILY LIMITS ==="
input double   RiskPercent      = 1.0;        // Risk per trade (% of equity)
input int      MaxTradesPerDay  = 3;          // Max new trades per calendar day
input double   MaxDailyLoss_Pct = 3.0;        // Stop EA if daily loss exceeds this %
input int      MinBarsBetween   = 3;          // Cooldown: min bars between trades

input group "=== GENERAL ==="
input ulong    MagicNumber      = 112233;     // Magic number (unique for BTCUSD)

//─── STRUCTS ───────────────────────────────────────────────────────

struct PosData
{
    ulong   ticket;
    double  entryPrice;
    double  atrAtEntry;
    double  stealthTP;     // manual TP price
    int     trailLevel;    // 0=none, 1=BE moved, 2=trailing
    int     beExtra;       // random BE extra pips used
};

//─── GLOBAL VARIABLES ──────────────────────────────────────────────

CTrade   trade;
int      h_ema_fast, h_ema_slow, h_ema_200, h_rsi, h_ema_h1, h_adx, h_atr;

datetime lastBarTime       = 0;
int      barsSinceLastTrade = 999;
double   dayStartBalance   = 0;
datetime lastDayDate       = 0;

PosData  positions[];
int      posCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    h_ema_fast = iMA(_Symbol, PERIOD_M5, FastEMA,       0, MODE_EMA, PRICE_CLOSE);
    h_ema_slow = iMA(_Symbol, PERIOD_M5, SlowEMA,       0, MODE_EMA, PRICE_CLOSE);
    h_ema_200  = iMA(_Symbol, PERIOD_M5, 200,           0, MODE_EMA, PRICE_CLOSE);
    h_rsi      = iRSI(_Symbol, PERIOD_M5, RSI_Period,   PRICE_CLOSE);
    h_ema_h1   = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    h_adx      = iADX(_Symbol, PERIOD_M5, ADX_Period);
    h_atr      = iATR(_Symbol, PERIOD_M5, ATR_Period);

    if(h_ema_fast == INVALID_HANDLE || h_ema_slow == INVALID_HANDLE ||
       h_ema_200  == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
       h_ema_h1   == INVALID_HANDLE || h_adx == INVALID_HANDLE ||
       h_atr      == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create indicators!");
        return INIT_FAILED;
    }

    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    ArrayResize(positions, 0);
    posCount = 0;

    dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    lastDayDate     = TimeCurrent();

    Print("=== BTC_Cla_V1 initialized ===");
    Print("Signal: EMA(", FastEMA, "/", SlowEMA, ") + RSI(", RSI_Period, ") + ADX(", ADX_Period, ")");
    Print("Trend:  H1 EMA(", H1_EMA_Period, ") | EMA200 filter: ", UseEMA200Filter);
    Print("Risk:   ", RiskPercent, "% | SL=", SL_ATR_Multi, "xATR | TP=", TP_ATR_Multi, "xATR");
    Print("Session: ", SessionStart_UTC, ":00-", SessionEnd_UTC, ":00 UTC | MaxTrades/day: ", MaxTradesPerDay);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(h_ema_fast);
    IndicatorRelease(h_ema_slow);
    IndicatorRelease(h_ema_200);
    IndicatorRelease(h_rsi);
    IndicatorRelease(h_ema_h1);
    IndicatorRelease(h_adx);
    IndicatorRelease(h_atr);
}

//─── HELPERS ───────────────────────────────────────────────────────

int RandomRange(int a, int b) { return (a >= b) ? a : a + MathRand() % (b - a + 1); }

double GetATR()
{
    double buf[]; ArraySetAsSeries(buf, true);
    if(CopyBuffer(h_atr, 0, 1, 1, buf) <= 0) return 0;
    return buf[0];
}

bool IsNewBar()
{
    datetime t = iTime(_Symbol, PERIOD_M5, 0);
    if(t != lastBarTime) { lastBarTime = t; barsSinceLastTrade++; return true; }
    return false;
}

void UpdateDayTracking()
{
    MqlDateTime now, last;
    TimeToStruct(TimeCurrent(), now);
    TimeToStruct(lastDayDate, last);
    if(now.day != last.day)
    {
        dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        lastDayDate     = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
bool IsTradingWindow()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.day_of_week == 6) return false;                                    // Saturday: no trading
    if(dt.day_of_week == 0 && dt.hour < 1) return false;                    // Sunday before 01:00
    if(dt.day_of_week == 5 && dt.hour >= FridayStop_UTC) return false;      // Friday cutoff

    if(dt.hour < SessionStart_UTC || dt.hour >= SessionEnd_UTC) return false; // Outside session
    return true;
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
    double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double spreadUSD = spreadPts * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    return (spreadUSD <= MaxSpread_USD);
}

//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
    double atr = GetATR();
    return (atr >= MinATR_USD && atr <= MaxATR_USD);
}

//+------------------------------------------------------------------+
bool IsDailyLossExceeded()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double loss    = dayStartBalance - balance;
    if(dayStartBalance <= 0) return false;
    return ((loss / dayStartBalance) * 100.0 >= MaxDailyLoss_Pct);
}

//+------------------------------------------------------------------+
int CountTodayTrades()
{
    MqlDateTime today;
    TimeToStruct(TimeCurrent(), today);
    datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                        today.year, today.mon, today.day));
    HistorySelect(dayStart, TimeCurrent());
    int cnt = 0;
    for(int i = 0; i < HistoryDealsTotal(); i++)
    {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_MAGIC)  == (long)MagicNumber &&
           HistoryDealGetString(t, DEAL_SYMBOL)  == _Symbol &&
           HistoryDealGetInteger(t, DEAL_ENTRY)  == DEAL_ENTRY_IN)
            cnt++;
    }
    return cnt;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) &&
           PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
           PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
    }
    return false;
}

//─── SIGNAL LOGIC ──────────────────────────────────────────────────

int GetH1Trend()
{
    // Returns: +1 = bullish (price above H1 EMA), -1 = bearish, 0 = uncertain
    double ema[]; ArraySetAsSeries(ema, true);
    if(CopyBuffer(h_ema_h1, 0, 1, 2, ema) <= 0) return 0;
    double h1Close = iClose(_Symbol, PERIOD_H1, 1);
    if(h1Close > ema[0]) return 1;
    if(h1Close < ema[0]) return -1;
    return 0;
}

//+------------------------------------------------------------------+
void GetSignals(bool &buySignal, bool &sellSignal)
{
    buySignal = false;
    sellSignal = false;

    if(barsSinceLastTrade < MinBarsBetween) return;

    // --- Read indicators (bar[1] = last closed, bar[2] = bar before) ---
    double fast[], slow[], ema200[], rsi[], adx[];
    ArraySetAsSeries(fast,   true);
    ArraySetAsSeries(slow,   true);
    ArraySetAsSeries(ema200, true);
    ArraySetAsSeries(rsi,    true);
    ArraySetAsSeries(adx,    true);

    if(CopyBuffer(h_ema_fast, 0, 0, 3, fast)   <= 0) return;
    if(CopyBuffer(h_ema_slow, 0, 0, 3, slow)   <= 0) return;
    if(CopyBuffer(h_ema_200,  0, 0, 3, ema200) <= 0) return;
    if(CopyBuffer(h_rsi,      0, 0, 3, rsi)    <= 0) return;
    if(CopyBuffer(h_adx,      0, 1, 1, adx)    <= 0) return;

    // EMA cross on completed bars
    bool crossUp   = (fast[1] > slow[1]) && (fast[2] <= slow[2]);
    bool crossDown = (fast[1] < slow[1]) && (fast[2] >= slow[2]);

    // RSI momentum bias (not classic OS/OB — momentum direction)
    bool rsiBull = (rsi[1] > 50.0);
    bool rsiBear = (rsi[1] < 50.0);

    // ADX: trend strength
    bool trendStrong = (!UseADX) || (adx[0] >= ADX_Min);

    // EMA200 on M5 (additional trend context)
    double closeM5 = iClose(_Symbol, PERIOD_M5, 1);
    bool above200 = (closeM5 > ema200[1]);
    bool below200 = (closeM5 < ema200[1]);

    // H1 trend
    int h1Trend = UseH1Trend ? GetH1Trend() : 0;

    // LONG conditions
    if(crossUp && rsiBull && trendStrong)
    {
        if(!UseH1Trend  || h1Trend >= 0)
        if(!UseEMA200Filter || above200)
            buySignal = true;
    }

    // SHORT conditions
    if(crossDown && rsiBear && trendStrong)
    {
        if(!UseH1Trend  || h1Trend <= 0)
        if(!UseEMA200Filter || below200)
            sellSignal = true;
    }
}

//─── LOT CALCULATION ───────────────────────────────────────────────

double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;
    double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmt    = equity * RiskPercent / 100.0;
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    double slPts   = slDistance / point;
    double lotSize = riskAmt / (slPts * tickValue / tickSize);
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lotSize)), 8);
}

//─── TRADE EXECUTION ───────────────────────────────────────────────

void OpenTrade(ENUM_ORDER_TYPE type)
{
    double atr = GetATR();
    if(atr <= 0) return;

    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double price    = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDist = SL_ATR_Multi * atr;
    double tpDist = TP_ATR_Multi * atr;

    // SL: IMMEDIATELY at entry (CLAUDE.md standard — no delay!)
    double sl = NormalizeDouble((type == ORDER_TYPE_BUY) ? price - slDist : price + slDist, digits);
    double stealthTP = NormalizeDouble((type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist, digits);

    double lots = CalculateLotSize(slDist);
    if(lots <= 0) return;

    string comment = StringFormat("BTC_Cla_V1|ATR=%.0f", atr);
    bool ok = (type == ORDER_TYPE_BUY)
              ? trade.Buy(lots, _Symbol, price, sl, 0, comment)
              : trade.Sell(lots, _Symbol, price, sl, 0, comment);

    if(ok)
    {
        ulong ticket = trade.ResultOrder();
        ArrayResize(positions, posCount + 1);
        positions[posCount].ticket     = ticket;
        positions[posCount].entryPrice = price;
        positions[posCount].atrAtEntry = atr;
        positions[posCount].stealthTP  = stealthTP;
        positions[posCount].trailLevel = 0;
        positions[posCount].beExtra    = RandomRange(Trail_BE_Min, Trail_BE_Max);
        posCount++;
        barsSinceLastTrade = 0;

        string dir = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
        Print(StringFormat("BTC_Cla_V1 %s #%I64u | lots=%.4f | price=%.2f | SL=%.2f | StTP=%.2f | ATR=%.2f",
              dir, ticket, lots, price, sl, stealthTP, atr));
    }
    else
    {
        Print("BTC_Cla_V1: Trade failed, error=", GetLastError());
    }
}

//─── POSITION MANAGEMENT ───────────────────────────────────────────

void SyncPositions()
{
    for(int i = posCount-1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(positions[i].ticket))
        {
            for(int j = i; j < posCount-1; j++) positions[j] = positions[j+1];
            posCount--;
            ArrayResize(positions, posCount);
        }
    }
}

//+------------------------------------------------------------------+
void ManagePositions()
{
    SyncPositions();

    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    for(int i = 0; i < posCount; i++)
    {
        ulong ticket = positions[i].ticket;
        if(!PositionSelectByTicket(ticket)) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double currentSL  = PositionGetDouble(POSITION_SL);
        double entryPrice = positions[i].entryPrice;
        double atr        = positions[i].atrAtEntry;
        double stealthTP  = positions[i].stealthTP;

        double curPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double profit   = (posType == POSITION_TYPE_BUY) ? curPrice - entryPrice
                                                         : entryPrice - curPrice;

        // 1. Stealth TP check
        if(stealthTP > 0)
        {
            bool tpHit = (posType == POSITION_TYPE_BUY  && curPrice >= stealthTP) ||
                         (posType == POSITION_TYPE_SELL && curPrice <= stealthTP);
            if(tpHit)
            {
                trade.PositionClose(ticket);
                Print(StringFormat("BTC_Cla_V1: Stealth TP hit #%I64u profit=%.2f", ticket, profit));
                continue;
            }
        }

        // 2. Trail Level 2: ATR trailing once at 2.0*ATR profit
        if(positions[i].trailLevel < 2 && profit >= Trail_L2_ATR * atr && currentSL > 0)
        {
            double newSL = NormalizeDouble(
                (posType == POSITION_TYPE_BUY) ? curPrice - Trail_L2_Dist * atr
                                               : curPrice + Trail_L2_Dist * atr, digits);
            bool better = (posType == POSITION_TYPE_BUY  && newSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(better && trade.PositionModify(ticket, newSL, 0))
            {
                positions[i].trailLevel = 2;
                Print(StringFormat("BTC_Cla_V1: Trail L2 #%I64u newSL=%.2f", ticket, newSL));
            }
            continue; // Don't apply L1 simultaneously
        }

        // 3. Trail Level 1: Move SL to BE+ once at 1.2*ATR profit
        if(positions[i].trailLevel < 1 && profit >= Trail_L1_ATR * atr && currentSL > 0)
        {
            double beExtra = positions[i].beExtra * point;
            double newSL   = NormalizeDouble(
                (posType == POSITION_TYPE_BUY) ? entryPrice + beExtra
                                               : entryPrice - beExtra, digits);
            bool better = (posType == POSITION_TYPE_BUY  && newSL > currentSL) ||
                          (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(better && trade.PositionModify(ticket, newSL, 0))
            {
                positions[i].trailLevel = 1;
                Print(StringFormat("BTC_Cla_V1: Trail BE+%d #%I64u newSL=%.2f",
                      positions[i].beExtra, ticket, newSL));
            }
        }
    }
}

//─── MAIN TICK ─────────────────────────────────────────────────────

void OnTick()
{
    ManagePositions();       // Always manage open positions on every tick

    if(!IsNewBar()) return;  // Entry logic only on new bar

    UpdateDayTracking();

    // Pre-entry filters
    if(!IsTradingWindow())           return;
    if(IsDailyLossExceeded())        { Print("BTC_Cla_V1: Daily loss cap reached, stopped for today."); return; }
    if(CountTodayTrades() >= MaxTradesPerDay) return;
    if(HasOpenPosition())            return;
    if(!IsSpreadOK())                return;
    if(!IsVolatilityOK())            return;

    // Get entry signal
    bool buySignal, sellSignal;
    GetSignals(buySignal, sellSignal);

    if(buySignal)       OpenTrade(ORDER_TYPE_BUY);
    else if(sellSignal) OpenTrade(ORDER_TYPE_SELL);
}

//─── OPTIMIZATION CRITERION ────────────────────────────────────────

double OnTester()
{
    double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
    double trades = TesterStatistics(STAT_TRADES);
    double dd     = TesterStatistics(STAT_EQUITY_DD_RELATIVE);
    double wr     = TesterStatistics(STAT_PROFIT_TRADES) / MathMax(1, trades);

    if(trades < 30) return 0;
    if(pf < 1.2)    return 0;
    if(dd > 25.0)   return 0;

    // Maximize: PF * sqrt(trades) * WR / (1 + DD%)
    return pf * MathSqrt(trades) * wr / (1.0 + dd / 100.0);
}
//+------------------------------------------------------------------+
