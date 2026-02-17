//+------------------------------------------------------------------+
//|                                              Clawder_Bridge.mq5  |
//|                        *** Clawder Bridge v1.0 ***               |
//|                   MT5 <-> Python <-> Claude AI Bridge            |
//|                   Date: 2026-02-17 17:00 (Zagreb, CET)           |
//+------------------------------------------------------------------+
#property copyright "Clawder Bridge v1.0 (2026-02-17)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== INDIKATORI ==="
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
input double   MinConfidence    = 0.7;      // Min confidence za trade (0.0-1.0)
input int      Slippage         = 30;

input group "=== FILE PATHS ==="
input string   DataFileName     = "clawder_data.csv";
input string   DecisionFileName = "clawder_decision.csv";

input group "=== OPĆE POSTAVKE ==="
input ulong    MagicNumber      = 999999;

//--- Global variables
CTrade         trade;
int            rsiHandle, emaFastHandle, emaSlowHandle, emaTrendHandle, emaLongHandle;
int            macdHandle, atrHandle, bbHandle;
datetime       lastBarTime = 0;
datetime       lastDecisionTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Kreiraj indikatore
    rsiHandle = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
    emaFastHandle = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    emaSlowHandle = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    emaTrendHandle = iMA(_Symbol, PERIOD_M5, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
    emaLongHandle = iMA(_Symbol, PERIOD_M5, EMA_Long, 0, MODE_EMA, PRICE_CLOSE);
    macdHandle = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    atrHandle = iATR(_Symbol, PERIOD_M5, ATR_Period);
    bbHandle = iBands(_Symbol, PERIOD_M5, BB_Period, 0, BB_Deviation, PRICE_CLOSE);

    // H1 indikatori za kontekst
    // (dodajemo kasnije ako treba)

    if(rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE ||
       atrHandle == INVALID_HANDLE || bbHandle == INVALID_HANDLE)
    {
        Print("Greška pri kreiranju indikatora!");
        return INIT_FAILED;
    }

    Print("=== Clawder Bridge v1.0 (2026-02-17 17:00 Zagreb) ===");
    Print("Data file: ", DataFileName);
    Print("Decision file: ", DecisionFileName);
    Print("Min confidence: ", MinConfidence);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
    if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
    if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
    if(emaTrendHandle != INVALID_HANDLE) IndicatorRelease(emaTrendHandle);
    if(emaLongHandle != INVALID_HANDLE) IndicatorRelease(emaLongHandle);
    if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
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
string GetEMASlope(int handle, int periods)
{
    double current = GetIndicatorValue(handle, 0, 1);
    double previous = GetIndicatorValue(handle, 0, periods + 1);

    if(current == 0 || previous == 0) return "unknown";

    double diff = current - previous;
    double atr = GetIndicatorValue(atrHandle, 0, 1);
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
string GetMACDState()
{
    double macdMain1 = GetIndicatorValue(macdHandle, 0, 1);
    double macdSignal1 = GetIndicatorValue(macdHandle, 1, 1);
    double macdMain2 = GetIndicatorValue(macdHandle, 0, 2);
    double macdSignal2 = GetIndicatorValue(macdHandle, 1, 2);

    bool aboveNow = macdMain1 > macdSignal1;
    bool abovePrev = macdMain2 > macdSignal2;

    if(aboveNow && !abovePrev) return "cross_up";
    if(!aboveNow && abovePrev) return "cross_down";
    if(aboveNow) return "bullish";
    if(!aboveNow) return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetMACDHistogram()
{
    double hist1 = GetIndicatorValue(macdHandle, 0, 1) - GetIndicatorValue(macdHandle, 1, 1);
    double hist2 = GetIndicatorValue(macdHandle, 0, 2) - GetIndicatorValue(macdHandle, 1, 2);

    if(hist1 > 0 && hist1 > hist2) return "growing_positive";
    if(hist1 > 0 && hist1 < hist2) return "shrinking_positive";
    if(hist1 < 0 && hist1 < hist2) return "growing_negative";
    if(hist1 < 0 && hist1 > hist2) return "shrinking_negative";
    return "neutral";
}

//+------------------------------------------------------------------+
string GetATRRegime()
{
    double atr = GetIndicatorValue(atrHandle, 0, 1);

    // Izračunaj prosječni ATR zadnjih 20 barova
    double sum = 0;
    for(int i = 1; i <= 20; i++)
        sum += GetIndicatorValue(atrHandle, 0, i);
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

    // Prosječna širina zadnjih 20 barova
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
    // EVENT: da li se cross UPRAVO DOGODIO na zadnjoj svijeći
    double fast1 = GetIndicatorValue(emaFastHandle, 0, 1);
    double slow1 = GetIndicatorValue(emaSlowHandle, 0, 1);
    double fast2 = GetIndicatorValue(emaFastHandle, 0, 2);
    double slow2 = GetIndicatorValue(emaSlowHandle, 0, 2);

    if(fast1 > slow1 && fast2 < slow2) return "golden";
    if(fast1 < slow1 && fast2 > slow2) return "death";
    return "none";
}

//+------------------------------------------------------------------+
string GetEMAAlignment()
{
    // STATE: trenutni odnos fast vs slow EMA
    double fast = GetIndicatorValue(emaFastHandle, 0, 1);
    double slow = GetIndicatorValue(emaSlowHandle, 0, 1);

    if(fast > slow) return "bullish";
    if(fast < slow) return "bearish";
    return "neutral";
}

//+------------------------------------------------------------------+
double GetCandleATRRatio()
{
    // Omjer zadnje svijeće i ATR-a
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
    // Impulse candle = range > 2x ATR
    return GetCandleATRRatio() > 2.0;
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

    // Header
    FileWrite(handle, "timestamp", "symbol", "price", "atr",
              "rsi_value", "rsi_zone",
              "ema_fast", "ema_slow", "ema_trend", "ema_long",
              "ema_slope", "ema_position", "ema_cross_event", "ema_alignment",
              "macd_main", "macd_signal", "macd_state", "macd_histogram",
              "bb_upper", "bb_middle", "bb_lower", "bb_position", "bb_squeeze",
              "atr_regime", "candle_atr_ratio", "impulse_candle");

    // Data
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

    FileWrite(handle,
              TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
              _Symbol,
              DoubleToString(price, _Digits),
              DoubleToString(atr, _Digits),
              DoubleToString(rsi, 2),
              GetRSIZone(rsi),
              DoubleToString(emaFast, _Digits),
              DoubleToString(emaSlow, _Digits),
              DoubleToString(emaTrend, _Digits),
              DoubleToString(emaLong, _Digits),
              GetEMASlope(emaTrendHandle, 5),
              GetPriceVsEMA(),
              GetEMACrossEvent(),
              GetEMAAlignment(),
              DoubleToString(macdMain, _Digits + 2),
              DoubleToString(macdSignal, _Digits + 2),
              GetMACDState(),
              GetMACDHistogram(),
              DoubleToString(bbUpper, _Digits),
              DoubleToString(bbMiddle, _Digits),
              DoubleToString(bbLower, _Digits),
              GetBBPosition(),
              GetBBSqueeze() ? "true" : "false",
              GetATRRegime(),
              DoubleToString(GetCandleATRRatio(), 2),
              IsImpulseCandle() ? "true" : "false");

    FileClose(handle);
    Print("Clawder: Data exported to ", filename);
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
    string header = FileReadString(handle);  // Skip header line

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

    // Provjeri confidence
    if(confidence < MinConfidence)
    {
        Print("Clawder: Confidence too low (", confidence, " < ", MinConfidence, ")");
        return;
    }

    // Već ima otvorenu poziciju?
    if(HasOpenPosition() && action != "CLOSE")
    {
        Print("Clawder: Already has open position");
        return;
    }

    // Izvrši
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
            Print("Clawder: BUY executed @ ", price);
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
            Print("Clawder: SELL executed @ ", price);
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

    // Obriši decision file nakon izvršenja
    FileDelete(filename, FILE_COMMON);
}

//+------------------------------------------------------------------+
void OnTick()
{
    // Uvijek provjeri za decision
    ReadAndExecuteDecision();

    // Na novi bar - eksportiraj podatke
    if(IsNewBar())
    {
        WriteDataFile();
    }
}
//+------------------------------------------------------------------+
