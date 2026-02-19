//+------------------------------------------------------------------+
//|                                           CALF_E_Breakout.mq5    |
//|                        *** CALF E - Breakout ***                 |
//|                   + Stealth Mode v2.0                            |
//|                   Version 2.0 - 2026-02-20                       |
//+------------------------------------------------------------------+
#property copyright "CALF E - Breakout + Stealth (2026-02-20)"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== BREAKOUT POSTAVKE ==="
input int      LookbackBars     = 20;
input double   BreakoutBuffer   = 0.5;

input group "=== VOLUME FILTER ==="
input bool     UseVolumeFilter  = true;
input int      VolumePeriod     = 20;

input group "=== TRADE MANAGEMENT ==="
input double   SLMultiplier     = 2.0;
input double   TPMultiplier     = 3.5;
input int      ATRPeriod        = 14;
input double   RiskPercent      = 1.0;

input group "=== STEALTH POSTAVKE ==="
input bool     UseStealthMode   = true;
input int      OpenDelayMin     = 0;
input int      OpenDelayMax     = 4;
input int      SLDelayMin       = 7;
input int      SLDelayMax       = 13;
input double   LargeCandleATR   = 3.0;

input group "=== TRAILING POSTAVKE ==="
input int      TrailActivatePips = 500;
input int      TrailBEPipsMin   = 33;
input int      TrailBEPipsMax   = 38;

input group "=== OPĆE ==="
input ulong    MagicNumber      = 100005;
input int      Slippage         = 30;

struct PendingTradeInfo { bool active; ENUM_ORDER_TYPE type; double lot; double intendedSL; double intendedTP; datetime signalTime; int delaySeconds; };
struct StealthPosInfo { bool active; ulong ticket; double intendedSL; double stealthTP; double entryPrice; datetime openTime; int delaySeconds; int randomBEPips; int trailLevel; };

CTrade trade;
int atrHandle;
datetime lastBarTime;
PendingTradeInfo g_pendingTrade;
StealthPosInfo g_positions[];
int g_posCount = 0;

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if(atrHandle == INVALID_HANDLE) return INIT_FAILED;
    lastBarTime = 0;
    MathSrand((uint)TimeCurrent() + (uint)GetTickCount());
    g_pendingTrade.active = false;
    ArrayResize(g_positions, 0); g_posCount = 0;
    Print("=== CALF E v2.0 STEALTH MODE ===");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle); }

int RandomRange(int minVal, int maxVal) { if(minVal >= maxVal) return minVal; return minVal + (MathRand() % (maxVal - minVal + 1)); }
bool IsTradingWindow() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); if(dt.day_of_week == 0) return (dt.hour > 1 || (dt.hour == 1 && dt.min >= 1)); if(dt.day_of_week >= 1 && dt.day_of_week <= 4) return true; if(dt.day_of_week == 5) return (dt.hour < 12 || (dt.hour == 12 && dt.min <= 30)); return false; }
bool IsBlackoutPeriod() { if(!UseStealthMode) return false; MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); int minutes = dt.hour * 60 + dt.min; return (minutes >= 15*60+30 && minutes < 16*60+30); }
bool IsLargeCandle() { if(!UseStealthMode) return false; double atr[]; ArraySetAsSeries(atr, true); if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return false; return ((iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1)) > LargeCandleATR * atr[0]); }
bool IsNewBar() { datetime t = iTime(_Symbol, PERIOD_CURRENT, 0); if(t != lastBarTime) { lastBarTime = t; return true; } return false; }
double GetATR() { double buf[]; ArraySetAsSeries(buf, true); if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return 0; return buf[0]; }
bool IsVolumeAboveAverage() { if(!UseVolumeFilter) return true; long vol[]; ArraySetAsSeries(vol, true); if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, VolumePeriod + 1, vol) <= 0) return true; double sum = 0; for(int i = 1; i <= VolumePeriod; i++) sum += (double)vol[i]; double avg = sum / (double)VolumePeriod; return ((double)vol[1] > avg * 1.2); }
double CalculateLotSize(double slDist) { if(slDist <= 0) return 0; double balance = AccountInfoDouble(ACCOUNT_BALANCE); double riskAmt = balance * RiskPercent / 100.0; double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); double lots = riskAmt / ((slDist / point) * tickVal / tickSize); lots = MathFloor(lots / lotStep) * lotStep; return MathMax(minLot, MathMin(maxLot, lots)); }
bool HasOpenPosition() { for(int i = PositionsTotal() - 1; i >= 0; i--) { ulong ticket = PositionGetTicket(i); if(PositionSelectByTicket(ticket)) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true; } return false; }

