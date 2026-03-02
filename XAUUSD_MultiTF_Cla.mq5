//+------------------------------------------------------------------+
//|                                            XAUUSD_MultiTF_Cla.mq5 |
//|                        Multi-Timeframe EA - H4 Trend + H1 + M5    |
//|                   Created: 02.03.2026 14:30 (Zagreb)              |
//+------------------------------------------------------------------+
#property copyright "XAUUSD MultiTF Cla v1.0"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETRI                                                    |
//+------------------------------------------------------------------+
// === OSNOVNI ===
input string   INFO1 = "=== OSNOVNI PARAMETRI ===";
input double   LotSize = 0.01;
input int      MagicNumber = 202603;          // Magic Number
input double   MaxSpread = 50;                // Max spread u PIPS

// === TARGETS (PIPS) ===
input string   INFO2 = "=== TARGETS (PIPS) ===";
input int      Target1_Pips = 300;            // Target 1 - zatvori 33%
input int      Target2_Pips = 500;            // Target 2 - zatvori 50%
input int      Target3_Pips = 800;            // Target 3 - zatvori ostatak

// === TRAILING STOP ===
input string   INFO3 = "=== TRAILING STOP ===";
input int      TrailingStart1 = 500;          // Pips za pomak na BE
input int      BEOffset_Min = 38;             // BE offset min pips
input int      BEOffset_Max = 43;             // BE offset max pips
input int      TrailingStart2 = 800;          // Pips za lock profit
input int      LockProfit_Min = 150;          // Lock profit min pips
input int      LockProfit_Max = 200;          // Lock profit max pips

// === STEALTH POSTAVKE ===
input string   INFO4 = "=== STEALTH ===";
input int      StealthSL_DelayMin = 7;        // SL delay min sekundi
input int      StealthSL_DelayMax = 13;       // SL delay max sekundi
input int      InitialSL_Pips = 500;          // Pocetni SL (za slanje brokeru)

// === FILTERI ===
input string   INFO5 = "=== FILTERI ===";
input bool     UseSpreadFilter = true;
input bool     UseLargeCandleFilter = true;
input double   LargeCandleATR = 2.0;          // Max candle size (ATR multiplier)
input bool     UseNewsFilter = false;         // News filter (placeholder)

// === TRADING WINDOW ===
input string   INFO6 = "=== TRADING WINDOW ===";
input bool     UseTradingWindow = true;
input int      FridayCloseHour = 11;          // Petak - zatvori do (sat)
input int      FridayCloseMinute = 30;        // Petak - zatvori do (minuta)

// === H4 TREND FILTER ===
input string   INFO7 = "=== H4 TREND FILTER ===";
input int      EMA_Fast_H4 = 20;              // Fast EMA period (H4)
input int      EMA_Slow_H4 = 50;              // Slow EMA period (H4)
input int      EMA_Trend_H4 = 200;            // Trend EMA period (H4)

// === H1 CONFIRMATION ===
input string   INFO8 = "=== H1 CONFIRMATION ===";
input int      EMA_Fast_H1 = 21;              // Fast EMA period (H1)
input int      EMA_Slow_H1 = 50;              // Slow EMA period (H1)
input int      RSI_Period_H1 = 14;            // RSI period (H1)
input double   RSI_OB_H1 = 65.0;              // RSI Overbought
input double   RSI_OS_H1 = 35.0;              // RSI Oversold

// === M5 ENTRY TRIGGER ===
input string   INFO9 = "=== M5 ENTRY TRIGGER ===";
input int      EMA_M5 = 21;                   // EMA period (M5)
input int      RSI_Period_M5 = 8;             // RSI period (M5)
input double   RSI_BUY_M5 = 45.0;             // RSI min za BUY entry
input double   RSI_SELL_M5 = 55.0;            // RSI max za SELL entry

// === DASHBOARD ===
input string   INFO10 = "=== DASHBOARD ===";
input bool     ShowDashboard = true;          // Prikazi dashboard

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

// Indicator handles
int      ema_fast_h4_handle, ema_slow_h4_handle, ema_trend_h4_handle;
int      ema_fast_h1_handle, ema_slow_h1_handle, rsi_h1_handle;
int      ema_m5_handle, rsi_m5_handle, atr_handle;

