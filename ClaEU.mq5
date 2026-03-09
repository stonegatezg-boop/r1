//+------------------------------------------------------------------+
//|                                                        ClaEU.mq5  |
//|                         Created: 09.03.2026 (Zagreb)              |
//|     Strategy: EMA Crossover + RSI Momentum + MACD Confirmation    |
//|     Timeframe: M5 | Instrument: EURUSD                            |
//+------------------------------------------------------------------+
#property copyright "Cla"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETRI                                                    |
//+------------------------------------------------------------------+
// === OSNOVNI ===
input string   INFO1 = "=== OSNOVNI PARAMETRI ===";
input double   LotSize = 0.01;
input int      MagicNumber = 556688;        // Magic Number za ClaEU
input double   MaxSpread = 20;              // Max spread u PIPS (EURUSD tipično 1-3 pips)

// === SIGNAL PARAMETRI ===
input string   INFO2 = "=== SIGNAL PARAMETRI ===";
input int      EMA_Fast = 9;                // Fast EMA period
input int      EMA_Slow = 21;               // Slow EMA period
input int      RSI_Period = 14;             // RSI period
input int      RSI_BuyLevel = 50;           // RSI level za BUY (iznad)
input int      RSI_SellLevel = 50;          // RSI level za SELL (ispod)
input int      MACD_Fast = 12;              // MACD Fast EMA
input int      MACD_Slow = 26;              // MACD Slow EMA
input int      MACD_Signal = 9;             // MACD Signal period
input bool     UseMACD = true;              // Koristi MACD potvrdu

// === TARGETS (PIPS) ===
input string   INFO3 = "=== TARGETS (PIPS) ===";
input int      Target1_Pips = 300;          // Target 1 - zatvori 33%
input int      Target2_Pips = 500;          // Target 2 - zatvori 50%
input int      Target3_Pips = 800;          // Target 3 - zatvori ostatak
input int      InitialSL_Pips = 1000;       // PRAVI SL ODMAH (1000 pips)

// === TRAILING STOP ===
input string   INFO4 = "=== TRAILING STOP ===";
input int      TrailingStart1 = 500;        // Pips za pomak na BE
input int      BEOffset_Min = 38;           // BE offset min pips
input int      BEOffset_Max = 43;           // BE offset max pips
input int      TrailingStart2 = 1000;       // Pips za lock profit (1000 pips)
input int      LockProfit_Min = 150;        // Lock profit min pips
input int      LockProfit_Max = 200;        // Lock profit max pips

// === FILTERI ===
input string   INFO5 = "=== FILTERI ===";
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 2.5;        // Max candle size (ATR multiplier)

// === RADNO VRIJEME (Zagreb/CET) ===
input string   INFO6 = "=== RADNO VRIJEME (Zagreb) ===";
input bool     UseTradingWindow = true;
input int      ServerGMTOffset = 2;         // Broker server GMT offset (tipično 2 za većinu brokera)
input int      ZagrebStartHour = 8;         // Početak tradinga (Zagreb time)
input int      ZagrebEndHour = 22;          // Kraj tradinga (Zagreb time)
input int      FridayCloseHour = 20;        // Petak - zatvori do (Zagreb time)

//+------------------------------------------------------------------+
//| GLOBALNE VARIJABLE                                                |
//+------------------------------------------------------------------+
CTrade trade;

// Position tracking
bool     hasOpenPosition = false;
ulong    currentTicket = 0;
double   entryPrice = 0;
int      positionType = -1;  // 0=BUY, 1=SELL
datetime entryTime = 0;

// Target tracking
bool     target1Hit = false;
bool     target2Hit = false;
double   originalLots = 0;

// Trailing
bool     trailingLevel1Done = false;
bool     trailingLevel2Done = false;

// Points conversion
double   pipValue;
int      pipDigits;

// Indicator handles
int      emaFastHandle;
int      emaSlowHandle;
int      rsiHandle;
int      macdHandle;

