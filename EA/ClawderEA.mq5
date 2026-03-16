//+------------------------------------------------------------------+
//|                        ClawderEA.mq5                             |
//|   Rule-based EA with AI Gatekeeper (Phase 1.5)                  |
//|   + Stealth Mode v2.0                                            |
//|                                                                  |
//|   Created:  2026-02-18 22:00 (server time)                        |
//|   Stealth:  2026-02-20 01:00 (server time)                        |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property copyright "Clawder"
//-------------------------------------------------------------------
// INCLUDES
//-------------------------------------------------------------------
#include <Trade/Trade.mqh>
//-------------------------------------------------------------------
// INPUTS
//-------------------------------------------------------------------
input group "=== TRADE POSTAVKE ==="
input double RiskPercent      = 0.5;     // Risk per trade %
input int    ATRperiod        = 14;
input int    FastEMA          = 9;
input int    SlowEMA          = 21;
input int    MaxSpread        = 30;
input int    MagicNumber      = 20260220;
input double MaxDailyDD       = 3.0;     // %
input int    MaxLossStreak    = 3;

input group "=== STEALTH POSTAVKE ==="
input bool   UseStealthMode     = true;
input int    OpenDelayMin       = 0;
input int    OpenDelayMax       = 4;
input int    SLDelayMin         = 7;
input int    SLDelayMax         = 13;
input double LargeCandleATR     = 3.0;

input group "=== TRAILING POSTAVKE ==="
input int    TrailActivatePips  = 500;
input int    TrailBEPipsMin     = 33;
input int    TrailBEPipsMax     = 38;

//--- Strukture
struct PendingTradeInfo
{
   bool              active;
   ENUM_ORDER_TYPE   type;
   double            lot;
   double            intendedSL;
   double            intendedTP;
   double            atrValue;
   datetime          signalTime;
   int               delaySeconds;
};

struct StealthPosInfo
{
   bool     active;
   ulong    ticket;
   double   intendedSL;
   double   stealthTP;
   double   entryPrice;
   datetime openTime;
   int      delaySeconds;
   int      randomBEPips;
   int      trailLevel;
};

//-------------------------------------------------------------------
// GLOBALS
//-------------------------------------------------------------------
CTrade trade;
int      atrHandle, emaFastHandle, emaSlowHandle;
datetime lastBarTime = 0;
int      lossStreak  = 0;

