//+------------------------------------------------------------------+
//|                                           XAUUSD_PatternEA.mq5   |
//|                 Based on 10-year statistical pattern analysis      |
//|                 Data: 230,400 M15 candles (2012-2022)             |
//+------------------------------------------------------------------+
//|  TOP PATTERNS IDENTIFIED (statistically significant, p<0.05):     |
//|                                                                    |
//|  BUY SIGNALS:                                                      |
//|  1. MACD bull cross + Stoch <30      WR:55.6% PF:1.458           |
//|  2. London open + uptrend + vol      WR:47.6% PF:1.371           |
//|  3. Volume dryup (accumulation)      WR:52.0% PF:1.232           |
//|  4. Volume spike bullish             WR:51.0% PF:1.167           |
//|  5. BB Squeeze bull breakout         WR:51.0% PF:1.134           |
//|  6. Stoch oversold cross up          WR:53.3% PF:1.083           |
//|                                                                    |
//|  SELL SIGNALS:                                                     |
//|  1. London open + downtrend + vol    WR:53.7% PF:1.552           |
//|                                                                    |
//|  NOTE: XAUUSD has strong long-term bullish bias.                  |
//|  Most short patterns showed negative expectancy.                   |
//|  This EA favors LONG positions as statistically validated.        |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Pattern EA - Statistical Analysis"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters - General
input group "=== GENERAL SETTINGS ==="
input double   LotSize           = 0.01;     // Lot Size
input int      MagicNumber       = 202602;   // Magic Number
input int      MaxSlippage       = 30;       // Max Slippage (points)

//--- Input Parameters - Risk Management
input group "=== RISK MANAGEMENT ==="
input double   ATR_SL_Multiplier = 1.0;      // Stop Loss = ATR x This
input double   ATR_TP_Multiplier = 1.5;      // Take Profit = ATR x This
input bool     UseTrailingStop   = true;      // Use Trailing Stop
input double   TrailStart_ATR    = 1.0;       // Start Trailing After ATR x This
input double   TrailStep_ATR     = 0.3;       // Trailing Step = ATR x This
input int      MaxBarsInTrade    = 12;        // Max Bars in Trade (0=disabled)

//--- Input Parameters - Signal Filters
input group "=== SIGNAL SELECTION ==="
input bool     Use_MACD_Stoch_Bull    = true;  // BUY: MACD Cross + Stoch Oversold (WR:55.6%)
input bool     Use_London_Trend_Bull  = true;  // BUY: London Open + Uptrend + Volume (PF:1.37)
input bool     Use_London_Trend_Bear  = true;  // SELL: London Open + Downtrend + Volume (PF:1.55)
input bool     Use_BB_Squeeze_Bull    = true;  // BUY: BB Squeeze Breakout (PF:1.13)
input bool     Use_Volume_Dryup_Bull  = true;  // BUY: Volume Dryup Accumulation (PF:1.23)
input bool     Use_Vol_Spike_Bull     = true;  // BUY: Volume Spike Bullish (PF:1.17)
input bool     Use_Stoch_Oversold     = true;  // BUY: Stoch Oversold Cross (WR:53.3%)
input int      MinSignalScore         = 2;     // Min Combined Score to Enter (1-5)

//--- Input Parameters - Session Filter
input group "=== SESSION FILTER ==="
input bool     TradeAsianSession      = false; // Trade Asian Session (00:00-07:00 UTC)
input bool     TradeLondonSession     = true;  // Trade London Session (07:00-13:00 UTC)
input bool     TradeNYSession         = true;  // Trade NY Session (13:00-20:00 UTC)
input bool     TradeLateNYSession     = false; // Trade Late NY (20:00-00:00 UTC)
input bool     AvoidFridayLateNY      = true;  // Avoid Friday after 20:00 UTC

//--- Input Parameters - Indicator Settings
input group "=== INDICATOR SETTINGS ==="
input int      ATR_Period         = 14;       // ATR Period
input int      RSI_Period         = 14;       // RSI Period
input int      BB_Period          = 20;       // Bollinger Bands Period
input double   BB_Deviation       = 2.0;      // Bollinger Bands Deviation
input int      MACD_Fast          = 12;       // MACD Fast EMA
input int      MACD_Slow          = 26;       // MACD Slow EMA
input int      MACD_Signal        = 9;        // MACD Signal Period
input int      Stoch_K            = 14;       // Stochastic K Period
input int      Stoch_D            = 3;        // Stochastic D Period
input int      Stoch_Slowing      = 3;        // Stochastic Slowing
input int      EMA_Fast           = 9;        // Fast EMA Period
input int      EMA_Slow           = 21;       // Slow EMA Period
input int      SMA_Period         = 20;       // SMA Period for trend

