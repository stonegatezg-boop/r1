//+------------------------------------------------------------------+
//|                                    VIKAS_SuperTrend_Gann_TSL.mq5 |
//|                        Based on TradingView indicator by VIKAS   |
//|                                         Created: 2026-02-02 14:30 |
//+------------------------------------------------------------------+
#property copyright "Based on TradingView indicator"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2

//--- Plot Up Trend
#property indicator_label1  "Up Trend"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot Down Trend
#property indicator_label2  "Down Trend"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- Input parameters
input group "SuperTrend Parameters"
input int      InpATRPeriod      = 18;     // ATR Period
input ENUM_APPLIED_PRICE InpSource = PRICE_LOW;  // Source
input double   InpATRMultiplier  = 2.8;    // ATR Multiplier
input bool     InpChangeATR      = false;  // Change ATR Calculation Method?
input bool     InpShowSignals    = true;   // Show Buy/Sell Signals?

//--- Indicator buffers
double UpTrendBuffer[];
double DownTrendBuffer[];
double TrendBuffer[];
double ATRBuffer[];

//--- Global variables
int atrHandle;
datetime lastAlertTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpATRPeriod < 1)
   {
      Print("ATR Period must be at least 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- Set indicator buffers
   SetIndexBuffer(0, UpTrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, DownTrendBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, TrendBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, ATRBuffer, INDICATOR_CALCULATIONS);

   //--- Set empty value
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   //--- Initialize ATR indicator
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle");
      return(INIT_FAILED);
   }

   //--- Set indicator short name
   IndicatorSetString(INDICATOR_SHORTNAME, "VIKAS SuperTrend(" + IntegerToString(InpATRPeriod) + ", " + DoubleToString(InpATRMultiplier, 1) + ")");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   ObjectsDeleteAll(0, "VIKAS_");
}

//+------------------------------------------------------------------+
//| Get source price based on input                                  |
//+------------------------------------------------------------------+
double GetSourcePrice(int index, const double &high[], const double &low[], const double &close[])
{
   switch(InpSource)
   {
      case PRICE_HIGH:
         return high[index];
      case PRICE_LOW:
         return low[index];
      case PRICE_CLOSE:
         return close[index];
      case PRICE_OPEN:
         return close[index]; // Using close as proxy for open in this context
      case PRICE_MEDIAN:
         return (high[index] + low[index]) / 2.0;  // hl2
      case PRICE_TYPICAL:
         return (high[index] + low[index] + close[index]) / 3.0;  // hlc3
      case PRICE_WEIGHTED:
         return (high[index] + low[index] + close[index] + close[index]) / 4.0;  // hlcc4
      default:
         return (high[index] + low[index]) / 2.0;  // hl2
   }
}

//+------------------------------------------------------------------+
//| Calculate SMA of True Range                                      |
//+------------------------------------------------------------------+
double CalculateSMA_TR(int index, int period, const double &high[], const double &low[], const double &close[], int rates_total)
{
   double sum = 0;
   int count = 0;

   for(int i = 0; i < period && (index + i) < rates_total; i++)
   {
      double tr;
      if(index + i + 1 < rates_total)
      {
         double highLow = high[index + i] - low[index + i];
         double highClose = MathAbs(high[index + i] - close[index + i + 1]);
         double lowClose = MathAbs(low[index + i] - close[index + i + 1]);
         tr = MathMax(highLow, MathMax(highClose, lowClose));
      }
      else
      {
         tr = high[index + i] - low[index + i];
      }
      sum += tr;
      count++;
   }

   return (count > 0) ? sum / count : 0;
}

