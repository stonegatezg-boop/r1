//+------------------------------------------------------------------+
//|                                              Clawder_Bridge.mq5  |
//|                        *** Clawder Bridge v2.0 ***               |
//|                   MT5 <-> Python <-> Claude AI Bridge            |
//|                   Date: 2026-02-17 (Zagreb, CET)                 |
//+------------------------------------------------------------------+
#property copyright "Clawder Bridge v2.0"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== M5 INDIKATORI ==="
input int      RSI_Period       = 14;
input int      EMA_Fast         = 9;
input int      EMA_Slow         = 21;
input int      EMA_Trend        = 50;
input int      EMA_Long         = 200;
input int      MACD_Fast        = 12;
input int      MACD_Slow        = 26;
input int      MACD_Signal      = 9;
input int      ATR_Period       = 14;
input int      BB_Period        = 20;
input double   BB_Deviation     = 2.0;

input group "=== TRADE MANAGEMENT ==="
input double   RiskPercent      = 1.0;
input double   MinConfidence    = 0.7;         // Min confidence za trade (0.0-1.0)
input int      Slippage         = 30;
input double   MaxSpreadATR     = 0.3;         // Max spread kao % ATR-a
input int      MaxTradesPerDay  = 5;           // Max tradeova dnevno
input double   DailyDrawdownPct = 3.0;         // Daily drawdown limit (% balansa)

input group "=== FILE PATHS ==="
input string   DataFileName     = "clawder_data.csv";
input string   DecisionFileName = "clawder_decision.csv";

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 999999;

//--- Global variables
CTrade         trade;

// M5 indikatori
int            rsiHandle, emaFastHandle, emaSlowHandle, emaTrendHandle, emaLongHandle;
int            macdHandle, atrHandle, bbHandle;

// H1 indikatori za kontekst
int            h1_rsiHandle, h1_emaFastHandle, h1_emaSlowHandle;
int            h1_macdHandle, h1_atrHandle;

// H4 indikatori za kontekst
int            h4_emaTrendHandle, h4_atrHandle;

datetime       lastBarTime = 0;
datetime       lastDecisionTime = 0;