//--- Global Variables
CTrade         trade;
datetime       lastBarTime        = 0;
datetime       entryBarTime       = 0;
int            barsInTrade        = 0;

//--- Indicator handles
int            hATR, hRSI, hBB, hMACD, hStoch, hEMAFast, hEMASlow, hSMA;
int            hVolSMA;

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Create indicator handles
   hATR      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   hRSI      = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   hBB       = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   hMACD     = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hStoch    = iStochastic(_Symbol, PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   hEMAFast  = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow  = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hSMA      = iMA(_Symbol, PERIOD_CURRENT, SMA_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE || hRSI == INVALID_HANDLE || hBB == INVALID_HANDLE ||
      hMACD == INVALID_HANDLE || hStoch == INVALID_HANDLE || hEMAFast == INVALID_HANDLE ||
      hEMASlow == INVALID_HANDLE || hSMA == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles!");
      return(INIT_FAILED);
   }

   Print("XAUUSD Pattern EA initialized successfully");
   Print("Min Signal Score: ", MinSignalScore);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE)      IndicatorRelease(hATR);
   if(hRSI != INVALID_HANDLE)      IndicatorRelease(hRSI);
   if(hBB != INVALID_HANDLE)       IndicatorRelease(hBB);
   if(hMACD != INVALID_HANDLE)     IndicatorRelease(hMACD);
   if(hStoch != INVALID_HANDLE)    IndicatorRelease(hStoch);
   if(hEMAFast != INVALID_HANDLE)  IndicatorRelease(hEMAFast);
   if(hEMASlow != INVALID_HANDLE)  IndicatorRelease(hEMASlow);
   if(hSMA != INVALID_HANDLE)      IndicatorRelease(hSMA);
}

//+------------------------------------------------------------------+
//| Get indicator value                                                |
//+------------------------------------------------------------------+
double GetIndicator(int handle, int buffer, int shift)
{
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) == 1)
      return val[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Get pip value for gold                                             |
//+------------------------------------------------------------------+
double GetPipValue()
{
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
      return 0.1;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
      return _Point * 10;
   return _Point;
}

//+------------------------------------------------------------------+
//| Check session filter                                               |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   int dow  = dt.day_of_week;  // 0=Sun, 5=Fri

   // Friday late session filter
   if(AvoidFridayLateNY && dow == 5 && hour >= 20)
      return false;

   // Session filters
   if(hour >= 0 && hour < 7)
      return TradeAsianSession;
   if(hour >= 7 && hour < 13)
      return TradeLondonSession;
   if(hour >= 13 && hour < 20)
      return TradeNYSession;
   if(hour >= 20)
      return TradeLateNYSession;

   return false;
}

//+------------------------------------------------------------------+
//| Check if we have an open position                                  |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE &posType, ulong &posTicket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            posTicket = ticket;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions                                                |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            trade.PositionClose(ticket);
            Print("Position closed: ", reason);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get volume ratio (current vs 20-period SMA)                       |
//+------------------------------------------------------------------+
double GetVolumeRatio(int shift)
{
   long vol = iVolume(_Symbol, PERIOD_CURRENT, shift);
   double volSum = 0;
   for(int i = shift; i < shift + 20; i++)
   {
      volSum += (double)iVolume(_Symbol, PERIOD_CURRENT, i);
   }
   double volAvg = volSum / 20.0;
   if(volAvg == 0) return 1.0;
   return (double)vol / volAvg;
}

//+------------------------------------------------------------------+
//| Check if candle is bullish/bearish                                 |
//+------------------------------------------------------------------+
bool IsBullish(int shift)
{
   return iClose(_Symbol, PERIOD_CURRENT, shift) > iOpen(_Symbol, PERIOD_CURRENT, shift);
}

bool IsBearish(int shift)
{
   return iClose(_Symbol, PERIOD_CURRENT, shift) < iOpen(_Symbol, PERIOD_CURRENT, shift);
}

//+------------------------------------------------------------------+
//| Get Bollinger Band width percentile                                |
//+------------------------------------------------------------------+
bool IsBBSqueezing()
{
   double bbUpper = GetIndicator(hBB, 1, 1);
   double bbLower = GetIndicator(hBB, 2, 1);
   double bbMid   = GetIndicator(hBB, 0, 1);

   if(bbMid == 0) return false;
   double currentWidth = (bbUpper - bbLower) / bbMid;

   // Compare with recent history
   int squeezeCount = 0;
   for(int i = 2; i < 202; i++)
   {
      double u = GetIndicator(hBB, 1, i);
      double l = GetIndicator(hBB, 2, i);
      double m = GetIndicator(hBB, 0, i);
      if(m == 0) continue;
      double w = (u - l) / m;
      if(currentWidth < w)
         squeezeCount++;
   }

   // If current width is in bottom 20% -> squeeze
   return (squeezeCount > 160);
}