//+------------------------------------------------------------------+
//| Create signal arrow                                              |
//+------------------------------------------------------------------+
void CreateSignalArrow(string name, datetime time, double price, bool isBuy)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, isBuy ? 233 : 234);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrGreen : clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, isBuy ? ANCHOR_TOP : ANCHOR_BOTTOM);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   if(rates_total < InpATRPeriod + 1)
      return(0);

   //--- Copy ATR values if using standard ATR
   if(InpChangeATR)
   {
      if(CopyBuffer(atrHandle, 0, 0, rates_total, ATRBuffer) <= 0)
         return(0);
   }

   //--- Set arrays as series (index 0 = current bar)
   ArraySetAsSeries(UpTrendBuffer, true);
   ArraySetAsSeries(DownTrendBuffer, true);
   ArraySetAsSeries(TrendBuffer, true);
   ArraySetAsSeries(ATRBuffer, true);
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   //--- Calculate starting position
   int start;
   if(prev_calculated == 0)
   {
      start = rates_total - InpATRPeriod - 2;
      for(int i = rates_total - 1; i > start; i--)
      {
         UpTrendBuffer[i] = EMPTY_VALUE;
         DownTrendBuffer[i] = EMPTY_VALUE;
         TrendBuffer[i] = 1;
      }
   }
   else
   {
      start = rates_total - prev_calculated + 1;
      if(start < 0) start = 0;
   }

   //--- Main calculation loop (from oldest to newest)
   for(int i = start; i >= 0; i--)
   {
      //--- Calculate ATR
      double atr;
      if(InpChangeATR)
      {
         atr = ATRBuffer[i];
      }
      else
      {
         atr = CalculateSMA_TR(i, InpATRPeriod, high, low, close, rates_total);
      }

      //--- Get source price
      double src = GetSourcePrice(i, high, low, close);

      //--- Calculate Up and Down bands
      double up = src - InpATRMultiplier * atr;
      double dn = src + InpATRMultiplier * atr;

      //--- Get previous values
      double up1 = (i < rates_total - InpATRPeriod - 1 && UpTrendBuffer[i + 1] != EMPTY_VALUE) ? UpTrendBuffer[i + 1] : up;
      double dn1 = (i < rates_total - InpATRPeriod - 1 && DownTrendBuffer[i + 1] != EMPTY_VALUE) ? DownTrendBuffer[i + 1] : dn;

      // Use stored trend values for previous up/dn
      if(i + 1 < rates_total)
      {
         if(TrendBuffer[i + 1] == 1 && UpTrendBuffer[i + 1] != EMPTY_VALUE)
            up1 = UpTrendBuffer[i + 1];
         if(TrendBuffer[i + 1] == -1 && DownTrendBuffer[i + 1] != EMPTY_VALUE)
            dn1 = DownTrendBuffer[i + 1];
      }

      //--- Adjust bands based on previous close
      if(i + 1 < rates_total)
      {
         if(close[i + 1] > up1)
            up = MathMax(up, up1);
         if(close[i + 1] < dn1)
            dn = MathMin(dn, dn1);
      }

      //--- Determine trend
      double trendPrev = (i + 1 < rates_total) ? TrendBuffer[i + 1] : 1;
      double trend;

      if(trendPrev == -1 && close[i] > dn1)
         trend = 1;
      else if(trendPrev == 1 && close[i] < up1)
         trend = -1;
      else
         trend = trendPrev;

      TrendBuffer[i] = trend;

      //--- Set buffer values based on trend
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

      //--- Generate signals
      bool buySignal = (trend == 1 && trendPrev == -1);
      bool sellSignal = (trend == -1 && trendPrev == 1);

      //--- Create visual signals
      if(InpShowSignals && i > 0)
      {
         if(buySignal)
         {
            string arrowName = "VIKAS_BuyArrow_" + IntegerToString(time[i]);
            CreateSignalArrow(arrowName, time[i], up, true);
         }
         if(sellSignal)
         {
            string arrowName = "VIKAS_SellArrow_" + IntegerToString(time[i]);
            CreateSignalArrow(arrowName, time[i], dn, false);
         }
      }

      //--- Alerts for current bar
      if(i == 1 && time[i] > lastAlertTime)
      {
         if(buySignal)
         {
            Alert("VIKAS SuperTrend Buy Signal on ", _Symbol);
            lastAlertTime = time[i];
         }
         else if(sellSignal)
         {
            Alert("VIKAS SuperTrend Sell Signal on ", _Symbol);
            lastAlertTime = time[i];
         }
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
