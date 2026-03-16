//+------------------------------------------------------------------+
//|                                                   Template_EA.mq5 |
//|                                    TEMPLATE - NE KORISTITI DIREKTNO |
//|                         Kopiraj i prilagodi signal logiku za novi EA |
//|                   Fixed: 04.03.2026 (Zagreb) - pip calc fix      |
//+------------------------------------------------------------------+
#property copyright "Template"
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
input int      MagicNumber = 100000;        // PROMIJENI ZA SVAKI EA!
input double   MaxSpread = 50;              // Max spread u PIPS

// === TARGETS (PIPS) ===
input string   INFO2 = "=== TARGETS (PIPS) ===";
input int      Target1_Pips = 300;          // Target 1 - zatvori 33%
input int      Target2_Pips = 500;          // Target 2 - zatvori 50%
input int      Target3_Pips = 800;          // Target 3 - zatvori ostatak

// === TRAILING STOP ===
input string   INFO3 = "=== TRAILING STOP ===";
input int      TrailingStart1 = 500;        // Pips za pomak na BE
input int      BEOffset_Min = 38;           // BE offset min pips
input int      BEOffset_Max = 43;           // BE offset max pips
input int      TrailingStart2 = 800;        // Pips za lock profit
input int      LockProfit_Min = 150;        // Lock profit min pips
input int      LockProfit_Max = 200;        // Lock profit max pips

// === STEALTH POSTAVKE ===
input string   INFO4 = "=== STEALTH ===";
input int      StealthSL_DelayMin = 7;      // SL delay min sekundi
input int      StealthSL_DelayMax = 13;     // SL delay max sekundi
input int      InitialSL_Pips = 500;        // Početni SL (za slanje brokeru)

// === FILTERI ===
input string   INFO5 = "=== FILTERI ===";
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 3.0;        // Max candle size (ATR multiplier)
input bool     UseNewsFilter = false;       // News filter (placeholder)

// === TRADING WINDOW ===
input string   INFO6 = "=== TRADING WINDOW ===";
input bool     UseTradingWindow = true;
input int      FridayCloseHour = 11;        // Petak - zatvori do (sat)
input int      FridayCloseMinute = 30;      // Petak - zatvori do (minuta)

// === SIGNAL PARAMETRI (PRILAGODI ZA SVAKI EA) ===
input string   INFO7 = "=== SIGNAL PARAMETRI ===";
// DODAJ OVDJE INPUTE SPECIFIČNE ZA SIGNAL LOGIKU
// Primjer:
// input int      EMA_Fast = 20;
// input int      EMA_Slow = 50;

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

// Stealth SL
bool     slSentToBroker = false;
datetime slSendTime = 0;
int      slDelaySeconds = 0;

// Trailing
bool     trailingLevel1Done = false;
bool     trailingLevel2Done = false;

// Points conversion
double   pipValue;
int      pipDigits;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // XAUUSD pip = 0.1 (fixed) bez obzira na broker digits (2 ili 3)
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      pipValue = 0.1;
      pipDigits = 1;
   }
   else
   {
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
   }

   // Provjeri postojeće pozicije
   CheckExistingPosition();

   Print("Template EA initialized. Pip value: ", pipValue);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Template EA removed. Reason: ", reason);
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

   // 2. Provjeri može li se trejdati
   if(!CanTrade()) return;

   // 3. Provjeri signale
   int signal = GetSignal();

   // 4. Otvori poziciju
   if(signal == 1)
      OpenBuy();
   else if(signal == -1)
      OpenSell();
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIKA - PRILAGODI ZA SVAKI EA                             |
//+------------------------------------------------------------------+
int GetSignal()
{
   // OVDJE DODAJ SVOJU SIGNAL LOGIKU
   // Vrati: 1 = BUY, -1 = SELL, 0 = NO SIGNAL

   // ========================================
   // PRIMJER - ZAMIJENI S PRAVOM LOGIKOM:
   // ========================================

   /*
   // Primjer: EMA Cross
   double emaFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   double emaSlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   double emaFastPrev = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 1, MODE_EMA, PRICE_CLOSE);
   double emaSlowPrev = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 1, MODE_EMA, PRICE_CLOSE);

   // BUY: Fast crosses above Slow
   if(emaFastPrev <= emaSlowPrev && emaFast > emaSlow)
      return 1;

   // SELL: Fast crosses below Slow
   if(emaFastPrev >= emaSlowPrev && emaFast < emaSlow)
      return -1;
   */

   return 0;  // No signal
}

