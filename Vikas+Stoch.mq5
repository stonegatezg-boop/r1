//+------------------------------------------------------------------+
//|                                                   Vikas+Stoch.mq5 |
//|                                    Vikas SuperTrend Indicator v1.0 |
//|                                         Created: 2026-02-02 14:30 |
//+------------------------------------------------------------------+
#property copyright "Vikas+Stoch"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2

//--- Plot SuperTrend Up
#property indicator_label1  "SuperTrend Up"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot SuperTrend Down
#property indicator_label2  "SuperTrend Down"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- Source types
enum ENUM_SOURCE_TYPE
{
   SOURCE_CLOSE,    // Close
   SOURCE_OPEN,     // Open
   SOURCE_HIGH,     // High
   SOURCE_LOW,      // Low
   SOURCE_HL2,      // HL2 (High+Low)/2
   SOURCE_HLC3,     // HLC3 (High+Low+Close)/3
   SOURCE_OHLC4     // OHLC4 (Open+High+Low+Close)/4
};

//--- Input Parameters
input int              ATR_Period     = 18;           // ATR Period
input ENUM_SOURCE_TYPE SourceType     = SOURCE_LOW;   // Source
input double           ATR_Multiplier = 2.8;          // ATR Multiplier
input bool             UseChangeATR   = false;        // Change ATR Calculation Method?
input bool             ShowSignals    = true;         // Show Buy/Sell Signals?

//--- Indicator Buffers
double UpTrendBuffer[];
double DownTrendBuffer[];
double TrendBuffer[];
double ATRBuffer[];

//--- Global Variables
datetime lastSignalTime = 0;
int lastSignalType = 0;  // 0=none, 1=buy, -1=sell

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set indicator buffers
   SetIndexBuffer(0, UpTrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, DownTrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, TrendBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, ATRBuffer, INDICATOR_CALCULATIONS);

   //--- Set empty values
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   //--- Indicator name
   IndicatorSetString(INDICATOR_SHORTNAME, "Vikas+Stoch(" +
                      IntegerToString(ATR_Period) + "," +
                      DoubleToString(ATR_Multiplier, 1) + ")");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Delete all Vikas arrows on deinit
   ObjectsDeleteAll(0, "VikasStoch_", 0, -1);
}

//+------------------------------------------------------------------+
//| Get source price based on selected type                           |
//+------------------------------------------------------------------+
double GetSourcePrice(const double &open[], const double &high[],
                      const double &low[], const double &close[], int index)
{
   switch(SourceType)
   {
      case SOURCE_CLOSE: return close[index];
      case SOURCE_OPEN:  return open[index];
      case SOURCE_HIGH:  return high[index];
      case SOURCE_LOW:   return low[index];
      case SOURCE_HL2:   return (high[index] + low[index]) / 2.0;
      case SOURCE_HLC3:  return (high[index] + low[index] + close[index]) / 3.0;
      case SOURCE_OHLC4: return (open[index] + high[index] + low[index] + close[index]) / 4.0;
      default:           return low[index];
   }
}

//+------------------------------------------------------------------+
//| Calculate ATR manually (SMA method)                               |
//+------------------------------------------------------------------+
double CalculateSMA_TR(const double &high[], const double &low[], const double &close[], int index, int period)
{
   if(index < period) return 0;

   double sum = 0;
   for(int i = 0; i < period; i++)
   {
      double tr;
      if(index - i == 0)
         tr = high[index - i] - low[index - i];
      else
         tr = MathMax(high[index - i] - low[index - i],
                      MathMax(MathAbs(high[index - i] - close[index - i - 1]),
                              MathAbs(low[index - i] - close[index - i - 1])));
      sum += tr;
   }
   return sum / period;
}

//+------------------------------------------------------------------+
//| Calculate ATR (EMA/RMA method - standard)                         |
//+------------------------------------------------------------------+
double CalculateATR(const double &high[], const double &low[], const double &close[], int index, int period, double prevATR)
{
   if(index < 1) return high[index] - low[index];

   double tr = MathMax(high[index] - low[index],
                       MathMax(MathAbs(high[index] - close[index - 1]),
                               MathAbs(low[index] - close[index - 1])));

   if(index < period)
      return tr;

   if(prevATR == 0)
      return CalculateSMA_TR(high, low, close, index, period);

   return (prevATR * (period - 1) + tr) / period;
}