PendingTradeInfo g_pendingTrade;
StealthPosInfo   g_positions[];
int              g_posCount = 0;

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

   MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
   g_pendingTrade.active = false;
   ArrayResize(g_positions, 0);
   g_posCount = 0;

   Print("=== ClawderEA v2.0 STEALTH MODE ===");
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
int RandomRange(int minVal, int maxVal)
{
   if(minVal >= maxVal) return minVal;
   return minVal + (MathRand() % (maxVal - minVal + 1));
}
//-------------------------------------------------------------------
// STEALTH: Trading Window
//-------------------------------------------------------------------
bool IsTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0)
   {
      if(dt.hour > 1 || (dt.hour == 1 && dt.min >= 1))
         return true;
      return false;
   }
   if(dt.day_of_week >= 1 && dt.day_of_week <= 4)
      return true;
   if(dt.day_of_week == 5)
   {
      if(dt.hour < 12 || (dt.hour == 12 && dt.min <= 30))
         return true;
      return false;
   }
   return false;
}
//-------------------------------------------------------------------
bool IsBlackoutPeriod()
{
   if(!UseStealthMode) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int minutes = dt.hour * 60 + dt.min;
   return (minutes >= 15*60+30 && minutes < 16*60+30);
}
//-------------------------------------------------------------------
bool IsLargeCandle()
{
   if(!UseStealthMode) return false;
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false;
   double high = iHigh(_Symbol, PERIOD_M15, 1);
   double low  = iLow(_Symbol, PERIOD_M15, 1);
   return ((high - low) > LargeCandleATR * atr[0]);
}
//-------------------------------------------------------------------
// TICK
//-------------------------------------------------------------------
void OnTick()
{
   ProcessPendingTrade();
   ManageStealthPositions();

   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   if(!IsTradingWindow()) return;
   if(IsBlackoutPeriod()) return;
   if(IsLargeCandle()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   if(CurrentDailyDD() <= -MaxDailyDD) return;
   if(lossStreak >= MaxLossStreak) return;
   if(HasOpenPosition()) return;
   if(g_pendingTrade.active) return;

   TradeLogic();
}
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

   if(!AIGatekeeperAllow(direction))
      return;

   QueueTrade(direction, atr[0]);
}
//-------------------------------------------------------------------
bool AIGatekeeperAllow(ENUM_ORDER_TYPE direction)
{
   return true;
}
//-------------------------------------------------------------------
void QueueTrade(ENUM_ORDER_TYPE type, double atr)
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

   if(UseStealthMode)
   {
      g_pendingTrade.active = true;
      g_pendingTrade.type = type;
      g_pendingTrade.lot = lot;
      g_pendingTrade.intendedSL = sl;
      g_pendingTrade.intendedTP = tp;
      g_pendingTrade.atrValue = atr;
      g_pendingTrade.signalTime = TimeCurrent();
      g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax);
      Print("ClawderEA: Trade queued, delay ", g_pendingTrade.delaySeconds, "s");
   }
   else
   {
      ExecuteTrade(type, lot, sl, tp);
   }
}
//-------------------------------------------------------------------
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp)
{
   double entry = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok;
   if(UseStealthMode)
   {
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, 0, 0, "ClawderEA")
           : trade.Sell(lot, _Symbol, entry, 0, 0, "ClawderEA");
   }
   else
   {
      ok = (type == ORDER_TYPE_BUY)
           ? trade.Buy(lot, _Symbol, entry, sl, tp, "ClawderEA")
           : trade.Sell(lot, _Symbol, entry, sl, tp, "ClawderEA");
   }

   if(ok && UseStealthMode)
   {
      ulong ticket = trade.ResultOrder();
      ArrayResize(g_positions, g_posCount + 1);
      g_positions[g_posCount].active = true;
      g_positions[g_posCount].ticket = ticket;
      g_positions[g_posCount].intendedSL = sl;
      g_positions[g_posCount].stealthTP = tp;
      g_positions[g_posCount].entryPrice = entry;
      g_positions[g_posCount].openTime = TimeCurrent();
      g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax);
      g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax);
      g_positions[g_posCount].trailLevel = 0;
      g_posCount++;
      Print("ClawderEA STEALTH: Opened #", ticket, ", SL delay ", g_positions[g_posCount-1].delaySeconds, "s");
   }
}
//-------------------------------------------------------------------
void ProcessPendingTrade()
{
   if(!g_pendingTrade.active) return;
   if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds)
   {
      ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot,
                   g_pendingTrade.intendedSL, g_pendingTrade.intendedTP);
      g_pendingTrade.active = false;
   }
}
//-------------------------------------------------------------------
void ManageStealthPositions()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = g_posCount - 1; i >= 0; i--)
   {
      if(!g_positions[i].active) continue;
      ulong ticket = g_positions[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         g_positions[i].active = false;
         continue;
      }

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // Delayed SL
      if(currentSL == 0 && g_positions[i].intendedSL != 0)
      {
         if(TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds)
         {
            double sl = NormalizeDouble(g_positions[i].intendedSL, digits);
            if(trade.PositionModify(ticket, sl, 0))
               Print("ClawderEA STEALTH: SL set #", ticket);
         }
      }

      // Stealth TP
      if(g_positions[i].stealthTP > 0)
      {
         bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) ||
                      (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP);
         if(tpHit)
         {
            trade.PositionClose(ticket);
            Print("ClawderEA STEALTH: TP hit #", ticket);
            g_positions[i].active = false;
            continue;
         }
      }

      // Trailing: 500 pips -> BE + random pips
      if(g_positions[i].trailLevel < 1 && currentSL > 0)
      {
         double profitPips = (posType == POSITION_TYPE_BUY)
                             ? (currentPrice - g_positions[i].entryPrice) / point
                             : (g_positions[i].entryPrice - currentPrice) / point;
         if(profitPips >= TrailActivatePips)
         {
            double newSL = (posType == POSITION_TYPE_BUY)
                           ? g_positions[i].entryPrice + g_positions[i].randomBEPips * point
                           : g_positions[i].entryPrice - g_positions[i].randomBEPips * point;
            newSL = NormalizeDouble(newSL, digits);

            bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                                (posType == POSITION_TYPE_SELL && newSL < currentSL);
            if(shouldModify && trade.PositionModify(ticket, newSL, 0))
            {
               g_positions[i].trailLevel = 1;
               Print("ClawderEA STEALTH: Trail BE+", g_positions[i].randomBEPips, " #", ticket);
            }
         }
      }
   }
   CleanupPositions();
}
//-------------------------------------------------------------------
void CleanupPositions()
{
   int newCount = 0;
   for(int i = 0; i < g_posCount; i++)
   {
      if(g_positions[i].active)
      {
         if(i != newCount) g_positions[newCount] = g_positions[i];
         newCount++;
      }
   }
   if(newCount != g_posCount)
   {
      g_posCount = newCount;
      ArrayResize(g_positions, g_posCount);
   }
}
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
//-------------------------------------------------------------------
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
//+------------------------------------------------------------------+
