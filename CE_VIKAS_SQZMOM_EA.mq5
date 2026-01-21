//+------------------------------------------------------------------+
//| CE_VIKAS_SQZMOM_EA.mq5                                          |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- inputs
input double   LotSize          = 0.2;
input long     MagicNumber      = 123456;
input int      Slippage         = 30;

input int      CE_Period        = 10;
input double   CE_Multiplier    = 3.0;

input int      VIKAS_Period     = 18;
input double   VIKAS_Multiplier = 2.8;

input int      SQZ_Length       = 10;
input int      KC_Length        = 10;
input int      BB_Length        = 20;

input int      SL_Buffer        = 100;
input int      TP_Min           = 191;
input int      TP_Max           = 214;
input int      BreakEvenPips    = 50;
input int      BreakEvenOffset  = 5;
input int      DelayMin         = 2;
input int      DelayMax         = 8;

//--- globals
int      atr_handle_ce;
int      atr_handle_vikas;

datetime last_bar_time = 0;

int      last_ce_dir       = 0;
int      last_trade_dir    = 0;
bool     trade_closed_flag = false;
ulong    current_ticket    = 0;

// non-blocking delay state
bool     pending_entry     = false;
int      pending_dir       = 0;
datetime pending_time      = 0;
datetime pending_ce_time   = 0;
double   pending_ce_sl     = 0.0;
int      pending_tp_pips   = 0;

//+------------------------------------------------------------------+
//| Trading Hours Filter                                             |
//| START: Sunday 00:05 (broker server time)                         |
//| END:   Friday 11:00 (broker server time)                         |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   int dow = dt.day_of_week;  // 0=Sunday, 1=Monday, ..., 5=Friday, 6=Saturday
   int hh  = dt.hour;
   int mm  = dt.min;

   // Saturday: NO trading
   if(dow == 6)
      return false;

   // Sunday: allowed only from 00:05 onwards
   if(dow == 0)
   {
      if(hh == 0 && mm < 5)
         return false;
      return true;
   }

   // Monday to Thursday: always allowed
   if(dow >= 1 && dow <= 4)
      return true;

   // Friday: allowed until 11:00
   if(dow == 5)
   {
      if(hh < 11)
         return true;
      if(hh == 11 && mm == 0)
         return true;
      return false;
   }

   return false;
}

//+------------------------------------------------------------------+
double PipsToPrice(double pips)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return pips * point;
}

//+------------------------------------------------------------------+
double LinearRegression(const double &price[], int len, int shift)
{
   if(len <= 1) return 0.0;
   if(ArraySize(price) < shift + len) return 0.0;

   double sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0;
   for(int i = 0; i < len; i++)
   {
      int idx = shift + i;
      double x = i + 1;
      double y = price[idx];
      sumX  += x;
      sumY  += y;
      sumXY += x * y;
      sumXX += x * x;
   }
   double n = (double)len;
   double denom = (n * sumXX - sumX * sumX);
   if(denom == 0.0) return 0.0;
   return (n * sumXY - sumX * sumY) / denom;
}