//+------------------------------------------------------------------+
//| SIGNAL: MACD Bull Cross + Stoch Oversold (WR:55.6%, PF:1.458)    |
//+------------------------------------------------------------------+
int Signal_MACD_Stoch_Bull()
{
   if(!Use_MACD_Stoch_Bull) return 0;

   double macd1    = GetIndicator(hMACD, 0, 1);  // MACD line bar 1
   double signal1  = GetIndicator(hMACD, 1, 1);  // Signal line bar 1
   double macd2    = GetIndicator(hMACD, 0, 2);  // MACD line bar 2
   double signal2  = GetIndicator(hMACD, 1, 2);  // Signal line bar 2
   double stochK1  = GetIndicator(hStoch, 0, 1); // Stoch K bar 1

   // MACD bullish crossover with Stoch < 30
   if(macd1 > signal1 && macd2 <= signal2 && stochK1 < 30)
      return 1;  // BUY signal

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL: London Open + Trend + Volume (BUY PF:1.37, SELL PF:1.55) |
//+------------------------------------------------------------------+
int Signal_London_Trend()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour != 7) return 0;  // Only at London open

   double close1   = iClose(_Symbol, PERIOD_CURRENT, 1);
   double sma1     = GetIndicator(hSMA, 0, 1);
   double emaF1    = GetIndicator(hEMAFast, 0, 1);
   double emaS1    = GetIndicator(hEMASlow, 0, 1);
   double volRatio = GetVolumeRatio(1);

   // BUY: London open + uptrend + volume
   if(Use_London_Trend_Bull && close1 > sma1 && emaF1 > emaS1 && IsBullish(1) && volRatio > 1.2)
      return 1;

   // SELL: London open + downtrend + volume
   if(Use_London_Trend_Bear && close1 < sma1 && emaF1 < emaS1 && IsBearish(1) && volRatio > 1.2)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL: BB Squeeze Breakout (PF:1.134)                            |