//+------------------------------------------------------------------+
//| PROVJERA MOŽE LI SE TREJDATI                                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Trading window
   if(UseTradingWindow && !IsTradingTime())
   {
      return false;
   }

   // Spread filter
   if(UseSpreadFilter)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      double spreadPips = spread * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / pipValue;
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
      int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
      CopyBuffer(atrHandle, 0, 0, 2, atr);
      IndicatorRelease(atrHandle);

      double candleSize = MathAbs(iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1));
      if(candleSize > atr[1] * LargeCandleATR)
      {
         return false;
      }
   }

   // News filter (placeholder)
   if(UseNewsFilter)
   {
      // TODO: Implementiraj news filter
   }

   return true;
}

//+------------------------------------------------------------------+
//| TRADING WINDOW CHECK                                               |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Nedjelja nakon 00:01
   if(dt.day_of_week == 0 && (dt.hour == 0 && dt.min < 1))
      return false;

   // Petak prije 11:30 (ili konfiguriranog vremena)
   if(dt.day_of_week == 5)
   {
      if(dt.hour > FridayCloseHour || (dt.hour == FridayCloseHour && dt.min >= FridayCloseMinute))
         return false;
   }

   // Subota - ne trejdaj
   if(dt.day_of_week == 6)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                           |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // STEALTH: Ne šalji TP brokeru!
   double sl = 0;  // SL ćemo poslati s odgodom
   double tp = 0;  // TP nikad ne šaljemo

   if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "Template EA"))
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
      slSentToBroker = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      // Postavi vrijeme za slanje SL-a (s odgodom)
      slDelaySeconds = StealthSL_DelayMin + MathRand() % (StealthSL_DelayMax - StealthSL_DelayMin + 1);
      slSendTime = TimeCurrent() + slDelaySeconds;

      Print("BUY opened at ", ask, ". SL will be sent in ", slDelaySeconds, " seconds");
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                          |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // STEALTH: Ne šalji TP brokeru!
   double sl = 0;
   double tp = 0;

   if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "Template EA"))
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
      slSentToBroker = false;
      trailingLevel1Done = false;
      trailingLevel2Done = false;

      // Postavi vrijeme za slanje SL-a
      slDelaySeconds = StealthSL_DelayMin + MathRand() % (StealthSL_DelayMax - StealthSL_DelayMin + 1);
      slSendTime = TimeCurrent() + slDelaySeconds;

      Print("SELL opened at ", bid, ". SL will be sent in ", slDelaySeconds, " seconds");
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

   // 1. STEALTH SL - pošalji brokeru s odgodom
   if(!slSentToBroker && TimeCurrent() >= slSendTime)
   {
      SendStealthSL();
   }

   // 2. STEALTH TP - provjeri targete
   CheckTargets(profitPips, currentPrice);

   // 3. TRAILING STOP
   ManageTrailing(profitPips);
}

//+------------------------------------------------------------------+
//| SEND STEALTH SL                                                    |
//+------------------------------------------------------------------+
void SendStealthSL()
{
   double slPrice = 0;

   if(positionType == 0)  // BUY
      slPrice = entryPrice - InitialSL_Pips * pipValue;
   else  // SELL
      slPrice = entryPrice + InitialSL_Pips * pipValue;

   slPrice = NormalizeDouble(slPrice, _Digits);

   if(trade.PositionModify(currentTicket, slPrice, 0))
   {
      slSentToBroker = true;
      Print("Stealth SL sent to broker at ", slPrice, " (delayed ", slDelaySeconds, "s)");
   }
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
            Print("Target 1 hit! Closed 33% at ", currentPrice, " (+", profitPips, " pips)");
         }
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
            Print("Target 2 hit! Closed 50% at ", currentPrice, " (+", profitPips, " pips)");
         }
      }
   }

   // Target 3: Zatvori sve
   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("Target 3 hit! Closed all at ", currentPrice, " (+", profitPips, " pips)");
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE TRAILING STOP                                               |
//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   if(!slSentToBroker) return;  // Čekaj dok SL nije poslan

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

      if(trade.PositionModify(currentTicket, newSL, 0))
      {
         trailingLevel1Done = true;
         Print("Trailing Level 1: SL moved to BE + ", offset, " pips");
      }
   }

   // Level 2: Na 800 pips, zaključaj profit
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
         Print("Trailing Level 2: Locked ", lockPips, " pips profit");
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
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            currentTicket = ticket;
            entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positionType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 0 : 1;
            entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            hasOpenPosition = true;
            originalLots = PositionGetDouble(POSITION_VOLUME);
            slSentToBroker = (PositionGetDouble(POSITION_SL) != 0);

            Print("Existing position found. Ticket: ", ticket);
            break;
         }
      }
   }
}
//+------------------------------------------------------------------+