void QueueTrade(ENUM_ORDER_TYPE type) { double atr = GetATR(); if(atr <= 0) return; double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID); double sl = (type == ORDER_TYPE_BUY) ? price - SLMultiplier * atr : price + SLMultiplier * atr; double tp = (type == ORDER_TYPE_BUY) ? price + TPMultiplier * atr : price - TPMultiplier * atr; double lots = CalculateLotSize(SLMultiplier * atr); if(lots <= 0) return; if(UseStealthMode) { g_pendingTrade.active = true; g_pendingTrade.type = type; g_pendingTrade.lot = lots; g_pendingTrade.intendedSL = sl; g_pendingTrade.intendedTP = tp; g_pendingTrade.signalTime = TimeCurrent(); g_pendingTrade.delaySeconds = RandomRange(OpenDelayMin, OpenDelayMax); Print("CALF_E: Trade queued"); } else { ExecuteTrade(type, lots, sl, tp); } }
void ExecuteTrade(ENUM_ORDER_TYPE type, double lot, double sl, double tp) { double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID); int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits); bool ok; if(UseStealthMode) ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, 0, 0, "CALF_E") : trade.Sell(lot, _Symbol, price, 0, 0, "CALF_E"); else ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, "CALF_E BUY") : trade.Sell(lot, _Symbol, price, sl, tp, "CALF_E SELL"); if(ok && UseStealthMode) { ulong ticket = trade.ResultOrder(); ArrayResize(g_positions, g_posCount + 1); g_positions[g_posCount].active = true; g_positions[g_posCount].ticket = ticket; g_positions[g_posCount].intendedSL = sl; g_positions[g_posCount].stealthTP = tp; g_positions[g_posCount].entryPrice = price; g_positions[g_posCount].openTime = TimeCurrent(); g_positions[g_posCount].delaySeconds = RandomRange(SLDelayMin, SLDelayMax); g_positions[g_posCount].randomBEPips = RandomRange(TrailBEPipsMin, TrailBEPipsMax); g_positions[g_posCount].trailLevel = 0; g_posCount++; Print("CALF_E STEALTH: Opened #", ticket); } else if(ok) Print("CALF_E: ", lot); }
void ProcessPendingTrade() { if(!g_pendingTrade.active) return; if(TimeCurrent() >= g_pendingTrade.signalTime + g_pendingTrade.delaySeconds) { ExecuteTrade(g_pendingTrade.type, g_pendingTrade.lot, g_pendingTrade.intendedSL, g_pendingTrade.intendedTP); g_pendingTrade.active = false; } }
void ManageStealthPositions() { double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); for(int i = g_posCount - 1; i >= 0; i--) { if(!g_positions[i].active) continue; ulong ticket = g_positions[i].ticket; if(!PositionSelectByTicket(ticket)) { g_positions[i].active = false; continue; } ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE); double currentSL = PositionGetDouble(POSITION_SL); double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK); if(currentSL == 0 && g_positions[i].intendedSL != 0 && TimeCurrent() >= g_positions[i].openTime + g_positions[i].delaySeconds) { if(trade.PositionModify(ticket, NormalizeDouble(g_positions[i].intendedSL, digits), 0)) Print("CALF_E STEALTH: SL set #", ticket); } if(g_positions[i].stealthTP > 0) { bool tpHit = (posType == POSITION_TYPE_BUY && currentPrice >= g_positions[i].stealthTP) || (posType == POSITION_TYPE_SELL && currentPrice <= g_positions[i].stealthTP); if(tpHit) { trade.PositionClose(ticket); g_positions[i].active = false; continue; } } if(g_positions[i].trailLevel < 1 && currentSL > 0) { double profitPips = (posType == POSITION_TYPE_BUY) ? (currentPrice - g_positions[i].entryPrice) / point : (g_positions[i].entryPrice - currentPrice) / point; if(profitPips >= TrailActivatePips) { double newSL = (posType == POSITION_TYPE_BUY) ? g_positions[i].entryPrice + g_positions[i].randomBEPips * point : g_positions[i].entryPrice - g_positions[i].randomBEPips * point; newSL = NormalizeDouble(newSL, digits); bool shouldModify = (posType == POSITION_TYPE_BUY && newSL > currentSL) || (posType == POSITION_TYPE_SELL && newSL < currentSL); if(shouldModify && trade.PositionModify(ticket, newSL, 0)) { g_positions[i].trailLevel = 1; } } } } CleanupPositions(); }
void CleanupPositions() { int newCount = 0; for(int i = 0; i < g_posCount; i++) { if(g_positions[i].active) { if(i != newCount) g_positions[newCount] = g_positions[i]; newCount++; } } if(newCount != g_posCount) { g_posCount = newCount; ArrayResize(g_positions, g_posCount); } }

void OnTick()
{
    ProcessPendingTrade();
    ManageStealthPositions();
    if(!IsNewBar()) return;
    if(HasOpenPosition()) return;
    if(!IsTradingWindow()) return;
    if(IsBlackoutPeriod()) return;
    if(IsLargeCandle()) return;
    if(g_pendingTrade.active) return;

    double high[], low[], close[];
    ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
    if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_CURRENT, 0, LookbackBars + 2, low) <= 0) return;
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, close) <= 0) return;
    double highestHigh = high[2]; double lowestLow = low[2];
    for(int i = 2; i < LookbackBars + 2; i++) { if(high[i] > highestHigh) highestHigh = high[i]; if(low[i] < lowestLow) lowestLow = low[i]; }
    double atr = GetATR();
    double buffer = BreakoutBuffer * atr;
    bool buySignal = (close[1] > highestHigh + buffer) && (close[2] <= highestHigh);
    bool sellSignal = (close[1] < lowestLow - buffer) && (close[2] >= lowestLow);
    if(!IsVolumeAboveAverage()) { buySignal = false; sellSignal = false; }
    if(buySignal) { Print("CALF_E BUY SIGNAL"); QueueTrade(ORDER_TYPE_BUY); }
    else if(sellSignal) { Print("CALF_E SELL SIGNAL"); QueueTrade(ORDER_TYPE_SELL); }
}
//+------------------------------------------------------------------+
