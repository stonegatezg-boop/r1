//+------------------------------------------------------------------+
//|                                               OHLCV_Table_MT5.mq5 |
//|                                    OHLCV History Table for MT5    |
//|                                         Created: 2026-02-04       |
//+------------------------------------------------------------------+
#property copyright "OHLCV Table"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Input Parameters
input group "Table Settings"
input int      TableRows      = 100;        // Number of Rows
input ENUM_BASE_CORNER TableCorner = CORNER_RIGHT_UPPER; // Table Position
input int      TableX         = 10;         // X Offset
input int      TableY         = 50;         // Y Offset
input int      FontSize       = 8;          // Font Size
input int      CellWidth      = 75;         // Cell Width
input int      CellHeight     = 16;         // Cell Height

input group "Colors"
input color    HeaderBg       = C'33,115,70';   // Header Background
input color    HeaderText     = clrWhite;       // Header Text
input color    Row1Bg         = C'220,230,241'; // Row Color 1
input color    Row2Bg         = C'189,215,238'; // Row Color 2
input color    Row3Bg         = C'255,242,204'; // Row Color 3 (alt day)
input color    Row4Bg         = C'255,230,153'; // Row Color 4 (alt day)
input color    SeparatorBg    = clrBlack;       // Day Separator
input color    TextColor      = clrBlack;       // Text Color
input color    BullColor      = C'0,128,0';     // Bullish Color
input color    BearColor      = C'192,0,0';     // Bearish Color

//--- Global Variables
string prefix = "OHLCV_";
string fontName = "Consolas";
int totalCols = 10;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   CreateTable();
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
//| Get pip value for the symbol                                      |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.01;
   if(StringFind(symbol, "XAG") >= 0 || StringFind(symbol, "SILVER") >= 0)
      return 0.001;
   if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0)
      return 1.0;
   if(digits == 5 || digits == 3)
      return _Point * 10;

   return _Point;
}

//+------------------------------------------------------------------+
//| Get day name                                                      |
//+------------------------------------------------------------------+
string GetDayName(datetime time)
{
   MqlDateTime dt;
   TimeToStruct(time, dt);

   switch(dt.day_of_week)
   {
      case 0: return "Sunday";
      case 1: return "Monday";
      case 2: return "Tuesday";
      case 3: return "Wednesday";
      case 4: return "Thursday";
      case 5: return "Friday";
      case 6: return "Saturday";
   }
   return "";
}

//+------------------------------------------------------------------+
//| Format volume                                                     |
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
//| Create cell                                                       |
//+------------------------------------------------------------------+
void CreateCell(string name, int col, int row, string text, color bgColor, color textColor, bool isHeader = false)
{
   int x = TableX + col * CellWidth;
   int y = TableY + row * CellHeight;

   // Background
   string bgName = name + "_bg";
   if(ObjectFind(0, bgName) < 0)
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, CellWidth);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, CellHeight);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER, TableCorner);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);

   // Text
   string txtName = name + "_txt";
   if(ObjectFind(0, txtName) < 0)
      ObjectCreate(0, txtName, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, txtName, OBJPROP_XDISTANCE, x + 3);
   ObjectSetInteger(0, txtName, OBJPROP_YDISTANCE, y + 2);
   ObjectSetString(0, txtName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, txtName, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, txtName, OBJPROP_FONT, fontName);
   ObjectSetInteger(0, txtName, OBJPROP_CORNER, TableCorner);
   ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, txtName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, txtName, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create header                                                     |
//+------------------------------------------------------------------+
void CreateHeader()
{
   string headers[] = {"Date/Day", "Time", "Open", "Close", "Pips", "High", "Low", "Change", "Change%", "Volume"};

   for(int i = 0; i < totalCols; i++)
   {
      CreateCell(prefix + "H" + IntegerToString(i), i, 0, headers[i], HeaderBg, HeaderText, true);
   }
}

