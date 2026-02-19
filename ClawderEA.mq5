//+------------------------------------------------------------------+
//|                        ClawderEA.mq5                             |
//|   Rule-based EA with AI Gatekeeper (Phase 1.5)                  |
//|                                                                  |
//|   Created:  2026-02-18 22:00 (server time)                        |
//|   Fixed:    2026-02-20 00:15 (server time)                        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.11"
#property copyright "Clawder"
//-------------------------------------------------------------------
// INCLUDES
//-------------------------------------------------------------------
#include <Trade/Trade.mqh>
//-------------------------------------------------------------------
// INPUTS
//-------------------------------------------------------------------
input double RiskPercent      = 0.5;     // Risk per trade %
input int    ATRperiod        = 14;
input int    FastEMA          = 9;
input int    SlowEMA          = 21;
input int    MaxSpread        = 30;
input int    MagicNumber      = 20260220;
// Risk limits
input double MaxDailyDD       = 3.0;     // %
input int    MaxLossStreak    = 3;
// Trailing
input bool   UseTrailing      = true;
input double TrailStartR      = 1.0;     // start trailing after 1R
input int    TrailPoints      = 150;
//-------------------------------------------------------------------
// GLOBALS
//-------------------------------------------------------------------
CTrade trade;
int      atrHandle, emaFastHandle, emaSlowHandle;
datetime lastBarTime = 0;
int      lossStreak  = 0;
//-------------------------------------------------------------------
// INIT
//-------------------------------------------------------------------
int OnInit()
{
   atrHandle     = iATR(_Symbol, PERIOD_M15, ATRperiod);
   emaFastHandle = iMA(_Symbol, PERIOD_M15, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M15, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   return INIT_SUCCEEDED;
}
//-------------------------------------------------------------------
void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
}
//-------------------------------------------------------------------
// TICK
//-------------------------------------------------------------------
void OnTick()
{
   ManageTrailing();
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;
   if(!IsTradingWindow()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   if(CurrentDailyDD() <= -MaxDailyDD) return;
   if(lossStreak >= MaxLossStreak) return;
   if(HasOpenPosition()) return;
   TradeLogic();
}
//-------------------------------------------------------------------
// TRADE TRANSACTION - loss streak tracking
//-------------------------------------------------------------------
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   if(profit < 0)
      lossStreak++;
   else
      lossStreak = 0;
}
//-------------------------------------------------------------------
// CORE LOGIC
//-------------------------------------------------------------------
void TradeLogic()
{
   double emaFast[1], emaSlow[1], atr[1];
   if(CopyBuffer(emaFastHandle, 0, 1, 1, emaFast) != 1) return;
   if(CopyBuffer(emaSlowHandle, 0, 1, 1, emaSlow) != 1) return;
   if(CopyBuffer(atrHandle,     0, 1, 1, atr)     != 1) return;
   ENUM_ORDER_TYPE direction;
   if(emaFast[0] > emaSlow[0])
      direction = ORDER_TYPE_BUY;
   else if(emaFast[0] < emaSlow[0])
      direction = ORDER_TYPE_SELL;
   else
      return;
   // --- AI GATEKEEPER (Phase 1.5)
   if(!AIGatekeeperAllow(direction))
      return;
   OpenTrade(direction, atr[0]);
}
//-------------------------------------------------------------------
// AI GATEKEEPER (SIMULATED / STUB)
//-------------------------------------------------------------------
bool AIGatekeeperAllow(ENUM_ORDER_TYPE direction)
{
   // Phase 1.5:
   // AI DOES NOT decide BUY/SELL
   // AI ONLY approves or blocks setup
   // Placeholder logic (to be replaced by Python/AI decision)
   return true;
}
//-------------------------------------------------------------------
// OPEN TRADE
//-------------------------------------------------------------------
void OpenTrade(ENUM_ORDER_TYPE type, double atr)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (type == ORDER_TYPE_BUY)
               ? entry - atr * 1.5
               : entry + atr * 1.5;
   double tp = (type == ORDER_TYPE_BUY)
               ? entry + atr * 3.0
               : entry - atr * 3.0;
   double lot = CalculateLot(MathAbs(entry - sl));
   if(lot <= 0) return;
   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, entry, sl, tp, "ClawderEA")
             : trade.Sell(lot,_Symbol, entry, sl, tp, "ClawderEA");
   if(!ok) return;
}
//-------------------------------------------------------------------
// LOT CALC
//-------------------------------------------------------------------
double CalculateLot(double slDistance)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slPoints = slDistance / point;
   double lot = riskMoney / (slPoints * tickValue / tickSize);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   return MathMax(min, MathMin(max, lot));
}
//-------------------------------------------------------------------
// TRAILING STOP
//-------------------------------------------------------------------
void ManageTrailing()
{
   if(!UseTrailing) return;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);
      double price = (type == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double R = MathAbs(open - sl);
      if(R <= 0) continue;
      double profitR = (type == POSITION_TYPE_BUY)
                       ? (price - open) / R
                       : (open - price) / R;
      if(profitR < TrailStartR) continue;
      double newSL = (type == POSITION_TYPE_BUY)
                     ? price - TrailPoints * _Point
                     : price + TrailPoints * _Point;
      if((type == POSITION_TYPE_BUY && newSL > sl) ||
         (type == POSITION_TYPE_SELL && newSL < sl))
         trade.PositionModify(ticket, newSL, tp);
   }
}
//-------------------------------------------------------------------
// HELPERS
//-------------------------------------------------------------------
bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
            return true;
   }
   return false;
}
double CurrentDailyDD()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, TimeCurrent());
   double pnl = 0;
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol)
         pnl += HistoryDealGetDouble(t, DEAL_PROFIT);
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   return (pnl / bal) * 100.0;
}
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0) return false; // Sunday
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true;
   if(dt.day_of_week == 5)
      return (dt.hour < 11 || (dt.hour == 11 && dt.min == 0));
   return false;
}
//+------------------------------------------------------------------+