// Last bar time (za signal samo na novoj svijeći)
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // EURUSD pip kalkulacija
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
   {
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      pipDigits = digits - 1;
   }
   else
   {
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      pipDigits = digits;
   }

   // Kreiraj indikator handle-ove
   emaFastHandle = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   macdHandle = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles!");
      return(INIT_FAILED);
   }

   // Provjeri postojeće pozicije
   CheckExistingPosition();

   Print("ClaEU initialized. Pip value: ", pipValue, " | SL: ", InitialSL_Pips, " pips | Trailing: ", TrailingStart2, " pips");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(macdHandle);
   Print("ClaEU removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Upravljaj postojećom pozicijom
   if(hasOpenPosition)
   {
      ManagePosition();
      return;
   }

   // 2. Provjeri samo na novoj svijeći
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   // 3. Provjeri može li se trejdati
   if(!CanTrade()) return;

   // 4. Provjeri signale
   int signal = GetSignal();

   // 5. Otvori poziciju
   if(signal == 1)
      OpenBuy();
   else if(signal == -1)
      OpenSell();
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIKA - EMA + RSI + MACD                                  |
//+------------------------------------------------------------------+
int GetSignal()
{
   // Dohvati EMA vrijednosti
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) < 3) return 0;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) < 3) return 0;

   // Dohvati RSI
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2) return 0;

   // Dohvati MACD
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSignal, true);
   if(CopyBuffer(macdHandle, 0, 0, 3, macdMain) < 3) return 0;
   if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) < 3) return 0;

   // BUY SIGNAL:
   // 1. EMA Fast > EMA Slow (uptrend)
   // 2. EMA crossover (Fast prelazi iznad Slow)
   // 3. RSI > 50 (bullish momentum)
   // 4. MACD histogram > 0 ili MACD crossover (potvrda)

   bool emaCrossUp = (emaFast[2] <= emaSlow[2] && emaFast[1] > emaSlow[1]);
   bool rsiBullish = (rsi[1] > RSI_BuyLevel);
   bool macdBullish = true;

   if(UseMACD)
   {
      double histogram = macdMain[1] - macdSignal[1];
      double histogramPrev = macdMain[2] - macdSignal[2];
      macdBullish = (histogram > 0) || (histogramPrev <= 0 && histogram > 0);
   }

   // SELL SIGNAL:
   // 1. EMA Fast < EMA Slow (downtrend)
   // 2. EMA crossover (Fast prelazi ispod Slow)
   // 3. RSI < 50 (bearish momentum)
   // 4. MACD histogram < 0 ili MACD crossover (potvrda)

   bool emaCrossDown = (emaFast[2] >= emaSlow[2] && emaFast[1] < emaSlow[1]);
   bool rsiBearish = (rsi[1] < RSI_SellLevel);
   bool macdBearish = true;

   if(UseMACD)
   {
      double histogram = macdMain[1] - macdSignal[1];
      double histogramPrev = macdMain[2] - macdSignal[2];
      macdBearish = (histogram < 0) || (histogramPrev >= 0 && histogram < 0);
   }

   // BUY: Crossover + momentum confirmation
   if(emaCrossUp && rsiBullish && macdBullish)
   {
      Print("BUY Signal: EMA Cross UP | RSI=", DoubleToString(rsi[1], 1), " | MACD bullish");
      return 1;
   }

   // SELL: Crossover + momentum confirmation
   if(emaCrossDown && rsiBearish && macdBearish)
   {
      Print("SELL Signal: EMA Cross DOWN | RSI=", DoubleToString(rsi[1], 1), " | MACD bearish");
      return -1;
   }

   return 0;  // No signal
}