// Dnevni limiti
datetime       currentDay = 0;
int            tradesToday = 0;
double         dayStartBalance = 0;
bool           dailyKillSwitch = false;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // ========== M5 INDIKATORI ==========
    rsiHandle = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
    emaFastHandle = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    emaTrendHandle = iMA(_Symbol, PERIOD_M5, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
    emaLongHandle = iMA(_Symbol, PERIOD_M5, EMA_Long, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_M5, ATR_Period);
    bbHandle = iBands(_Symbol, PERIOD_M5, BB_Period, 0, BB_Deviation, PRICE_CLOSE);

    // ========== H1 INDIKATORI (KONTEKST) ==========
    h1_rsiHandle = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE);
    h1_emaFastHandle = iMA(_Symbol, PERIOD_H1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    h1_emaSlowHandle = iMA(_Symbol, PERIOD_H1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    h1_macdHandle = iMACD(_Symbol, PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    h1_atrHandle = iATR(_Symbol, PERIOD_H1, ATR_Period);

    // ========== H4 INDIKATORI (BIG PICTURE) ==========
    h4_emaTrendHandle = iMA(_Symbol, PERIOD_H4, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
    h4_atrHandle = iATR(_Symbol, PERIOD_H4, ATR_Period);

    // Provjera handleova
    if(rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE ||
       atrHandle == INVALID_HANDLE || bbHandle == INVALID_HANDLE ||
       h1_rsiHandle == INVALID_HANDLE || h1_macdHandle == INVALID_HANDLE ||
       h4_emaTrendHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    // Inicijaliziraj dnevne varijable
    ResetDailyCounters();

    Print("=== Clawder Bridge v2.0 ===");
    Print("Data file: ", DataFileName);
    Print("Decision file: ", DecisionFileName);
    Print("Min confidence: ", MinConfidence);
    Print("Max spread (ATR%): ", MaxSpreadATR);
    Print("Max trades/day: ", MaxTradesPerDay);
    Print("Daily drawdown limit: ", DailyDrawdownPct, "%");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // M5
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
    if(emaTrendHandle != INVALID_HANDLE) IndicatorRelease(emaTrendHandle);
    if(emaLongHandle != INVALID_HANDLE) IndicatorRelease(emaLongHandle);
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);

    // H1
    if(h1_rsiHandle != INVALID_HANDLE) IndicatorRelease(h1_rsiHandle);
    if(h1_emaFastHandle != INVALID_HANDLE) IndicatorRelease(h1_emaFastHandle);
    if(h1_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(h1_emaSlowHandle);
    if(h1_macdHandle != INVALID_HANDLE) IndicatorRelease(h1_macdHandle);
    if(h1_atrHandle != INVALID_HANDLE) IndicatorRelease(h1_atrHandle);

    // H4
    if(h4_emaTrendHandle != INVALID_HANDLE) IndicatorRelease(h4_emaTrendHandle);
    if(h4_atrHandle != INVALID_HANDLE) IndicatorRelease(h4_atrHandle);
}

//+------------------------------------------------------------------+
void ResetDailyCounters()
{
    MqlDateTime dt;
    TimeCurrent(dt);
    datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

    if(today != currentDay)
    {
        currentDay = today;
        tradesToday = 0;
        dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        dailyKillSwitch = false;
        Print("Clawder: Novi dan - resetirani dnevni brojači");
    }
}

//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
    // Provjeri drawdown
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double drawdownPct = (dayStartBalance - currentBalance) / dayStartBalance * 100;

    if(drawdownPct >= DailyDrawdownPct)
    {
        if(!dailyKillSwitch)
        {
            dailyKillSwitch = true;
            Print("!!! DAILY KILL SWITCH ACTIVATED !!! Drawdown: ", DoubleToString(drawdownPct, 2), "%");
        }
        return false;
    }

    // Provjeri broj tradeova
    if(tradesToday >= MaxTradesPerDay)
    {
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
    double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double atr = GetIndicatorValue(atrHandle, 0, 1);

    if(atr <= 0) return true;

    double spreadRatio = spread / atr;
    if(spreadRatio > MaxSpreadATR)
    {
        Print("Clawder: Spread too wide (", DoubleToString(spreadRatio * 100, 1), "% of ATR)");
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int buffer, int shift)
{
    double value[1];
    if(CopyBuffer(handle, buffer, shift, 1, value) > 0)
        return value[0];
    return 0;
}

//+------------------------------------------------------------------+
string GetRSIZone(double rsi)
{
    if(rsi < 30) return "oversold";
    if(rsi > 70) return "overbought";
    if(rsi < 40) return "weak";
    if(rsi > 60) return "strong";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetEMASlope(int handle, int atrHandle_local, int periods)
{
    double current = GetIndicatorValue(handle, 0, 1);
    double previous = GetIndicatorValue(handle, 0, periods + 1);

    if(current == 0 || previous == 0) return "unknown";

    double diff = current - previous;
    double atr = GetIndicatorValue(atrHandle_local, 0, 1);
    double threshold = atr * 0.1;

    if(diff > threshold) return "bullish";
    if(diff < -threshold) return "bearish";
    return "flat";
}

//+------------------------------------------------------------------+
string GetPriceVsEMA()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ema50 = GetIndicatorValue(emaTrendHandle, 0, 1);
    double ema200 = GetIndicatorValue(emaLongHandle, 0, 1);

    if(price > ema50 && price > ema200) return "above_both";
    if(price < ema50 && price < ema200) return "below_both";
    return "between";
}

//+------------------------------------------------------------------+
string GetMACDState(int handle)
{
    double macdMain1 = GetIndicatorValue(handle, 0, 1);
    double macdSignal1 = GetIndicatorValue(handle, 1, 1);
    double macdMain2 = GetIndicatorValue(handle, 0, 2);
    double macdSignal2 = GetIndicatorValue(handle, 1, 2);

    bool aboveNow = macdMain1 > macdSignal1;
    bool abovePrev = macdMain2 > macdSignal2;

    if(aboveNow && !abovePrev) return "cross_up";
    if(!aboveNow && abovePrev) return "cross_down";
    if(aboveNow) return "bullish";
    if(!aboveNow) return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetMACDHistogram(int handle)
{
    double hist1 = GetIndicatorValue(handle, 0, 1) - GetIndicatorValue(handle, 1, 1);
    double hist2 = GetIndicatorValue(handle, 0, 2) - GetIndicatorValue(handle, 1, 2);

    if(hist1 > 0 && hist1 > hist2) return "growing_positive";
    if(hist1 > 0 && hist1 < hist2) return "shrinking_positive";
    if(hist1 < 0 && hist1 < hist2) return "growing_negative";
    if(hist1 < 0 && hist1 > hist2) return "shrinking_negative";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetATRRegime(int handle)
{
    double atr = GetIndicatorValue(handle, 0, 1);

    double sum = 0;
    for(int i = 1; i <= 20; i++)
        sum += GetIndicatorValue(handle, 0, i);
    double avgATR = sum / 20;

    if(avgATR == 0) return "unknown";

    double ratio = atr / avgATR;

    if(ratio < 0.5) return "low";
    if(ratio > 2.0) return "extreme";
    if(ratio > 1.3) return "high";
    return "normal";
}

//+------------------------------------------------------------------+
string GetBBPosition()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double upper = GetIndicatorValue(bbHandle, 1, 1);
    double middle = GetIndicatorValue(bbHandle, 0, 1);
    double lower = GetIndicatorValue(bbHandle, 2, 1);

    if(price > upper) return "above_upper";
    if(price > middle + (upper - middle) * 0.5) return "upper_zone";
    if(price < lower) return "below_lower";
    if(price < middle - (middle - lower) * 0.5) return "lower_zone";
    return "middle";
}

//+------------------------------------------------------------------+
bool GetBBSqueeze()
{
    double width = GetIndicatorValue(bbHandle, 1, 1) - GetIndicatorValue(bbHandle, 2, 1);

    double sum = 0;
    for(int i = 1; i <= 20; i++)
    {
        double w = GetIndicatorValue(bbHandle, 1, i) - GetIndicatorValue(bbHandle, 2, i);
        sum += w;
    }
    double avgWidth = sum / 20;

    return (width < avgWidth * 0.5);
}

//+------------------------------------------------------------------+
string GetEMACrossEvent()
{
    double fast1 = GetIndicatorValue(emaFastHandle, 0, 1);
    double slow1 = GetIndicatorValue(emaSlowHandle, 0, 1);
    double fast2 = GetIndicatorValue(emaFastHandle, 0, 2);
    double slow2 = GetIndicatorValue(emaSlowHandle, 0, 2);

    if(fast1 > slow1 && fast2 < slow2) return "golden";
    if(fast1 < slow1 && fast2 > slow2) return "death";
    return "none";
}

//+------------------------------------------------------------------+
string GetEMAAlignment(int fastHandle, int slowHandle)
{
    double fast = GetIndicatorValue(fastHandle, 0, 1);
    double slow = GetIndicatorValue(slowHandle, 0, 1);

    if(fast > slow) return "bullish";
    if(fast < slow) return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
double GetCandleATRRatio()
{
    double high = iHigh(_Symbol, PERIOD_M5, 1);
    double low = iLow(_Symbol, PERIOD_M5, 1);
    double candleRange = high - low;
    double atr = GetIndicatorValue(atrHandle, 0, 1);

    if(atr <= 0) return 0;
    return candleRange / atr;
}

//+------------------------------------------------------------------+
bool IsImpulseCandle()
{
    return GetCandleATRRatio() > 2.0;
}

//+------------------------------------------------------------------+
bool IsMomentumExhaustion()
{
    // Momentum exhaustion = shrinking histogram + neutral RSI + normal ATR
    string histogram = GetMACDHistogram(macdHandle);
    double rsi = GetIndicatorValue(rsiHandle, 0, 1);
    string atrRegime = GetATRRegime(atrHandle);

    bool shrinkingHist = (histogram == "shrinking_positive" || histogram == "shrinking_negative");
    bool neutralRSI = (rsi >= 40 && rsi <= 60);
    bool normalATR = (atrRegime == "normal" || atrRegime == "low");

    return (shrinkingHist && neutralRSI && normalATR);
}

//+------------------------------------------------------------------+
string GetH1Trend()
{
    // H1 trend baziran na EMA alignment i MACD
    string emaAlign = GetEMAAlignment(h1_emaFastHandle, h1_emaSlowHandle);
    string macdState = GetMACDState(h1_macdHandle);

    if(emaAlign == "bullish" && (macdState == "bullish" || macdState == "cross_up"))
        return "strong_bullish";
    if(emaAlign == "bearish" && (macdState == "bearish" || macdState == "cross_down"))
        return "strong_bearish";
    if(emaAlign == "bullish")
        return "bullish";
    if(emaAlign == "bearish")
        return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetH4Trend()
{
    // H4 trend baziran na cijeni vs EMA50
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ema50 = GetIndicatorValue(h4_emaTrendHandle, 0, 1);
    double atr = GetIndicatorValue(h4_atrHandle, 0, 1);

    if(ema50 == 0 || atr == 0) return "unknown";

    double distance = (price - ema50) / atr;

    if(distance > 1.0) return "strong_bullish";
    if(distance > 0.3) return "bullish";
    if(distance < -1.0) return "strong_bearish";
    if(distance < -0.3) return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
void WriteDataFile()
{
    string filename = DataFileName;
    int handle = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');

    if(handle == INVALID_HANDLE)
    {
        Print("Greška: Ne mogu otvoriti ", filename);
        return;
    }

    // Header - sada s HTF kontekstom i novim featurama
    FileWrite(handle,
        // Osnovni podaci
        "timestamp", "symbol", "price", "spread_atr_pct",
        // M5 indikatori
        "atr", "rsi_value", "rsi_zone",
        "ema_fast", "ema_slow", "ema_trend", "ema_long",
        "ema_slope", "ema_position", "ema_cross_event", "ema_alignment",
        "macd_main", "macd_signal", "macd_state", "macd_histogram",
        "bb_upper", "bb_middle", "bb_lower", "bb_position", "bb_squeeze",
        "atr_regime", "candle_atr_ratio", "impulse_candle", "momentum_exhaustion",
        // H1 kontekst
        "h1_trend", "h1_rsi_zone", "h1_macd_state", "h1_atr_regime",
        // H4 kontekst
        "h4_trend",
        // Dnevni limiti
        "trades_today", "daily_drawdown_pct", "kill_switch_active"
    );

    // Izračunaj sve vrijednosti
    double rsi = GetIndicatorValue(rsiHandle, 0, 1);
    double emaFast = GetIndicatorValue(emaFastHandle, 0, 1);
    double emaSlow = GetIndicatorValue(emaSlowHandle, 0, 1);
    double emaTrend = GetIndicatorValue(emaTrendHandle, 0, 1);
    double emaLong = GetIndicatorValue(emaLongHandle, 0, 1);
    double macdMain = GetIndicatorValue(macdHandle, 0, 1);
    double macdSignal = GetIndicatorValue(macdHandle, 1, 1);
    double bbUpper = GetIndicatorValue(bbHandle, 1, 1);
    double bbMiddle = GetIndicatorValue(bbHandle, 0, 1);
    double bbLower = GetIndicatorValue(bbHandle, 2, 1);
    double atr = GetIndicatorValue(atrHandle, 0, 1);
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Spread kao % ATR-a
    double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadATRPct = (atr > 0) ? (spread / atr * 100) : 0;

    // H1 vrijednosti
    double h1_rsi = GetIndicatorValue(h1_rsiHandle, 0, 1);

    // Dnevni drawdown
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double dailyDrawdown = (dayStartBalance > 0) ? ((dayStartBalance - currentBalance) / dayStartBalance * 100) : 0;

    // Data row
    FileWrite(handle,
        // Osnovni podaci
        TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
        _Symbol,
        DoubleToString(price, _Digits),
        DoubleToString(spreadATRPct, 1),
        // M5 indikatori
        DoubleToString(atr, _Digits),
        DoubleToString(rsi, 2),
        GetRSIZone(rsi),
        DoubleToString(emaFast, _Digits),
        DoubleToString(emaSlow, _Digits),
        DoubleToString(emaTrend, _Digits),
        DoubleToString(emaLong, _Digits),
        GetEMASlope(emaTrendHandle, atrHandle, 5),
        GetPriceVsEMA(),
        GetEMACrossEvent(),
        GetEMAAlignment(emaFastHandle, emaSlowHandle),
        DoubleToString(macdMain, _Digits + 2),
        DoubleToString(macdSignal, _Digits + 2),
        GetMACDState(macdHandle),
        GetMACDHistogram(macdHandle),
        DoubleToString(bbUpper, _Digits),
        DoubleToString(bbMiddle, _Digits),
        DoubleToString(bbLower, _Digits),
        GetBBPosition(),
        GetBBSqueeze() ? "true" : "false",
        GetATRRegime(atrHandle),
        DoubleToString(GetCandleATRRatio(), 2),
        IsImpulseCandle() ? "true" : "false",
        IsMomentumExhaustion() ? "true" : "false",
        // H1 kontekst
        GetH1Trend(),
        GetRSIZone(h1_rsi),
        GetMACDState(h1_macdHandle),
        GetATRRegime(h1_atrHandle),
        // H4 kontekst
        GetH4Trend(),
        // Dnevni limiti
        IntegerToString(tradesToday),
        DoubleToString(dailyDrawdown, 2),
        dailyKillSwitch ? "true" : "false"
    );

    FileClose(handle);
    Print("Clawder: Data exported (H1/H4 context included)");
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
double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0.01;
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
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
void ReadAndExecuteDecision()
{
    string filename = DecisionFileName;

    if(!FileIsExist(filename, FILE_COMMON))
        return;

    int handle = FileOpen(filename, FILE_READ | FILE_CSV | FILE_COMMON, ',');
    if(handle == INVALID_HANDLE)
        return;

    // Čitaj header
    if(FileIsEnding(handle)) { FileClose(handle); return; }
    string header = FileReadString(handle);

    // Čitaj data
    if(FileIsEnding(handle)) { FileClose(handle); return; }

    string timestamp = FileReadString(handle);
    string action = FileReadString(handle);
    string confidence_str = FileReadString(handle);
    string sl_str = FileReadString(handle);
    string tp_str = FileReadString(handle);
    string reasoning = FileReadString(handle);

    FileClose(handle);

    // Provjeri da li je nova odluka
    datetime decisionTime = StringToTime(timestamp);
    if(decisionTime <= lastDecisionTime)
        return;

    lastDecisionTime = decisionTime;

    double confidence = StringToDouble(confidence_str);
    double sl = StringToDouble(sl_str);
    double tp = StringToDouble(tp_str);

    Print("Clawder Decision: ", action, " confidence=", confidence, " reasoning=", reasoning);

    // Obriši file odmah (čak i ako ne izvršimo trade)
    FileDelete(filename, FILE_COMMON);

    // ========== FILTERI ==========

    // 1. Confidence filter
    if(confidence < MinConfidence)
    {
        Print("Clawder: Confidence too low (", confidence, " < ", MinConfidence, ")");
        return;
    }

    // 2. Daily limits filter
    if(!CheckDailyLimits() && action != "CLOSE")
    {
        Print("Clawder: Daily limits reached (trades: ", tradesToday, ", kill switch: ", dailyKillSwitch, ")");
        return;
    }

    // 3. Spread filter (samo za nove pozicije)
    if((action == "BUY" || action == "SELL") && !CheckSpreadFilter())
    {
        return;
    }

    // 4. Već ima otvorenu poziciju?
    if(HasOpenPosition() && action != "CLOSE")
    {
        Print("Clawder: Already has open position");
        return;
    }

    // ========== IZVRŠENJE ==========
    double price, slPrice, tpPrice;
    int digits = _Digits;
    double atr = GetIndicatorValue(atrHandle, 0, 1);

    if(action == "BUY")
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        slPrice = (sl > 0) ? sl : price - 2 * atr;
        tpPrice = (tp > 0) ? tp : price + 3 * atr;
        slPrice = NormalizeDouble(slPrice, digits);
        tpPrice = NormalizeDouble(tpPrice, digits);

        double lots = CalculateLotSize(price - slPrice);

        if(trade.Buy(lots, _Symbol, price, slPrice, tpPrice, "Clawder AI BUY"))
        {
            Print("Clawder: BUY executed @ ", price);
            tradesToday++;
        }
    }
    else if(action == "SELL")
    {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        slPrice = (sl > 0) ? sl : price + 2 * atr;
        tpPrice = (tp > 0) ? tp : price - 3 * atr;
        slPrice = NormalizeDouble(slPrice, digits);
        tpPrice = NormalizeDouble(tpPrice, digits);

        double lots = CalculateLotSize(slPrice - price);

        if(trade.Sell(lots, _Symbol, price, slPrice, tpPrice, "Clawder AI SELL"))
        {
            Print("Clawder: SELL executed @ ", price);
            tradesToday++;
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
                    Print("Clawder: Position closed");
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
void OnTick()
{
    // Resetiraj dnevne brojače ako je novi dan
    ResetDailyCounters();

    // Uvijek provjeri za decision
    ReadAndExecuteDecision();

    // Na novi bar - eksportiraj podatke
    if(IsNewBar())
    {
        WriteDataFile();
    }
}
//+------------------------------------------------------------------+
