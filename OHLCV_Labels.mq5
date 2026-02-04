//+------------------------------------------------------------------+
//|                                                 OHLCV_Labels.mq5 |
//|                                    OHLC + Volume Labels Indicator |
//|                                         Created: 2026-02-04       |
//+------------------------------------------------------------------+
#property copyright "OHLCV Labels"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Input Parameters
input group "Display Settings"
input bool     ShowOpen       = true;       // Show Open
input bool     ShowHigh       = true;       // Show High
input bool     ShowLow        = true;       // Show Low
input bool     ShowClose      = true;       // Show Close
input bool     ShowVolume     = true;       // Show Volume
input bool     ShowChange     = true;       // Show Change %
input int      MaxBars        = 50;         // Max Bars to Display

input group "Style Settings"
input int      FontSize       = 8;          // Font Size
input color    BullColor      = clrLime;    // Bullish Candle Color
input color    BearColor      = clrRed;     // Bearish Candle Color
input color    NeutralColor   = clrWhite;   // Neutral Color
input int      YOffset        = 20;         // Vertical Offset (pixels)

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "OHLCV_");
}

//+------------------------------------------------------------------+
//| Format volume for display                                         |
//+------------------------------------------------------------------+
string FormatVolume(long vol)
{
   if(vol >= 1000000)
      return DoubleToString(vol / 1000000.0, 2) + "M";
   else if(vol >= 1000)
      return DoubleToString(vol / 1000.0, 2) + "K";
   else
      return IntegerToString(vol);
}

//+------------------------------------------------------------------+
//| Create or update label                                            |
//+------------------------------------------------------------------+
void CreateLabel(string name, datetime time, double price, string text, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TEXT, 0, time, price);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   ObjectSetInteger(0, name, OBJPROP_TIME, time);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LOWER);
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
   //--- Set as series
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(tick_volume, true);
   ArraySetAsSeries(volume, true);

   //--- Calculate bars to process
   int barsToProcess = MathMin(MaxBars, rates_total - 1);

   //--- Get chart scale for offset calculation
   double atr = 0;
   for(int i = 0; i < MathMin(14, barsToProcess); i++)
      atr += high[i] - low[i];
   atr /= MathMin(14, barsToProcess);

   double offset = atr * 0.5;  // Dynamic offset based on volatility

   //--- Process each bar
   for(int i = 1; i <= barsToProcess; i++)  // Start from 1 to skip current bar
   {
      //--- Determine candle color
      bool isBull = close[i] > open[i];
      bool isBear = close[i] < open[i];
      color textColor = isBull ? BullColor : (isBear ? BearColor : NeutralColor);

      //--- Build label text
      string labelText = "";
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(ShowOpen)
         labelText += "O:" + DoubleToString(open[i], digits) + "\n";

      if(ShowHigh)
         labelText += "H:" + DoubleToString(high[i], digits) + "\n";

      if(ShowLow)
         labelText += "L:" + DoubleToString(low[i], digits) + "\n";

      if(ShowClose)
         labelText += "C:" + DoubleToString(close[i], digits) + "\n";

      if(ShowChange && i + 1 < rates_total)
      {
         double change = close[i] - close[i + 1];
         double changePct = (close[i + 1] != 0) ? (change / close[i + 1]) * 100 : 0;
         string sign = (change >= 0) ? "+" : "";
         labelText += sign + DoubleToString(change, digits) + " (" + sign + DoubleToString(changePct, 2) + "%)\n";
      }

      if(ShowVolume)
      {
         long vol = (volume[i] > 0) ? volume[i] : tick_volume[i];
         labelText += "V:" + FormatVolume(vol);
      }

      //--- Remove trailing newline
      StringTrimRight(labelText);

      //--- Create label above the candle
      string labelName = "OHLCV_" + IntegerToString(i);
      double labelPrice = high[i] + offset;

      CreateLabel(labelName, time[i], labelPrice, labelText, textColor);
   }

   //--- Clean up old labels
   for(int i = barsToProcess + 1; i < barsToProcess + 100; i++)
   {
      string labelName = "OHLCV_" + IntegerToString(i);
      if(ObjectFind(0, labelName) >= 0)
         ObjectDelete(0, labelName);
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