//+------------------------------------------------------------------+
//| Stateful Chandelier Exit (TradingView-like)                      |
//+------------------------------------------------------------------+
int CalcChandelierExit(int shift, double &ce_stop_long, double &ce_stop_short)
{
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   if(bars <= CE_Period + shift + 2) return 0;

   static bool   inited = false;
   static int    ce_dir[];
   static double ce_stop[];

   if(!inited || ArraySize(ce_dir) != bars)
   {
      ArrayResize(ce_dir, bars);
      ArrayResize(ce_stop, bars);
      ArrayInitialize(ce_dir, 0);
      ArrayInitialize(ce_stop, 0.0);
      inited = true;
   }

   ArraySetAsSeries(ce_dir, true);
   ArraySetAsSeries(ce_stop, true);

   // recompute from far history to current shift (deterministic, closed bars only)
   for(int i = bars - CE_Period - 2; i >= shift; i--)
   {
      double highestClose = -DBL_MAX;
      double lowestClose  = DBL_MAX;

      for(int j = i; j < i + CE_Period; j++)
      {
         double c = iClose(_Symbol, PERIOD_CURRENT, j);
         if(c > highestClose) highestClose = c;
         if(c < lowestClose)  lowestClose  = c;
      }

      double atr_buff[];
      ArraySetAsSeries(atr_buff, true);
      if(CopyBuffer(atr_handle_ce, 0, i, CE_Period + 2, atr_buff) <= 0)
         return 0;
      double atr = atr_buff[i];

      double longStop  = highestClose - CE_Multiplier * atr;
      double shortStop = lowestClose  + CE_Multiplier * atr;

      int    prev_dir  = (i + 1 < bars ? ce_dir[i + 1]  : 0);
      double prev_stop = (i + 1 < bars ? ce_stop[i + 1] : 0.0);
      double close     = iClose(_Symbol, PERIOD_CURRENT, i);

      int    dir  = prev_dir;
      double stop = prev_stop;

      if(prev_dir == 0)
      {
         if(close > shortStop)
         {
            dir  = +1;
            stop = longStop;
         }
         else if(close < longStop)
         {
            dir  = -1;
            stop = shortStop;
         }
      }
      else if(prev_dir == +1)
      {
         double trailed = MathMax(longStop, prev_stop);
         if(close <= trailed)
         {
            dir  = -1;
            stop = shortStop;
         }
         else
         {
            dir  = +1;
            stop = trailed;
         }
      }
      else if(prev_dir == -1)
      {
         double trailed = MathMin(shortStop, prev_stop);
         if(close >= trailed)
         {
            dir  = +1;
            stop = longStop;
         }
         else
         {
            dir  = -1;
            stop = trailed;
         }
      }

      ce_dir[i]  = dir;
      ce_stop[i] = stop;
   }

   int dir_now = ce_dir[shift];
   ce_stop_long  = (dir_now == +1 ? ce_stop[shift] : 0.0);
   ce_stop_short = (dir_now == -1 ? ce_stop[shift] : 0.0);
   return dir_now;
}

//+------------------------------------------------------------------+
//| Stateful SuperTrend (HL2 source)                                |
//+------------------------------------------------------------------+
int CalcVikasSuperTrend(int shift, double &vikas_line)
{
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   if(bars <= VIKAS_Period + shift + 2) return 0;

   static bool   inited = false;
   static int    trend[];
   static double upperBand[];
   static double lowerBand[];

   if(!inited || ArraySize(trend) != bars)
   {
      ArrayResize(trend, bars);
      ArrayResize(upperBand, bars);
      ArrayResize(lowerBand, bars);
      ArrayInitialize(trend, 0);
      ArrayInitialize(upperBand, 0.0);
      ArrayInitialize(lowerBand, 0.0);
      inited = true;
   }

   ArraySetAsSeries(trend, true);
   ArraySetAsSeries(upperBand, true);
   ArraySetAsSeries(lowerBand, true);

   for(int i = bars - VIKAS_Period - 2; i >= shift; i--)
   {
      double atr_buff[];
      ArraySetAsSeries(atr_buff, true);
      if(CopyBuffer(atr_handle_vikas, 0, i, VIKAS_Period + 2, atr_buff) <= 0)
         return 0;
      double atr = atr_buff[i];

      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      double low  = iLow(_Symbol, PERIOD_CURRENT, i);
      double hl2  = (high + low) / 2.0;

      double basicUpper = hl2 + VIKAS_Multiplier * atr;
      double basicLower = hl2 - VIKAS_Multiplier * atr;

      double prevUpper = (i + 1 < bars ? upperBand[i + 1] : basicUpper);
      double prevLower = (i + 1 < bars ? lowerBand[i + 1] : basicLower);
      int    prevTrend = (i + 1 < bars ? trend[i + 1]     : 0);

      double finalUpper = (basicUpper < prevUpper ? basicUpper : prevUpper);
      double finalLower = (basicLower > prevLower ? basicLower : prevLower);

      double close = iClose(_Symbol, PERIOD_CURRENT, i);

      int curTrend = prevTrend;
      if(close > finalUpper) curTrend = +1;
      else if(close < finalLower) curTrend = -1;

      trend[i]     = curTrend;
      upperBand[i] = finalUpper;
      lowerBand[i] = finalLower;
   }

   int t = trend[shift];
   if(t == +1) vikas_line = lowerBand[shift];
   else if(t == -1) vikas_line = upperBand[shift];
   else vikas_line = 0.0;

   return t;
}

