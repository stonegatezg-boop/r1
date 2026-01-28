//+------------------------------------------------------------------+
//|                                               ChandelierExit.mq5 |
//|                        Based on TradingView indicator by everget |
//|                                             GPL-3.0 license      |
//+------------------------------------------------------------------+
#property copyright "Based on TradingView indicator by Alex Orekhov (everget)"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2

//--- Plot Long Stop
#property indicator_label1  "Long Stop"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot Short Stop
#property indicator_label2  "Short Stop"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- Input parameters
input group "Calculation"
input int    InpATRPeriod    = 10;      // ATR Period
input double InpATRMultiplier = 3.2;    // ATR Multiplier
input bool   InpUseClose     = true;    // Use Close Price for Extremums

input group "Visuals"
input bool   InpShowLabels   = true;    // Show Buy/Sell Labels
input bool   InpHighlightState = true;  // Highlight State

input group "Alerts"
input bool   InpAwaitBarConfirmation = true; // Await Bar Confirmation

//--- Indicator buffers
double LongStopBuffer[];
double ShortStopBuffer[];
double DirectionBuffer[];
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
   SetIndexBuffer(0, LongStopBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ShortStopBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, DirectionBuffer, INDICATOR_CALCULATIONS);
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
   IndicatorSetString(INDICATOR_SHORTNAME, "CE(" + IntegerToString(InpATRPeriod) + ", " + DoubleToString(InpATRMultiplier, 1) + ")");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release ATR handle
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   //--- Remove all objects created by indicator
   ObjectsDeleteAll(0, "CE_");
}

//+------------------------------------------------------------------+
//| Get highest value over period                                    |
//+------------------------------------------------------------------+
double GetHighest(int index, int period, const double &high[], const double &close[], bool useClose)
{
   double highest = useClose ? close[index] : high[index];
   for(int i = 1; i < period && (index + i) < ArraySize(high); i++)
   {
      double val = useClose ? close[index + i] : high[index + i];
      if(val > highest)
         highest = val;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Get lowest value over period                                     |
//+------------------------------------------------------------------+
double GetLowest(int index, int period, const double &low[], const double &close[], bool useClose)
{
   double lowest = useClose ? close[index] : low[index];
   for(int i = 1; i < period && (index + i) < ArraySize(low); i++)
   {
      double val = useClose ? close[index + i] : low[index + i];
      if(val < lowest)
         lowest = val;
   }
   return lowest;
}

//+------------------------------------------------------------------+
//| Create arrow object for signals                                  |
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
//| Create text label for signals                                    |
//+------------------------------------------------------------------+
void CreateSignalLabel(string name, datetime time, double price, bool isBuy)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_TEXT, 0, time, price);
   ObjectSetString(0, name, OBJPROP_TEXT, isBuy ? "Buy" : "Sell");
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrGreen : clrRed);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, isBuy ? ANCHOR_LOWER : ANCHOR_UPPER);
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

   //--- Copy ATR values
   if(CopyBuffer(atrHandle, 0, 0, rates_total, ATRBuffer) <= 0)
      return(0);

   //--- Set arrays as series (index 0 = current bar)
   ArraySetAsSeries(LongStopBuffer, true);
   ArraySetAsSeries(ShortStopBuffer, true);
   ArraySetAsSeries(DirectionBuffer, true);
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
      //--- Initialize buffers
      for(int i = rates_total - 1; i > start; i--)
      {
         LongStopBuffer[i] = EMPTY_VALUE;
         ShortStopBuffer[i] = EMPTY_VALUE;
         DirectionBuffer[i] = 1;
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
      double atr = InpATRMultiplier * ATRBuffer[i];

      //--- Calculate Long Stop
      double highestHigh = GetHighest(i, InpATRPeriod, high, close, InpUseClose);
      double longStop = highestHigh - atr;
      double longStopPrev = (i < rates_total - InpATRPeriod - 1) ? LongStopBuffer[i + 1] : longStop;
      if(longStopPrev == EMPTY_VALUE) longStopPrev = longStop;

      if(close[i + 1] > longStopPrev)
         longStop = MathMax(longStop, longStopPrev);

      //--- Calculate Short Stop
      double lowestLow = GetLowest(i, InpATRPeriod, low, close, InpUseClose);
      double shortStop = lowestLow + atr;
      double shortStopPrev = (i < rates_total - InpATRPeriod - 1) ? ShortStopBuffer[i + 1] : shortStop;
      if(shortStopPrev == EMPTY_VALUE) shortStopPrev = shortStop;

      if(close[i + 1] < shortStopPrev)
         shortStop = MathMin(shortStop, shortStopPrev);

      //--- Determine direction
      double dirPrev = (i < rates_total - InpATRPeriod - 1) ? DirectionBuffer[i + 1] : 1;
      double dir;

      if(close[i] > shortStopPrev)
         dir = 1;
      else if(close[i] < longStopPrev)
         dir = -1;
      else
         dir = dirPrev;

      DirectionBuffer[i] = dir;

      //--- Set buffer values based on direction
      if(dir == 1)
      {
         LongStopBuffer[i] = longStop;
         ShortStopBuffer[i] = EMPTY_VALUE;
      }
      else
      {
         LongStopBuffer[i] = EMPTY_VALUE;
         ShortStopBuffer[i] = shortStop;
      }

      //--- Detect signals
      bool buySignal = (dir == 1 && dirPrev == -1);
      bool sellSignal = (dir == -1 && dirPrev == 1);

      //--- Create visual objects for signals
      if(InpShowLabels && i > 0)  // Don't create on current bar unless confirmed
      {
         if(buySignal)
         {
            string arrowName = "CE_BuyArrow_" + IntegerToString(time[i]);
            string labelName = "CE_BuyLabel_" + IntegerToString(time[i]);
            CreateSignalArrow(arrowName, time[i], longStop, true);
            CreateSignalLabel(labelName, time[i], longStop - 10 * _Point, true);
         }
         if(sellSignal)
         {
            string arrowName = "CE_SellArrow_" + IntegerToString(time[i]);
            string labelName = "CE_SellLabel_" + IntegerToString(time[i]);
            CreateSignalArrow(arrowName, time[i], shortStop, false);
            CreateSignalLabel(labelName, time[i], shortStop + 10 * _Point, false);
         }
      }

      //--- Handle alerts for current bar
      if(i == 0 || (i == 1 && InpAwaitBarConfirmation))
      {
         int alertBar = InpAwaitBarConfirmation ? 1 : 0;
         if(i == alertBar && time[alertBar] > lastAlertTime)
         {
            double alertDirPrev = DirectionBuffer[alertBar + 1];
            bool alertBuy = (DirectionBuffer[alertBar] == 1 && alertDirPrev == -1);
            bool alertSell = (DirectionBuffer[alertBar] == -1 && alertDirPrev == 1);

            if(alertBuy)
            {
               Alert("Chandelier Exit Buy Signal on ", _Symbol);
               lastAlertTime = time[alertBar];
            }
            else if(alertSell)
            {
               Alert("Chandelier Exit Sell Signal on ", _Symbol);
               lastAlertTime = time[alertBar];
            }
         }
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
