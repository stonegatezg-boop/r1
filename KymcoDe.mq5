//+------------------------------------------------------------------+
//|                                                   KymcoDe.mq5    |
//|   Deepco Core + Kymco Discipline (Production EA)                 |
//|                                                                  |
//|   Created:  2026-02-18 22:00 (server time)                        |
//|   Fixed:    2026-02-19 23:00 (server time)                        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"
#property copyright "KymcoDe"
//--- includes
#include <Trade/Trade.mqh>
//--- inputs
input double RiskPercent        = 0.5;     // Risk per trade %
input int    ATRperiod          = 20;
input int    ATRmaPeriod        = 100;
input int    DonchianPeriod     = 20;
input int    BBperiod           = 20;
input double BBdev              = 2.0;
input int    CooldownBars       = 5;
input int    MaxSpread          = 40;
input int    MagicNumber        = 9022026;
input double MaxDailyDD         = 3.0;     // %
input bool   UseBreakeven       = true;
input double BreakevenR         = 1.0;
//--- globals
CTrade trade;
int atrHandle, bbHandle;
datetime lastBar = 0;
datetime lastTradeTime = 0;
//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_M5, ATRperiod);
   bbHandle  = iBands(_Symbol, PERIOD_M5, BBperiod, 0, BBdev, PRICE_CLOSE);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
   IndicatorRelease(bbHandle);
}
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == lastBar)
   {
      ManageBreakeven();
      return;
   }
   lastBar = barTime;
   if(!IsTradingWindow()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   if(CurrentDailyDD() <= -MaxDailyDD) return;
   if(HasOpenPosition()) return;
   if(TimeCurrent() - lastTradeTime < CooldownBars * PeriodSeconds(PERIOD_M5))
      return;
   if(IsHighVolatility())
      DonchianSignal();
   else
      BollingerSignal();
}
//+------------------------------------------------------------------+
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Nedjelja - forex trziste zatvoreno
   if(dt.day_of_week == 0)
      return false;
   // Ponedjeljak - Cetvrtak: cijeli dan
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;
   // Petak: do 11:00
   if(dt.day_of_week == 5)
      return (dt.hour < 11 || (dt.hour == 11 && dt.min == 0));
   return false;
}
//+------------------------------------------------------------------+
bool IsHighVolatility()
{
   double atr[1], atrs[];
   ArraySetAsSeries(atrs, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) != 1) return false;
   if(CopyBuffer(atrHandle, 0, 1, ATRmaPeriod, atrs) < ATRmaPeriod) return false;
   double sum = 0;
   for(int i=0;i<ATRmaPeriod;i++) sum += atrs[i];
   double atrMA = sum / ATRmaPeriod;
   return (atr[0] > atrMA);
}
//+------------------------------------------------------------------+
void DonchianSignal()
{
   double high[], low[], close[];
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);
   if(CopyHigh(_Symbol, PERIOD_M5, 1, DonchianPeriod, high) < DonchianPeriod) return;
   if(CopyLow (_Symbol, PERIOD_M5, 1, DonchianPeriod, low ) < DonchianPeriod) return;
   if(CopyClose(_Symbol, PERIOD_M5, 1, 1, close) != 1) return;
   double upper = high[ArrayMaximum(high)];
   double lower = low[ArrayMinimum(low)];
   if(close[0] > upper)
      OpenTrade(ORDER_TYPE_BUY, lower);
   else if(close[0] < lower)
      OpenTrade(ORDER_TYPE_SELL, upper);
}
//+------------------------------------------------------------------+
void BollingerSignal()
{
   double upper[1], lower[1], close[1];
   if(CopyBuffer(bbHandle, 1, 1, 1, upper) != 1) return;
   if(CopyBuffer(bbHandle, 2, 1, 1, lower) != 1) return;
   if(CopyClose (_Symbol, PERIOD_M5, 1, 1, close) != 1) return;
   double highPrev = iHigh(_Symbol, PERIOD_M5, 1);
   double lowPrev  = iLow (_Symbol, PERIOD_M5, 1);
   if(close[0] > upper[0])
      OpenTrade(ORDER_TYPE_SELL, highPrev);
   else if(close[0] < lower[0])
      OpenTrade(ORDER_TYPE_BUY, lowPrev);
}
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double stop)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((type == ORDER_TYPE_BUY && stop >= entry) ||
      (type == ORDER_TYPE_SELL && stop <= entry)) return;
   double slDist = MathAbs(entry - stop);
   double lot = CalculateLot(slDist);
   if(lot <= 0) return;
   double tp = (type == ORDER_TYPE_BUY)
               ? entry + 2 * slDist
               : entry - 2 * slDist;
   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, entry, stop, tp, "KymcoDe")
             : trade.Sell(lot,_Symbol, entry, stop, tp, "KymcoDe");
   if(ok)
      lastTradeTime = TimeCurrent();
}
//+------------------------------------------------------------------+
double CalculateLot(double slDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slPoints = slDist / point;
   double lot = riskMoney / (slPoints * tickValue / tickSize);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   return MathMax(min, MathMin(max, lot));
}
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   if(!UseBreakeven) return;
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
      if(profitR >= BreakevenR && MathAbs(sl - open) > _Point)
         trade.PositionModify(ticket, open, tp);
   }
}
//+------------------------------------------------------------------+
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
//+------------------------------------------------------------------+
double CurrentDailyDD()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, TimeCurrent());
   double pnl = 0;
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol)
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   return (pnl / bal) * 100.0;
}
//+------------------------------------------------------------------+