//+------------------------------------------------------------------+
//| SQZMOM exact logic                                              |
//+------------------------------------------------------------------+
double CalcSQZMOM(int shift)
{
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   if(bars <= MathMax(KC_Length, MathMax(BB_Length, SQZ_Length)) + shift + 5)
      return 0.0;

   double high_buff[], low_buff[], close_buff[];
   ArraySetAsSeries(high_buff, true);
   ArraySetAsSeries(low_buff, true);
   ArraySetAsSeries(close_buff, true);

   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high_buff) <= 0)   return 0.0;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low_buff) <= 0)     return 0.0;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close_buff) <= 0) return 0.0;

   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;
   for(int i = shift; i < shift + KC_Length; i++)
   {
      if(high_buff[i] > highest) highest = high_buff[i];
      if(low_buff[i]  < lowest)  lowest  = low_buff[i];
   }

   double sum = 0.0;
   for(int i = shift; i < shift + BB_Length; i++)
      sum += close_buff[i];
   double sma = sum / (double)BB_Length;

   double mid = 0.5 * ((highest + lowest) * 0.5 + sma);

   double diff_buff[];
   ArrayResize(diff_buff, bars);
   ArraySetAsSeries(diff_buff, true);
   for(int i = 0; i < bars; i++)
      diff_buff[i] = close_buff[i] - mid;

   return LinearRegression(diff_buff, SQZ_Length, shift);
}