// New bar check
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   // Pip value za XAUUSD (1 pip = 0.1 = 10 points)
   if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 2)
   {
      pipValue = 0.1;
      pipDigits = 1;
   }
   else
   {
      pipValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      pipDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) - 1;
   }

   // Kreiraj indikator handleove
   // H4 handles
   ema_fast_h4_handle  = iMA(_Symbol, PERIOD_H4, EMA_Fast_H4, 0, MODE_EMA, PRICE_CLOSE);
   ema_slow_h4_handle  = iMA(_Symbol, PERIOD_H4, EMA_Slow_H4, 0, MODE_EMA, PRICE_CLOSE);
   ema_trend_h4_handle = iMA(_Symbol, PERIOD_H4, EMA_Trend_H4, 0, MODE_EMA, PRICE_CLOSE);

   // H1 handles
   ema_fast_h1_handle  = iMA(_Symbol, PERIOD_H1, EMA_Fast_H1, 0, MODE_EMA, PRICE_CLOSE);
   ema_slow_h1_handle  = iMA(_Symbol, PERIOD_H1, EMA_Slow_H1, 0, MODE_EMA, PRICE_CLOSE);
   rsi_h1_handle       = iRSI(_Symbol, PERIOD_H1, RSI_Period_H1, PRICE_CLOSE);

   // M5 handles
   ema_m5_handle       = iMA(_Symbol, PERIOD_M5, EMA_M5, 0, MODE_EMA, PRICE_CLOSE);
   rsi_m5_handle       = iRSI(_Symbol, PERIOD_M5, RSI_Period_M5, PRICE_CLOSE);
   atr_handle          = iATR(_Symbol, PERIOD_M5, 14);

   // Provjeri handleove
   if(ema_fast_h4_handle == INVALID_HANDLE || ema_slow_h4_handle == INVALID_HANDLE ||
      ema_trend_h4_handle == INVALID_HANDLE || ema_fast_h1_handle == INVALID_HANDLE ||
      ema_slow_h1_handle == INVALID_HANDLE || rsi_h1_handle == INVALID_HANDLE ||
      ema_m5_handle == INVALID_HANDLE || rsi_m5_handle == INVALID_HANDLE ||
      atr_handle == INVALID_HANDLE)
   {
      Print("GRESKA: Nije moguce kreirati indikatore!");
      return INIT_FAILED;
   }

   // Provjeri postojece pozicije
   CheckExistingPosition();

   Print("XAUUSD MultiTF Cla initialized. Pip value: ", pipValue);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Oslobodi handleove
   IndicatorRelease(ema_fast_h4_handle);
   IndicatorRelease(ema_slow_h4_handle);
   IndicatorRelease(ema_trend_h4_handle);
   IndicatorRelease(ema_fast_h1_handle);
   IndicatorRelease(ema_slow_h1_handle);
   IndicatorRelease(rsi_h1_handle);
   IndicatorRelease(ema_m5_handle);
   IndicatorRelease(rsi_m5_handle);
   IndicatorRelease(atr_handle);

   // Obriši dashboard
   ObjectDelete(0, "EA_Dashboard");

   Print("XAUUSD MultiTF Cla removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Dashboard - uvijek ažuriraj
   if(ShowDashboard) DrawDashboard();

   // 1. Upravljaj postojecom pozicijom
   if(hasOpenPosition)
   {
      ManagePosition();
      return;
   }

   // 2. Provjeri novu svjecu (samo na novoj M5 svjeci ulazimo)
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // 3. Provjeri moze li se trejdati
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
//| SIGNAL LOGIKA - MULTI TIMEFRAME                                   |
//+------------------------------------------------------------------+
int GetSignal()
{
   // Dohvati vrijednosti indikatora
   double h4_ema_fast  = GetIndicatorValue(ema_fast_h4_handle, 1);
   double h4_ema_slow  = GetIndicatorValue(ema_slow_h4_handle, 1);
   double h4_ema_trend = GetIndicatorValue(ema_trend_h4_handle, 1);

   double h1_ema_fast  = GetIndicatorValue(ema_fast_h1_handle, 1);
   double h1_ema_slow  = GetIndicatorValue(ema_slow_h1_handle, 1);
   double h1_rsi       = GetIndicatorValue(rsi_h1_handle, 1);

   double m5_ema       = GetIndicatorValue(ema_m5_handle, 1);
   double m5_rsi       = GetIndicatorValue(rsi_m5_handle, 1);

   double close_m5     = iClose(_Symbol, PERIOD_M5, 1);
   double close_h1     = iClose(_Symbol, PERIOD_H1, 1);

   // Validacija
   if(h4_ema_fast == 0 || h4_ema_slow == 0 || h4_ema_trend == 0) return 0;
   if(h1_ema_fast == 0 || h1_ema_slow == 0 || h1_rsi == 0) return 0;
   if(m5_ema == 0 || m5_rsi == 0) return 0;

   // ============================================================
   // H4 TREND FILTER
   // ============================================================
   bool h4_bullish = (h4_ema_fast > h4_ema_slow) && (close_h1 > h4_ema_trend);
   bool h4_bearish = (h4_ema_fast < h4_ema_slow) && (close_h1 < h4_ema_trend);

   // ============================================================
   // H1 CONFIRMATION
   // ============================================================
   bool h1_buy_confirm  = (h1_ema_fast > h1_ema_slow) && (h1_rsi > 40) && (h1_rsi < RSI_OB_H1);
   bool h1_sell_confirm = (h1_ema_fast < h1_ema_slow) && (h1_rsi < 60) && (h1_rsi > RSI_OS_H1);

   // ============================================================
   // M5 TRIGGER
   // ============================================================
   bool m5_buy_trigger  = (close_m5 > m5_ema) && (m5_rsi > RSI_BUY_M5) && (m5_rsi < 70);
   bool m5_sell_trigger = (close_m5 < m5_ema) && (m5_rsi < RSI_SELL_M5) && (m5_rsi > 30);

   // ============================================================
   // CANDLE PATTERN CONFIRMATION
   // ============================================================
   double open_m5_1  = iOpen(_Symbol, PERIOD_M5, 1);
   double close_m5_2 = iClose(_Symbol, PERIOD_M5, 2);
   double open_m5_2  = iOpen(_Symbol, PERIOD_M5, 2);

   bool bullish_candle = (close_m5 > open_m5_1) && (close_m5 > close_m5_2);
   bool bearish_candle = (close_m5 < open_m5_1) && (close_m5 < close_m5_2);

   // ============================================================
   // FINALNI SIGNAL
   // ============================================================
   bool buySignal  = h4_bullish && h1_buy_confirm  && m5_buy_trigger  && bullish_candle;
   bool sellSignal = h4_bearish && h1_sell_confirm && m5_sell_trigger && bearish_candle;

   if(buySignal)  return 1;
   if(sellSignal) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| PROVJERA MOŽE LI SE TREJDATI                                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Trading window (Nedjelja 00:01 - Petak 11:30)
   if(UseTradingWindow && !IsTradingTime())
   {
      return false;
   }

   // Spread filter (u PIPS!)
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
      double atr = GetIndicatorValue(atr_handle, 1);
      if(atr > 0)
      {
         double candleSize = MathAbs(iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1));
         if(candleSize > atr * LargeCandleATR)
         {
            return false;
         }
      }
   }

   // News filter (placeholder)
   if(UseNewsFilter)
   {
      // TODO: Implementiraj news filter
      // Možeš koristiti MQL5 kalendar ili external news API
   }

   // Min SL/TP distance provjera
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevel > InitialSL_Pips * 10)  // Convert pips to points
   {
      Print("Stop level precijenjen: ", stopLevel, " points");
      return false;
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

   // INTRADAY: NEMA restrikcija - trejdaj cijeli dan!
   return true;
}