//+------------------------------------------------------------------+
int Signal_BB_Squeeze_Bull()
{
   if(!Use_BB_Squeeze_Bull) return 0;

   double atr1   = GetIndicator(hATR, 0, 1);
   double range1 = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
   double volRatio = GetVolumeRatio(1);

   // BB squeeze + bullish breakout candle + volume
   if(IsBBSqueezing() && IsBullish(1) && range1 > atr1 * 1.2 && volRatio > 1.5)
      return 1;

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL: Volume Dryup Accumulation (PF:1.232)                      |
//+------------------------------------------------------------------+
int Signal_Volume_Dryup()
{
   if(!Use_Volume_Dryup_Bull) return 0;

   double volRatio = GetVolumeRatio(1);

   // Volume < 30% of average -> accumulation phase
   if(volRatio < 0.3)
      return 1;  // Mild BUY bias (high frequency, use as confirmation only)

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL: Volume Spike Bullish (PF:1.167)                           |
//+------------------------------------------------------------------+
int Signal_Volume_Spike_Bull()
{
   if(!Use_Vol_Spike_Bull) return 0;

   double volRatio = GetVolumeRatio(1);

   // Volume > 2x average + bullish candle
   if(volRatio > 2.0 && IsBullish(1))
      return 1;

   return 0;
}

//+------------------------------------------------------------------+
//| SIGNAL: Stochastic Oversold Cross (WR:53.3%)                      |
//+------------------------------------------------------------------+
int Signal_Stoch_Oversold()
{
   if(!Use_Stoch_Oversold) return 0;

   double stochK1 = GetIndicator(hStoch, 0, 1);
   double stochD1 = GetIndicator(hStoch, 1, 1);
   double stochK2 = GetIndicator(hStoch, 0, 2);
   double stochD2 = GetIndicator(hStoch, 1, 2);

   // K crosses above D below 25
   if(stochK1 > stochD1 && stochK2 <= stochD2 && stochK1 < 25)
      return 1;

   return 0;
}

//+------------------------------------------------------------------+
//| Calculate combined signal score                                    |
//+------------------------------------------------------------------+
int CalculateSignalScore(int &buyScore, int &sellScore)
{
   buyScore = 0;
   sellScore = 0;

   // High-value signals (higher weight)
   int macdStoch = Signal_MACD_Stoch_Bull();
   if(macdStoch > 0) buyScore += 2;  // Weight: 2 (WR:55.6%, PF:1.458)

   int londonTrend = Signal_London_Trend();
   if(londonTrend > 0) buyScore += 2;   // Weight: 2 (PF:1.371)
   if(londonTrend < 0) sellScore += 3;  // Weight: 3 (PF:1.552 - BEST sell signal)

   // Medium-value signals
   int bbSqueeze = Signal_BB_Squeeze_Bull();
   if(bbSqueeze > 0) buyScore += 1;  // Weight: 1

   int volSpike = Signal_Volume_Spike_Bull();
   if(volSpike > 0) buyScore += 1;  // Weight: 1

   int stochOversold = Signal_Stoch_Oversold();
   if(stochOversold > 0) buyScore += 1;  // Weight: 1

   // Low-value confirmation signals (only adds score, not enough alone)
   int volDryup = Signal_Volume_Dryup();
   if(volDryup > 0) buyScore += 1;  // Weight: 1 (high frequency, confirmation only)

   return (buyScore > sellScore) ? buyScore : -sellScore;
}

//+------------------------------------------------------------------+
//| Manage trailing stop                                               |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!UseTrailingStop) return;

   double atr = GetIndicator(hATR, 0, 1);
   double trailStart = atr * TrailStart_ATR;
   double trailStep  = atr * TrailStep_ATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;

         if(profit >= trailStart)
         {
            double newSL = bid - trailStep;
            newSL = NormalizeDouble(newSL, _Digits);

            if(newSL > currentSL || currentSL == 0)
            {
               trade.PositionModify(ticket, newSL, currentTP);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;

         if(profit >= trailStart)
         {
            double newSL = ask + trailStep;
            newSL = NormalizeDouble(newSL, _Digits);

            if(newSL < currentSL || currentSL == 0)
            {
               trade.PositionModify(ticket, newSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Trailing stop management (every tick)
   ManageTrailingStop();

   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Check position status
   ENUM_POSITION_TYPE posType;
   ulong posTicket;
   bool hasPosition = HasOpenPosition(posType, posTicket);

   // Time-based exit
   if(hasPosition && MaxBarsInTrade > 0)
   {
      barsInTrade++;
      if(barsInTrade >= MaxBarsInTrade)
      {
         CloseAllPositions("Max bars in trade reached (" + IntegerToString(MaxBarsInTrade) + ")");
         hasPosition = false;
         barsInTrade = 0;
      }
   }

   // Session filter
   if(!IsSessionAllowed())
   {
      // Close positions if session ends
      if(hasPosition)
         CloseAllPositions("Session filter - outside trading hours");
      return;
   }

   // Calculate signals
   int buyScore = 0, sellScore = 0;
   int totalScore = CalculateSignalScore(buyScore, sellScore);

   // --- ENTRY LOGIC ---
   if(!hasPosition)
   {
      double atr = GetIndicator(hATR, 0, 1);
      if(atr == 0) return;

      // BUY Entry
      if(buyScore >= MinSignalScore)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl  = NormalizeDouble(ask - atr * ATR_SL_Multiplier, _Digits);
         double tp  = NormalizeDouble(ask + atr * ATR_TP_Multiplier, _Digits);

         string comment = StringFormat("BUY Score:%d", buyScore);

         if(trade.Buy(LotSize, _Symbol, ask, sl, tp, comment))
         {
            Print("BUY opened | Score: ", buyScore, " | SL: ", sl, " | TP: ", tp);
            entryBarTime = currentBarTime;
            barsInTrade = 0;
         }
      }
      // SELL Entry
      else if(sellScore >= MinSignalScore)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl  = NormalizeDouble(bid + atr * ATR_SL_Multiplier, _Digits);
         double tp  = NormalizeDouble(bid - atr * ATR_TP_Multiplier, _Digits);

         string comment = StringFormat("SELL Score:%d", sellScore);

         if(trade.Sell(LotSize, _Symbol, bid, sl, tp, comment))
         {
            Print("SELL opened | Score: ", sellScore, " | SL: ", sl, " | TP: ", tp);
            entryBarTime = currentBarTime;
            barsInTrade = 0;
         }
      }
   }
   // --- EXIT on opposite signal ---
   else
   {
      if(posType == POSITION_TYPE_BUY && sellScore >= MinSignalScore)
      {
         CloseAllPositions("Opposite SELL signal (Score: " + IntegerToString(sellScore) + ")");
      }
      else if(posType == POSITION_TYPE_SELL && buyScore >= MinSignalScore)
      {
         CloseAllPositions("Opposite BUY signal (Score: " + IntegerToString(buyScore) + ")");
      }
   }
}
//+------------------------------------------------------------------+