//+------------------------------------------------------------------+
bool HasOpenPosition(int &dir, ulong &ticket)
{
   dir = 0;
   ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos_ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(pos_ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((string)PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)  dir = +1;
      if(type == POSITION_TYPE_SELL) dir = -1;

      ticket = pos_ticket;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ManageBreakEven()
{
   int dir;
   ulong ticket;
   if(!HasOpenPosition(dir, ticket) || dir == 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl         = PositionGetDouble(POSITION_SL);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double pips_in_profit = 0.0;
   if(dir == +1) pips_in_profit = (bid - open_price) / PipsToPrice(1.0);
   else          pips_in_profit = (open_price - ask) / PipsToPrice(1.0);

   if(pips_in_profit >= BreakEvenPips)
   {
      double new_sl_price = (dir == +1)
                            ? open_price + PipsToPrice(BreakEvenOffset)
                            : open_price - PipsToPrice(BreakEvenOffset);

      if((dir == +1 && (sl == 0.0 || new_sl_price > sl)) ||
         (dir == -1 && (sl == 0.0 || new_sl_price < sl)))
      {
         trade.PositionModify(ticket, new_sl_price, PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   atr_handle_ce    = iATR(_Symbol, PERIOD_CURRENT, CE_Period);
   atr_handle_vikas = iATR(_Symbol, PERIOD_CURRENT, VIKAS_Period);

   if(atr_handle_ce == INVALID_HANDLE ||
      atr_handle_vikas == INVALID_HANDLE)
      return INIT_FAILED;

   MathSrand((uint)GetTickCount());
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void ClearPending()
{
   pending_entry   = false;
   pending_dir     = 0;
   pending_time    = 0;
   pending_ce_time = 0;
   pending_ce_sl   = 0.0;
   pending_tp_pips = 0;
}

//+------------------------------------------------------------------+
void OnTick()
{
   int dir;
   ulong ticket;

   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates);
   if(copied < 3) return;
   ArraySetAsSeries(rates, true);

   // Break-even runs always (inside and outside trading hours)
   ManageBreakEven();

   // Execute pending entry if time reached and still valid
   if(pending_entry && TimeCurrent() >= pending_time)
   {
      // TRADING HOURS GATE: Cancel pending if outside trading hours
      if(!IsTradingTime())
      {
         ClearPending();
      }
      else if(HasOpenPosition(dir, ticket))
      {
         ClearPending();
      }
      else
      {
         double price = (pending_dir == +1)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);

         double sl = (pending_dir == +1)
                     ? pending_ce_sl - PipsToPrice(SL_Buffer)
                     : pending_ce_sl + PipsToPrice(SL_Buffer);

         double tp = (pending_dir == +1)
                     ? price + PipsToPrice(pending_tp_pips)
                     : price - PipsToPrice(pending_tp_pips);

         bool ok = false;
         if(pending_dir == +1)
            ok = trade.Buy(LotSize, _Symbol, price, sl, tp);
         else if(pending_dir == -1)
            ok = trade.Sell(LotSize, _Symbol, price, sl, tp);

         ClearPending();
      }
   }

   if(rates[1].time == last_bar_time) return;
   last_bar_time = rates[1].time;

   bool has_pos = HasOpenPosition(dir, ticket);
   if(!has_pos && current_ticket != 0)
   {
      trade_closed_flag = true;
      current_ticket = 0;
   }
   else if(has_pos)
   {
      current_ticket = ticket;
   }

   int shift_now  = 1;
   int shift_prev = 2;

   double ce_long_now = 0.0, ce_short_now = 0.0;
   int ce_dir_now = CalcChandelierExit(shift_now, ce_long_now, ce_short_now);

   double ce_long_prev = 0.0, ce_short_prev = 0.0;
   int ce_dir_prev = CalcChandelierExit(shift_prev, ce_long_prev, ce_short_prev);

   double vikas_line = 0.0;
   int vikas_dir = CalcVikasSuperTrend(shift_now, vikas_line);

   double sqz_val = CalcSQZMOM(shift_now);
   int sqz_dir = (sqz_val > 0 ? +1 : (sqz_val < 0 ? -1 : 0));

   bool ce_flipped = (ce_dir_now != 0 && ce_dir_prev != 0 && ce_dir_now != ce_dir_prev);

   // If new CE flip occurs before pending executes → cancel pending
   if(ce_flipped && pending_entry)
      ClearPending();

   // CE-based forced close runs always (inside and outside trading hours)
   if(has_pos && dir != 0)
   {
      if(ce_flipped && ce_dir_now == -dir)
      {
         trade.PositionClose(ticket, Slippage);
         trade_closed_flag = true;
         last_trade_dir = dir;
         current_ticket = 0;
      }
   }

   last_ce_dir = ce_dir_now;

   has_pos = HasOpenPosition(dir, ticket);
   if(has_pos) return;

   if(trade_closed_flag)
   {
      if(last_trade_dir != 0 && ce_dir_now == last_trade_dir) return;
      if(last_trade_dir != 0 && ce_dir_now == -last_trade_dir)
         trade_closed_flag = false;
   }

   // TRADING HOURS GATE: Block new entries outside trading hours
   // CE events detected outside trading hours are IGNORED (not queued)
   if(!IsTradingTime())
      return;

   bool open_long  = false;
   bool open_short = false;

   if(ce_flipped && ce_dir_now == +1 && vikas_dir == +1 && sqz_dir == +1)
      open_long = true;
   if(ce_flipped && ce_dir_now == -1 && vikas_dir == -1 && sqz_dir == -1)
      open_short = true;

   if(!open_long && !open_short) return;

   int delay_sec = DelayMin + (int)MathRand() % (DelayMax - DelayMin + 1);
   int tp_pips   = TP_Min + (int)MathRand() % (TP_Max - TP_Min + 1);

   pending_entry   = true;
   pending_dir     = open_long ? +1 : -1;
   pending_time    = TimeCurrent() + delay_sec;
   pending_ce_time = TimeCurrent();
   pending_ce_sl   = open_long ? ce_long_now : ce_short_now;
   pending_tp_pips = tp_pips;
}