//+------------------------------------------------------------------+
//| Create table                                                      |
//+------------------------------------------------------------------+
void CreateTable()
{
   CreateHeader();
   UpdateTable();
}

//+------------------------------------------------------------------+
//| Update table data                                                 |
//+------------------------------------------------------------------+
void UpdateTable()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = GetPipValue();

   string prevDate = "";
   int colorToggle = 0;

   for(int i = 1; i <= TableRows; i++)
   {
      if(i >= Bars(_Symbol, PERIOD_CURRENT))
         break;

      int row = i;

      // Get bar data
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      double close = iClose(_Symbol, PERIOD_CURRENT, i);
      long volume = iVolume(_Symbol, PERIOD_CURRENT, i);
      long tickVol = iTickVolume(_Symbol, PERIOD_CURRENT, i);

      // Get previous close for change calculation
      double prevClose = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      double change = close - prevClose;
      double changePct = prevClose != 0 ? (change / prevClose) * 100 : 0;

      // Calculate pips
      double pipsVal = MathAbs((close - open) / pipValue);

      // Check if bullish or bearish
      bool isBullish = close > open;

      // Date string
      string dateStr = TimeToString(barTime, TIME_DATE);
      StringReplace(dateStr, ".", "/");

      // Check if new day
      bool newDay = (dateStr != prevDate && prevDate != "");
      if(newDay)
         colorToggle = (colorToggle == 0) ? 1 : 0;

      // Determine row background color
      color rowBg;
      if(newDay)
         rowBg = SeparatorBg;
      else if(colorToggle == 0)
         rowBg = (i % 2 == 0) ? Row1Bg : Row2Bg;
      else
         rowBg = (i % 2 == 0) ? Row3Bg : Row4Bg;

      // Text colors
      color txtClr = newDay ? clrWhite : TextColor;
      color candleClr = newDay ? clrWhite : (isBullish ? BullColor : BearColor);
      color changeClr = newDay ? clrWhite : (change >= 0 ? BullColor : BearColor);

      // Format date with day name
      string dateDayStr = "";
      if(newDay || i == 1)
      {
         MqlDateTime dt;
         TimeToStruct(barTime, dt);
         dateDayStr = StringFormat("%02d.%02d.%d\n%s", dt.day, dt.mon, dt.year, GetDayName(barTime));
      }

      // Format values
      string timeStr = TimeToString(barTime, TIME_MINUTES);
      string openStr = DoubleToString(open, digits);
      string closeStr = DoubleToString(close, digits);
      string pipsStr = IntegerToString((int)MathRound(pipsVal));
      string highStr = DoubleToString(high, digits);
      string lowStr = DoubleToString(low, digits);
      string changeStr = (change >= 0 ? "+" : "") + DoubleToString(change, digits);
      string changePctStr = (changePct >= 0 ? "+" : "") + DoubleToString(changePct, 2) + "%";
      string volStr = FormatVolume(volume > 0 ? volume : tickVol);

      // Create cells
      CreateCell(prefix + "R" + IntegerToString(row) + "C0", 0, row, dateDayStr, rowBg, txtClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C1", 1, row, timeStr, rowBg, txtClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C2", 2, row, openStr, rowBg, candleClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C3", 3, row, closeStr, rowBg, candleClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C4", 4, row, pipsStr, rowBg, candleClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C5", 5, row, highStr, rowBg, txtClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C6", 6, row, lowStr, rowBg, txtClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C7", 7, row, changeStr, rowBg, changeClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C8", 8, row, changePctStr, rowBg, changeClr);
      CreateCell(prefix + "R" + IntegerToString(row) + "C9", 9, row, volStr, rowBg, txtClr);

      prevDate = dateStr;
   }

   ChartRedraw(0);
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
   // Update table on new bar
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBarTime != lastBarTime)
   {
      UpdateTable();
      lastBarTime = currentBarTime;
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| ChartEvent function                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Update on chart change
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      UpdateTable();
   }
}
//+------------------------------------------------------------------+