//+------------------------------------------------------------------+
//| PROVJERA MOŽE LI SE TREJDATI                                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Trading window (Zagreb time)
   if(UseTradingWindow && !IsTradingTime())
      return false;

   // Spread filter
   if(UseSpreadFilter)
   {
      double spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadPips = spreadPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / pipValue;
      if(spreadPips > MaxSpread)
      {
         return false;
      }
   }

   // Large candle filter
   if(UseLargeCandleFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      int atrHandle = iATR(_Symbol, PERIOD_M5, 14);
      if(CopyBuffer(atrHandle, 0, 0, 2, atr) < 2)
      {
         IndicatorRelease(atrHandle);
         return false;
      }
      IndicatorRelease(atrHandle);

      double candleSize = MathAbs(iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1));
      if(candleSize > atr[1] * LargeCandleATR)
      {
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| TRADING WINDOW CHECK (Zagreb Time)                                 |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Konverzija server time u Zagreb time
   // Zagreb = CET/CEST (GMT+1 zimi, GMT+2 ljeti)
   // Pretpostavljamo da je broker server već na sličnom offsetu
   // Ako nije, korisnik može podesiti ServerGMTOffset

   // Zagreb je GMT+1 (zima) ili GMT+2 (ljeto)
   // Većina brokera koristi GMT+2 (EET) ili GMT+3 (EEST)
   // Za jednostavnost, koristimo direktno server time ako je broker već na CET/EET

   int serverHour = dt.hour;

   // Nedjelja - ne trejdaj do 00:01
   if(dt.day_of_week == 0 && serverHour < 1)
      return false;

   // Subota - ne trejdaj
   if(dt.day_of_week == 6)
      return false;

   // Petak - zatvori ranije
   if(dt.day_of_week == 5)
   {
      if(serverHour >= FridayCloseHour)
         return false;
   }

   // Provjeri radno vrijeme (Zagreb)
   if(serverHour < ZagrebStartHour || serverHour >= ZagrebEndHour)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| OPEN BUY - PRAVI SL ODMAH!                                        |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // PRAVI SL ODMAH - 1000 pipsa
   double sl = NormalizeDouble(ask - InitialSL_Pips * pipValue, _Digits);
   double tp = 0;  // Stealth TP - ne šaljemo brokeru

   if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "ClaEU"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = ask;
      positionType = 0;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      // Reset flags
      target1Hit = false;
      target2Hit = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      Print("BUY opened at ", ask, " | SL: ", sl, " (", InitialSL_Pips, " pips)");
   }
   else
   {
      Print("BUY failed! Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL - PRAVI SL ODMAH!                                       |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // PRAVI SL ODMAH - 1000 pipsa
   double sl = NormalizeDouble(bid + InitialSL_Pips * pipValue, _Digits);
   double tp = 0;  // Stealth TP - ne šaljemo brokeru

   if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "ClaEU"))
   {
      currentTicket = trade.ResultOrder();
      entryPrice = bid;
      positionType = 1;
      entryTime = TimeCurrent();
      hasOpenPosition = true;
      originalLots = LotSize;

      // Reset flags
      target1Hit = false;
      target2Hit = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      Print("SELL opened at ", bid, " | SL: ", sl, " (", InitialSL_Pips, " pips)");
   }
   else
   {
      Print("SELL failed! Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| MANAGE POSITION                                                    |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!PositionSelectByTicket(currentTicket))
   {
      // Pozicija zatvorena (SL hit ili manual)
      hasOpenPosition = false;
      Print("Position closed externally");
      return;
   }

   double currentPrice = (positionType == 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPips = 0;

   if(positionType == 0)  // BUY
      profitPips = (currentPrice - entryPrice) / pipValue;
   else  // SELL
      profitPips = (entryPrice - currentPrice) / pipValue;

   // 1. STEALTH TP - provjeri targete
   CheckTargets(profitPips, currentPrice);

   // 2. TRAILING STOP
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
//| CHECK TARGETS (STEALTH TP)                                        |
//+------------------------------------------------------------------+
void CheckTargets(double profitPips, double currentPrice)
{
   double currentLots = PositionGetDouble(POSITION_VOLUME);

   // Target 1: Zatvori 33%
   if(!target1Hit && profitPips >= Target1_Pips)
   {
      double closeSize = NormalizeDouble(originalLots * 0.33, 2);
      if(closeSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         closeSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(closeSize <= currentLots)
      {
         if(trade.PositionClosePartial(currentTicket, closeSize))
         {
            target1Hit = true;
            Print("Target 1 hit! Closed 33% at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
         }
      }
      else
      {
         target1Hit = true;
      }
   }

   // Target 2: Zatvori 50% preostalog
   if(!target2Hit && target1Hit && profitPips >= Target2_Pips)
   {
      currentLots = PositionGetDouble(POSITION_VOLUME);
      double closeSize = NormalizeDouble(currentLots * 0.50, 2);
      if(closeSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         closeSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(closeSize <= currentLots)
      {
         if(trade.PositionClosePartial(currentTicket, closeSize))
         {
            target2Hit = true;
            Print("Target 2 hit! Closed 50% at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
         }
      }
      else
      {
         target2Hit = true;
      }
   }

   // Target 3: Zatvori sve
   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("Target 3 hit! Closed all at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE TRAILING STOP                                               |
//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   double currentSL = PositionGetDouble(POSITION_SL);
   double newSL = currentSL;

   // Level 1: Na 500 pips, pomakni na BE + offset
   if(!trailingLevel1Done && profitPips >= TrailingStart1)
   {
      int offset = BEOffset_Min + MathRand() % (BEOffset_Max - BEOffset_Min + 1);

      if(positionType == 0)  // BUY
         newSL = entryPrice + offset * pipValue;
      else  // SELL
         newSL = entryPrice - offset * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);

      // Provjeri da je novi SL bolji od trenutnog
      bool isBetter = false;
      if(positionType == 0 && newSL > currentSL) isBetter = true;
      if(positionType == 1 && newSL < currentSL) isBetter = true;

      if(isBetter && trade.PositionModify(currentTicket, newSL, 0))
      {
         trailingLevel1Done = true;
         Print("Trailing Level 1: SL moved to BE + ", offset, " pips (", newSL, ")");
      }
   }

   // Level 2: Na 1000 pips, zaključaj profit
   if(!trailingLevel2Done && trailingLevel1Done && profitPips >= TrailingStart2)
   {
      int lockPips = LockProfit_Min + MathRand() % (LockProfit_Max - LockProfit_Min + 1);

      if(positionType == 0)  // BUY
         newSL = entryPrice + lockPips * pipValue;
      else  // SELL
         newSL = entryPrice - lockPips * pipValue;

      newSL = NormalizeDouble(newSL, _Digits);

      if(trade.PositionModify(currentTicket, newSL, 0))
      {
         trailingLevel2Done = true;
         Print("Trailing Level 2: Locked ", lockPips, " pips profit (SL: ", newSL, ")");
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK EXISTING POSITION                                            |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            currentTicket = ticket;
            entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positionType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 0 : 1;
            entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            hasOpenPosition = true;
            originalLots = PositionGetDouble(POSITION_VOLUME);

            Print("Existing position found. Ticket: ", ticket, " | Entry: ", entryPrice);
            break;
         }
      }
   }
}
//+------------------------------------------------------------------+