//+------------------------------------------------------------------+
//| OPEN BUY                                                           |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // STEALTH: Ne salji TP brokeru!
   double sl = 0;  // SL cemo poslati s odgodom
   double tp = 0;  // TP nikad ne saljemo

   if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "MultiTF BUY"))
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

      // Postavi vrijeme za slanje SL-a (s odgodom 7-13 sekundi)
      slDelaySeconds = StealthSL_DelayMin + MathRand() % (StealthSL_DelayMax - StealthSL_DelayMin + 1);
      slSendTime = TimeCurrent() + slDelaySeconds;

      Print("BUY opened at ", ask, ". SL will be sent in ", slDelaySeconds, " seconds");
   }
   else
   {
      Print("BUY GRESKA: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| OPEN SELL                                                          |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // STEALTH: Ne salji TP brokeru!
   double sl = 0;
   double tp = 0;

   if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "MultiTF SELL"))
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
   else
   {
      Print("SELL GRESKA: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
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

   // 1. STEALTH SL - posalji brokeru s odgodom
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
            Print("TARGET 1 HIT! Closed 33% at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
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
            Print("TARGET 2 HIT! Closed 50% at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
         }
      }
   }

   // Target 3: Zatvori sve
   if(target2Hit && profitPips >= Target3_Pips)
   {
      if(trade.PositionClose(currentTicket))
      {
         hasOpenPosition = false;
         Print("TARGET 3 HIT! Closed ALL at ", currentPrice, " (+", DoubleToString(profitPips, 1), " pips)");
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE TRAILING STOP (2-LEVEL)                                    |
//+------------------------------------------------------------------+
void ManageTrailing(double profitPips)
{
   if(!slSentToBroker) return;  // Cekaj dok SL nije poslan

   double currentSL = PositionGetDouble(POSITION_SL);
   double newSL = currentSL;

   // Level 1: Na 500 pips, pomakni na BE + 38-43 pips (random)
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
         Print("TRAILING L1: SL moved to BE + ", offset, " pips (", newSL, ")");
      }
   }

   // Level 2: Na 800 pips, zakljucaj 150-200 pips profita (random)
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
         Print("TRAILING L2: Locked ", lockPips, " pips profit (SL at ", newSL, ")");
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
//| GET INDICATOR VALUE                                                |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| DRAW DASHBOARD                                                     |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   // Koristi Comment() za multiline text (umjesto OBJ_LABEL koji ne podržava multiline)

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool inTradingTime = IsTradingTime();

   double h4_ema_fast  = GetIndicatorValue(ema_fast_h4_handle, 1);
   double h4_ema_slow  = GetIndicatorValue(ema_slow_h4_handle, 1);
   double h4_ema_trend = GetIndicatorValue(ema_trend_h4_handle, 1);
   double h1_rsi       = GetIndicatorValue(rsi_h1_handle, 1);
   double m5_rsi       = GetIndicatorValue(rsi_m5_handle, 1);
   double atr          = GetIndicatorValue(atr_handle, 1);
   double close_h1     = iClose(_Symbol, PERIOD_H1, 1);

   bool h4_bull = (h4_ema_fast > h4_ema_slow) && (close_h1 > h4_ema_trend);
   bool h4_bear = (h4_ema_fast < h4_ema_slow) && (close_h1 < h4_ema_trend);
   string trendStr   = h4_bull ? "BULLISH" : (h4_bear ? "BEARISH" : "NEUTRAL");
   string sessionStr = inTradingTime ? "ACTIVE" : "INACTIVE";

   // Spread u PIPS
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips = spread * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / pipValue;

   // Pozicija info
   string posStr = "NONE";
   double profitPips = 0;
   if(hasOpenPosition)
   {
      double currentPrice = (positionType == 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(positionType == 0)
         profitPips = (currentPrice - entryPrice) / pipValue;
      else
         profitPips = (entryPrice - currentPrice) / pipValue;

      posStr = (positionType == 0) ? "BUY" : "SELL";
      posStr += " | " + DoubleToString(profitPips, 1) + " pips";
      if(target1Hit) posStr += " | T1";
      if(target2Hit) posStr += " T2";
      if(trailingLevel1Done) posStr += " | L1";
      if(trailingLevel2Done) posStr += " L2";
   }

   string text = "\n";
   text += "  XAUUSD MultiTF Cla v1.0\n";
   text += "  ========================\n";
   text += "  Trading:  " + sessionStr + "\n";
   text += "  H4 Trend: " + trendStr + "\n";
   text += "  H1 RSI:   " + DoubleToString(h1_rsi, 1) + "\n";
   text += "  M5 RSI:   " + DoubleToString(m5_rsi, 1) + "\n";
   text += "  ATR:      " + DoubleToString(atr, 2) + "\n";
   text += "  Spread:   " + DoubleToString(spreadPips, 1) + " pips\n";
   text += "  ========================\n";
   text += "  Position: " + posStr + "\n";

   Comment(text);
}
//+------------------------------------------------------------------+
