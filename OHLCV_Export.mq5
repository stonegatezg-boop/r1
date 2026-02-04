//+------------------------------------------------------------------+
//|                                                 OHLCV_Export.mq5 |
//|                      Export OHLCV History to CSV File             |
//|                                         Created: 2026-02-04       |
//+------------------------------------------------------------------+
#property copyright "OHLCV Export"
#property version   "1.00"
#property script_show_inputs

//--- Input Parameters
input ENUM_TIMEFRAMES  ExportTimeframe = PERIOD_M5;    // Timeframe
input int              YearsBack       = 2;            // Years of History
input bool             IncludeHeader   = true;         // Include Header Row
input string           Separator       = ",";          // CSV Separator (, or ;)

//+------------------------------------------------------------------+
//| Script program start function                                     |
//+------------------------------------------------------------------+
void OnStart()
{
   //--- Calculate date range
   datetime endDate = TimeCurrent();
   datetime startDate = endDate - (YearsBack * 365 * 24 * 60 * 60);

   //--- Get timeframe string for filename
   string tfString = GetTimeframeString(ExportTimeframe);

   //--- Create filename
   string filename = _Symbol + "_" + tfString + "_OHLCV_" +
                     TimeToString(startDate, TIME_DATE) + "_to_" +
                     TimeToString(endDate, TIME_DATE) + ".csv";

   //--- Replace invalid characters in filename
   StringReplace(filename, ".", "_");
   StringReplace(filename, ":", "-");
   StringReplace(filename, " ", "_");
   filename = filename + "";

   // Fix extension
   StringReplace(filename, "_csv", ".csv");

   //--- Open file
   int fileHandle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, StringGetCharacter(Separator, 0));

   if(fileHandle == INVALID_HANDLE)
   {
      Alert("Error opening file: ", filename, " Error: ", GetLastError());
      return;
   }

   //--- Write header
   if(IncludeHeader)
   {
      FileWrite(fileHandle,
                "Date",
                "Time",
                "Open",
                "High",
                "Low",
                "Close",
                "Volume",
                "Tick_Volume",
                "Spread",
                "Change",
                "Change_%",
                "Range",
                "Body",
                "Upper_Wick",
                "Lower_Wick",
                "Is_Bullish");
   }

   //--- Copy rates
   MqlRates rates[];
   ArraySetAsSeries(rates, false);

   int copied = CopyRates(_Symbol, ExportTimeframe, startDate, endDate, rates);

   if(copied <= 0)
   {
      Alert("Error copying rates. Error: ", GetLastError());
      FileClose(fileHandle);
      return;
   }

   Print("Exporting ", copied, " candles to ", filename);

   //--- Get digits for formatting
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- Progress tracking
   int progressStep = copied / 20;  // 5% steps
   if(progressStep < 1) progressStep = 1;

   //--- Write data
   for(int i = 0; i < copied; i++)
   {
      //--- Calculate additional metrics
      double change = 0;
      double changePct = 0;

      if(i > 0)
      {
         change = rates[i].close - rates[i-1].close;
         if(rates[i-1].close != 0)
            changePct = (change / rates[i-1].close) * 100;
      }

      double range = rates[i].high - rates[i].low;
      double body = MathAbs(rates[i].close - rates[i].open);
      double upperWick = rates[i].high - MathMax(rates[i].open, rates[i].close);
      double lowerWick = MathMin(rates[i].open, rates[i].close) - rates[i].low;
      bool isBullish = rates[i].close > rates[i].open;

      //--- Format date and time
      string dateStr = TimeToString(rates[i].time, TIME_DATE);
      string timeStr = TimeToString(rates[i].time, TIME_MINUTES);

      //--- Write row
      FileWrite(fileHandle,
                dateStr,
                timeStr,
                DoubleToString(rates[i].open, digits),
                DoubleToString(rates[i].high, digits),
                DoubleToString(rates[i].low, digits),
                DoubleToString(rates[i].close, digits),
                IntegerToString(rates[i].real_volume),
                IntegerToString(rates[i].tick_volume),
                IntegerToString(rates[i].spread),
                DoubleToString(change, digits),
                DoubleToString(changePct, 2),
                DoubleToString(range, digits),
                DoubleToString(body, digits),
                DoubleToString(upperWick, digits),
                DoubleToString(lowerWick, digits),
                isBullish ? "1" : "0");

      //--- Show progress
      if(i % progressStep == 0)
      {
         int pct = (int)((double)i / copied * 100);
         Comment("Exporting... ", pct, "% (", i, "/", copied, ")");
      }
   }

   //--- Close file
   FileClose(fileHandle);

   //--- Clear comment
   Comment("");

   //--- Success message
   string fullPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + filename;

   Alert("Export complete!\n\n",
         "Candles exported: ", copied, "\n",
         "Timeframe: ", tfString, "\n",
         "Period: ", TimeToString(startDate, TIME_DATE), " to ", TimeToString(endDate, TIME_DATE), "\n\n",
         "File saved to:\n", fullPath);

   Print("File saved: ", fullPath);
}

//+------------------------------------------------------------------+
//| Get timeframe as string                                           |
//+------------------------------------------------------------------+
string GetTimeframeString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";
      case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";
      case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return "CURRENT";
   }
}
//+------------------------------------------------------------------+