//+------------------------------------------------------------------+
//| Create Buy Arrow                                                   |
//+------------------------------------------------------------------+
void CreateBuyArrow(datetime time, double price)
{
   string name = "VikasStoch_BUY_" + IntegerToString((long)time);

   if(ObjectFind(0, name) >= 0)
      return;

   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 233);  // Up arrow
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create Sell Arrow                                                  |
//+------------------------------------------------------------------+
void CreateSellArrow(datetime time, double price)
{
   string name = "VikasStoch_SELL_" + IntegerToString((long)time);

   if(ObjectFind(0, name) >= 0)
      return;

   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 234);  // Down arrow
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   //--- Check for minimum bars
   if(rates_total < ATR_Period + 1)
      return(0);

   //--- Set as series (oldest = index 0)
   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(UpTrendBuffer, false);
   ArraySetAsSeries(DownTrendBuffer, false);
   ArraySetAsSeries(TrendBuffer, false);
   ArraySetAsSeries(ATRBuffer, false);

   //--- Calculate starting position
   int start;
   if(prev_calculated == 0)
   {
      start = ATR_Period;

      //--- Initialize buffers
      for(int i = 0; i < start; i++)
      {
         UpTrendBuffer[i] = EMPTY_VALUE;
         DownTrendBuffer[i] = EMPTY_VALUE;
         TrendBuffer[i] = 1;
         ATRBuffer[i] = 0;
      }
   }
   else
      start = prev_calculated - 1;

   //--- Main calculation loop
   for(int i = start; i < rates_total; i++)
   {
      //--- Calculate ATR
      if(UseChangeATR)
         ATRBuffer[i] = CalculateATR(high, low, close, i, ATR_Period, i > 0 ? ATRBuffer[i-1] : 0);
      else
         ATRBuffer[i] = CalculateSMA_TR(high, low, close, i, ATR_Period);

      //--- Get source price
      double src = GetSourcePrice(open, high, low, close, i);

      //--- Calculate Up and Down bands
      double up = src - ATR_Multiplier * ATRBuffer[i];
      double dn = src + ATR_Multiplier * ATRBuffer[i];

      //--- Get previous values
      double up1 = (i > 0 && UpTrendBuffer[i-1] != EMPTY_VALUE) ? UpTrendBuffer[i-1] : up;
      double dn1 = (i > 0 && DownTrendBuffer[i-1] != EMPTY_VALUE) ? DownTrendBuffer[i-1] : dn;
      double prevClose = (i > 0) ? close[i-1] : close[i];

      //--- Adjust Up band
      if(prevClose > up1)
         up = MathMax(up, up1);

      //--- Adjust Down band
      if(prevClose < dn1)
         dn = MathMin(dn, dn1);

      //--- Determine trend
      double prevTrend = (i > 0) ? TrendBuffer[i-1] : 1;
      double trend;

      if(prevTrend == -1 && close[i] > dn1)
         trend = 1;
      else if(prevTrend == 1 && close[i] < up1)
         trend = -1;
      else
         trend = prevTrend;

      TrendBuffer[i] = trend;

      //--- Set plot values
      if(trend == 1)
      {
         UpTrendBuffer[i] = up;
         DownTrendBuffer[i] = EMPTY_VALUE;
      }
      else
      {
         UpTrendBuffer[i] = EMPTY_VALUE;
         DownTrendBuffer[i] = dn;
      }

      //--- Generate signals on confirmed bars only
      if(ShowSignals && i > 0 && i < rates_total - 1)  // Not on current forming bar
      {
         bool buySignal = (trend == 1 && TrendBuffer[i-1] == -1);
         bool sellSignal = (trend == -1 && TrendBuffer[i-1] == 1);

         if(buySignal)
         {
            CreateBuyArrow(time[i], low[i] - ATRBuffer[i] * 0.5);
         }

         if(sellSignal)
         {
            CreateSellArrow(time[i], high[i] + ATRBuffer[i] * 0.5);
         }
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
