//+------------------------------------------------------------------+
//|                                                  OHLCV_Panel.mq5 |
//|                         OHLC + Volume Panel - Click on any candle |
//|                                         Created: 2026-02-04       |
//+------------------------------------------------------------------+
#property copyright "OHLCV Panel"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Input Parameters
input group "Panel Settings"
input int      PanelX         = 20;         // Panel X Position
input int      PanelY         = 50;         // Panel Y Position
input int      PanelWidth     = 200;        // Panel Width
input color    PanelBgColor   = C'32,32,32';// Panel Background Color
input color    PanelBorder    = clrGray;    // Panel Border Color
input color    LabelColor     = clrWhite;   // Label Color
input color    BullColor      = clrLime;    // Bullish Value Color
input color    BearColor      = clrRed;     // Bearish Value Color
input int      FontSize       = 10;         // Font Size

//--- Global Variables
int selectedBar = 1;  // Default to previous bar
string prefix = "OHLCV_Panel_";

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   CreatePanel();
   UpdatePanel(selectedBar);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, prefix);
}

//+------------------------------------------------------------------+
//| Create rectangle label                                            |
//+------------------------------------------------------------------+
void CreateRectLabel(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create text label                                                 |
//+------------------------------------------------------------------+
void CreateTextLabel(string name, int x, int y, string text, color clr, int size = 0)
{
   if(size == 0) size = FontSize;

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create the panel                                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int lineHeight = FontSize + 8;
   int panelHeight = lineHeight * 10 + 20;

   //--- Background
   CreateRectLabel(prefix + "bg", PanelX, PanelY, PanelWidth, panelHeight, PanelBgColor, PanelBorder);

   //--- Title
   CreateTextLabel(prefix + "title", PanelX + 10, PanelY + 5, _Symbol + " OHLCV", LabelColor, FontSize + 2);

   //--- Labels
   int y = PanelY + 35;
   CreateTextLabel(prefix + "lbl_time", PanelX + 10, y, "Time:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_open", PanelX + 10, y, "Open:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_high", PanelX + 10, y, "High:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_low", PanelX + 10, y, "Low:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_close", PanelX + 10, y, "Close:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_change", PanelX + 10, y, "Change:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_range", PanelX + 10, y, "Range:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_volume", PanelX + 10, y, "Volume:", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "lbl_spread", PanelX + 10, y, "Spread:", LabelColor);

   //--- Values (placeholders)
   y = PanelY + 35;
   int valueX = PanelX + 80;
   CreateTextLabel(prefix + "val_time", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_open", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_high", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_low", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_close", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_change", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_range", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_volume", valueX, y, "-", LabelColor); y += lineHeight;
   CreateTextLabel(prefix + "val_spread", valueX, y, "-", LabelColor);
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
//| Update panel with bar data                                        |
//+------------------------------------------------------------------+
void UpdatePanel(int barIndex)
{
   if(barIndex < 0 || barIndex >= Bars(_Symbol, PERIOD_CURRENT))
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, barIndex);
   double open = iOpen(_Symbol, PERIOD_CURRENT, barIndex);
   double high = iHigh(_Symbol, PERIOD_CURRENT, barIndex);
   double low = iLow(_Symbol, PERIOD_CURRENT, barIndex);
   double close = iClose(_Symbol, PERIOD_CURRENT, barIndex);
   long volume = iVolume(_Symbol, PERIOD_CURRENT, barIndex);
   long tickVol = iTickVolume(_Symbol, PERIOD_CURRENT, barIndex);

   //--- Calculate change
   double prevClose = (barIndex + 1 < Bars(_Symbol, PERIOD_CURRENT)) ?
                      iClose(_Symbol, PERIOD_CURRENT, barIndex + 1) : open;
   double change = close - prevClose;
   double changePct = (prevClose != 0) ? (change / prevClose) * 100 : 0;

   //--- Calculate range
   double range = high - low;

   //--- Get spread
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;

   //--- Determine colors
   bool isBull = close > open;
   bool isBear = close < open;
   color valueColor = isBull ? BullColor : (isBear ? BearColor : LabelColor);
   color changeColor = (change > 0) ? BullColor : ((change < 0) ? BearColor : LabelColor);

   //--- Update values
   ObjectSetString(0, prefix + "val_time", OBJPROP_TEXT, TimeToString(barTime, TIME_DATE|TIME_MINUTES));
   ObjectSetInteger(0, prefix + "val_time", OBJPROP_COLOR, LabelColor);

   ObjectSetString(0, prefix + "val_open", OBJPROP_TEXT, DoubleToString(open, digits));
   ObjectSetInteger(0, prefix + "val_open", OBJPROP_COLOR, LabelColor);

   ObjectSetString(0, prefix + "val_high", OBJPROP_TEXT, DoubleToString(high, digits));
   ObjectSetInteger(0, prefix + "val_high", OBJPROP_COLOR, BullColor);

   ObjectSetString(0, prefix + "val_low", OBJPROP_TEXT, DoubleToString(low, digits));
   ObjectSetInteger(0, prefix + "val_low", OBJPROP_COLOR, BearColor);

   ObjectSetString(0, prefix + "val_close", OBJPROP_TEXT, DoubleToString(close, digits));
   ObjectSetInteger(0, prefix + "val_close", OBJPROP_COLOR, valueColor);

   string sign = (change >= 0) ? "+" : "";
   ObjectSetString(0, prefix + "val_change", OBJPROP_TEXT, sign + DoubleToString(change, digits) + " (" + sign + DoubleToString(changePct, 2) + "%)");
   ObjectSetInteger(0, prefix + "val_change", OBJPROP_COLOR, changeColor);

   ObjectSetString(0, prefix + "val_range", OBJPROP_TEXT, DoubleToString(range, digits));
   ObjectSetInteger(0, prefix + "val_range", OBJPROP_COLOR, LabelColor);

   long vol = (volume > 0) ? volume : tickVol;
   ObjectSetString(0, prefix + "val_volume", OBJPROP_TEXT, FormatVolume(vol));
   ObjectSetInteger(0, prefix + "val_volume", OBJPROP_COLOR, LabelColor);

   ObjectSetString(0, prefix + "val_spread", OBJPROP_TEXT, DoubleToString(spread, digits) + " (" + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts)");
   ObjectSetInteger(0, prefix + "val_spread", OBJPROP_COLOR, LabelColor);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| ChartEvent function                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   //--- Mouse click event
   if(id == CHARTEVENT_CLICK)
   {
      //--- Convert pixel coordinates to chart coordinates
      datetime clickTime;
      double clickPrice;
      int subWindow;

      if(ChartXYToTimePrice(0, (int)lparam, (int)dparam, subWindow, clickTime, clickPrice))
      {
         //--- Find the bar index at click position
         int barIndex = iBarShift(_Symbol, PERIOD_CURRENT, clickTime);
         if(barIndex >= 0)
         {
            selectedBar = barIndex;
            UpdatePanel(selectedBar);
         }
      }
   }

   //--- Mouse move event (optional: update on hover)
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      //--- Get mouse position
      int x = (int)lparam;
      int y = (int)dparam;

      //--- Check if inside panel area - don't update if hovering over panel
      if(x >= PanelX && x <= PanelX + PanelWidth && y >= PanelY && y <= PanelY + 200)
         return;
   }
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
   //--- Update panel on new tick (for current bar updates)
   if(selectedBar == 0)
      UpdatePanel(0);

   return(rates_total);
}
//+------------------------------------------------------------------+
