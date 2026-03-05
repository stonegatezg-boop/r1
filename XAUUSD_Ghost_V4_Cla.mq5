//+------------------------------------------------------------------+
//|                                         XAUUSD_Ghost_V4_Cla.mq5  |
//|   Strategy : Asian Liquidity Sweep + NY Killzone Reversal        |
//|   Timeframe: M5 entry  |  H1 bias  |  H4 structure               |
//|   Instrument: XAUUSD (Gold vs USD)                               |
//|   Created: 02.03.2026 15:30 (Zagreb)                             |
//|   Fixed: 05.03.2026 (Zagreb) - SL ODMAH + 3-level trail + MFE   |
//|                                                                  |
//|  IMPROVEMENTS over V3:                                           |
//|  - Relaxed sweep detection (displacement-based)                  |
//|  - Extended killzone windows (optional, OFF by default)          |
//|  - Optional H1 bias (less strict)                                |
//|  - Multiple FVG tracking                                         |
//|  - Diagnostic logging                                            |
//|  - Stealth TP (ne šalje brokeru)                                 |
//|  - Delayed SL (7-13 sec)                                         |
//|  - 3-target partial close system                                 |
//|  - SMART TRAILING (continues trailing after L2, never gives back)|
//+------------------------------------------------------------------+
#property copyright   "XAUUSD Ghost EA v4.2 Cla"
#property version     "4.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//──────────────────────────────────────────────
//  INPUT GROUPS
//──────────────────────────────────────────────
input group "═══ RISK MANAGEMENT ═══"
input double  RiskPercent       = 1.0;      // % rizika po tradu
input double  FixedLot          = 0.01;     // Fiksni lot (ako UseDynamic=false)
input bool    UseDynamicLot     = true;     // Dinamički lot (% risk)
input double  MinRR             = 1.5;      // Minimalni R:R omjer (sniženo s 1.8)
input int     MaxTrades         = 2;        // Max otvorenih trades (povećano)

input group "═══ ASIAN RANGE ═══"
input int     AsianOpen_GMT     = 0;        // Asian session start (GMT)
input int     AsianClose_GMT    = 7;        // Asian session end (GMT)
input int     SweepBuffer       = 5;        // Buffer iznad/ispod range (points) - sniženo
input int     SweepConfirmBars  = 5;        // Broj M5 svjeća za potvrdu sweep-a (povećano)
input double  SweepDisplacement = 0.3;      // Min displacement ratio (0.3 = 30% range)

input group "═══ KILLZONE WINDOWS ═══"
input bool    UseKillzoneFilter = false;    // Killzone filter (OFF = trejda cijeli dan)
input bool    UseLondonKZ       = true;     // London Killzone (ako je filter ON)
input bool    UseNY_KZ          = true;     // NY Killzone (ako je filter ON)
input int     LondonKZ_Start    = 6;        // London KZ start GMT
input int     LondonKZ_End      = 11;       // London KZ end GMT
input int     NY_KZ_Start       = 13;       // NY KZ start GMT
input int     NY_KZ_End         = 18;       // NY KZ end GMT

input group "═══ FVG & STRUCTURE ═══"
input int     FVG_MinSize       = 3;        // Min FVG veličina (points) - sniženo
input int     FVG_MaxAge        = 20;       // Maks. starost FVG u M5 svjećama (povećano)
input int     ATR_Period        = 14;       // ATR period za SL/TP
input double  ATR_SL_Mult       = 1.5;      // ATR multiplikator za Stop Loss
input double  ATR_TP_Mult       = 2.5;      // ATR multiplikator za Take Profit

input group "═══ FILTERS ═══"
input double  MaxSpread         = 50;       // Max spread u pointima (povećano)
input bool    UseH1Bias         = false;    // H1 struktura potvrda (ISKLJUČENO default)
input bool    UseStrictSweep    = false;    // Striktna sweep detekcija (ISKLJUČENO)

input group "═══ TARGETS (pips) ═══"
input int     Target1_Pips      = 200;      // Target 1 - zatvori 33%
input int     Target2_Pips      = 350;      // Target 2 - zatvori 50% preostalog
input int     Target3_Pips      = 600;      // Target 3 - zatvori ostatak

input group "═══ TRAILING (3-LEVEL + MFE) ═══"
input int     TrailingStart1    = 500;      // L1: Pips za BE move
input int     BE_LockMin        = 38;       // L1: BE + min pips
input int     BE_LockMax        = 43;       // L1: BE + max pips
input int     TrailingStart2    = 800;      // L2: Pips za profit lock
input int     ProfitLockMin     = 150;      // L2: Lock min pips
input int     ProfitLockMax     = 200;      // L2: Lock max pips
input int     TrailingStart3    = 1200;     // L3: Lock profit aktivacija
input int     Lock3Min          = 180;      // L3: Lock min pips
input int     Lock3Max          = 220;      // L3: Lock max pips
input int     MFE_Pips          = 1500;     // MFE: Trail aktivacija (pips)
input int     MFE_TrailDist     = 500;      // MFE: Trail distance (pips)

input group "═══ STEALTH & TIMING ═══"
input int     SL_DelayMin       = 7;        // Min delay za SL (sekunde)
input int     SL_DelayMax       = 13;       // Max delay za SL (sekunde)
input bool    UseStealthTP      = true;     // Stealth TP (ne šalje brokeru)
input int     MagicNumber       = 202503;   // Magic Number

//──────────────────────────────────────────────
//  GLOBAL STATE
//──────────────────────────────────────────────
struct AsianRange {
   double   high;
   double   low;
   double   mid;
   double   size;
   bool     valid;
   bool     highSwept;
   bool     lowSwept;
   datetime sweepTime;
   int      sweepDir;      // +1 swept high (expect sell), -1 swept low (expect buy)
   double   sweepPrice;
};

struct FVG {
   double   top;
   double   bottom;
   double   mid;
   int      dir;           // +1 bullish, -1 bearish
   datetime time;
   bool     active;
   bool     touched;
};

struct PendingSL {
   ulong    ticket;
   double   sl;
   datetime sendTime;
   bool     pending;
};

AsianRange  g_asian;
FVG         g_fvg[5];           // Track multiple FVGs
int         g_fvgCount = 0;
PendingSL   g_pendingSL[];
datetime    g_lastBarM5 = 0;
datetime    g_lastBarH1 = 0;
int         g_atrHandle, g_atrH1Handle;
int         g_emaH1Handle;
double      g_h1Bias;           // +1 bullish, -1 bearish, 0 neutral
datetime    g_currentDay = 0;
int         g_tradesToday = 0;
double      g_point;
int         g_digits;

// Partial close tracking
struct PartialTrack {
   ulong    ticket;
   bool     t1_closed;
   bool     t2_closed;
   double   originalLot;
   double   entryPrice;
   int      direction;     // +1 buy, -1 sell
   int      trailLevel;    // 0=none, 1=BE, 2=lock, 3=lock200
   int      randomBE;      // Random BE offset
   int      randomL2;      // Random L2 lock
   int      randomL3;      // Random L3 lock
   double   maxProfit;     // MFE tracking
};
PartialTrack g_partials[];

//──────────────────────────────────────────────
//  INIT
//──────────────────────────────────────────────
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);

   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   g_atrHandle   = iATR(_Symbol, PERIOD_M5, ATR_Period);
   g_atrH1Handle = iATR(_Symbol, PERIOD_H1, ATR_Period);
   g_emaH1Handle = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE || g_atrH1Handle == INVALID_HANDLE || g_emaH1Handle == INVALID_HANDLE)
   {
      Print("[GHOST V4] GREŠKA: Indikatori nisu inicijalizirani!");
      return INIT_FAILED;
   }

   ResetAsianRange();
   ResetFVGs();

   Print("[GHOST V4] ══════════════════════════════════════");
   Print("[GHOST V4] Inicijalizacija uspješna");
   Print("[GHOST V4] Symbol: ", _Symbol, " | Point: ", g_point);
   Print("[GHOST V4] Killzone Filter: ", UseKillzoneFilter ? "UKLJUČEN" : "ISKLJUČEN (trejda cijeli dan)");
   if(UseKillzoneFilter)
   {
      Print("[GHOST V4]   London: ", LondonKZ_Start, "-", LondonKZ_End, " GMT");
      Print("[GHOST V4]   NY: ", NY_KZ_Start, "-", NY_KZ_End, " GMT");
   }
   Print("[GHOST V4] H1 Bias: ", UseH1Bias ? "UKLJUČEN" : "ISKLJUČEN");
   Print("[GHOST V4] Stealth TP: ", UseStealthTP ? "DA" : "NE");
   Print("[GHOST V4] Smart Trail: L3 aktivacija @ ", TrailingStart3, " pips, distance ", MFE_TrailDist, " pips");
   Print("[GHOST V4] ══════════════════════════════════════");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(g_atrHandle);
   IndicatorRelease(g_atrH1Handle);
   IndicatorRelease(g_emaH1Handle);
   ObjectsDeleteAll(0, "GHOST_");
   Comment("");
}

//──────────────────────────────────────────────
//  MAIN TICK
//──────────────────────────────────────────────
void OnTick()
{
   // 1. Manage existing trades (stealth TP, trailing, partials)
   ManageOpenTrades();

   // 2. Process pending SL orders (delayed send)
   ProcessPendingSL();

   // 3. Draw dashboard
   DrawDashboard();

   // 4. New bar logic
   datetime barM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(barM5 == g_lastBarM5) return;
   g_lastBarM5 = barM5;

   // 5. New day reset
   MqlDateTime dt;
   TimeGMT(dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(today != g_currentDay)
   {
      g_currentDay   = today;
      g_tradesToday  = 0;
      ResetAsianRange();
      ResetFVGs();
      Print("[GHOST V4] ═══ NOVI DAN: ", TimeToString(today, TIME_DATE), " ═══");
   }

   // 6. Spread check
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      static datetime lastSpreadWarn = 0;
      if(TimeCurrent() - lastSpreadWarn > 300)
      {
         Print("[GHOST V4] Spread previsok: ", spread, " > ", MaxSpread);
         lastSpreadWarn = TimeCurrent();
      }
      return;
   }

   // 7. Build Asian Range
   BuildAsianRange(dt);

   // 8. Detect sweep
   if(g_asian.valid && !g_asian.highSwept && !g_asian.lowSwept)
      DetectSweep(dt);

   // 9. Detect FVG after sweep
   if(g_asian.valid && (g_asian.highSwept || g_asian.lowSwept))
      DetectFVG();

   // 10. Try entry
   if(CountMyTrades() < MaxTrades && !IsWeekendBlocked(dt))
   {
      if(IsInKillzone(dt))
         TryEntry(dt);
      else
      {
         static datetime lastKZWarn = 0;
         if(TimeCurrent() - lastKZWarn > 600)
         {
            Print("[GHOST V4] Izvan killzone. Sat GMT: ", dt.hour);
            lastKZWarn = TimeCurrent();
         }
      }
   }

   // 11. Update H1 bias
   UpdateH1Bias();
}

//──────────────────────────────────────────────
//  BUILD ASIAN RANGE
//──────────────────────────────────────────────
void BuildAsianRange(MqlDateTime &dt)
{
   int hour = dt.hour;
   if(hour < AsianOpen_GMT || hour >= AsianClose_GMT) return;

   double high = iHigh(_Symbol, PERIOD_M5, 1);
   double low  = iLow(_Symbol, PERIOD_M5, 1);

   if(!g_asian.valid)
   {
      g_asian.high  = high;
      g_asian.low   = low;
      g_asian.valid = true;
      Print("[GHOST V4] Asian range ZAPOČET: ", g_asian.low, " - ", g_asian.high);
   }
   else
   {
      if(high > g_asian.high) g_asian.high = high;
      if(low  < g_asian.low)  g_asian.low  = low;
   }

   g_asian.mid  = (g_asian.high + g_asian.low) / 2.0;
   g_asian.size = g_asian.high - g_asian.low;
}

//──────────────────────────────────────────────
//  DETECT SWEEP (relaxed version)
//──────────────────────────────────────────────
void DetectSweep(MqlDateTime &dt)
{
   if(!g_asian.valid || g_asian.size <= 0) return;

   double bufPts     = SweepBuffer * g_point;
   double minDisp    = g_asian.size * SweepDisplacement;

   for(int i = 1; i <= SweepConfirmBars; i++)
   {
      double high_i  = iHigh(_Symbol, PERIOD_M5, i);
      double low_i   = iLow(_Symbol, PERIOD_M5, i);
      double close_i = iClose(_Symbol, PERIOD_M5, i);
      double open_i  = iOpen(_Symbol, PERIOD_M5, i);

      // === SWEEP HIGH (expect SELL) ===
      // Relaxed: wick above Asian high, then displacement down
      if(high_i > g_asian.high + bufPts)
      {
         bool validSweep = false;

         if(UseStrictSweep)
         {
            // Strict: must close below Asian high
            validSweep = (close_i < g_asian.high);
         }
         else
         {
            // Relaxed: just need displacement (close significantly below high)
            double displacement = high_i - close_i;
            validSweep = (displacement >= minDisp) || (close_i < g_asian.mid);
         }

         if(validSweep)
         {
            g_asian.highSwept  = true;
            g_asian.sweepTime  = iTime(_Symbol, PERIOD_M5, i);
            g_asian.sweepDir   = +1;
            g_asian.sweepPrice = high_i;
            Print("[GHOST V4] ▼ HIGH SWEPT @ ", high_i, " | Asian High: ", g_asian.high);
            Print("[GHOST V4]   Očekujem SELL setup (FVG bearish)");
            DrawSweepLine(g_asian.high, true);
            return;
         }
      }

      // === SWEEP LOW (expect BUY) ===
      if(low_i < g_asian.low - bufPts)
      {
         bool validSweep = false;

         if(UseStrictSweep)
         {
            validSweep = (close_i > g_asian.low);
         }
         else
         {
            double displacement = close_i - low_i;
            validSweep = (displacement >= minDisp) || (close_i > g_asian.mid);
         }

         if(validSweep)
         {
            g_asian.lowSwept   = true;
            g_asian.sweepTime  = iTime(_Symbol, PERIOD_M5, i);
            g_asian.sweepDir   = -1;
            g_asian.sweepPrice = low_i;
            Print("[GHOST V4] ▲ LOW SWEPT @ ", low_i, " | Asian Low: ", g_asian.low);
            Print("[GHOST V4]   Očekujem BUY setup (FVG bullish)");
            DrawSweepLine(g_asian.low, false);
            return;
         }
      }
   }
}

//──────────────────────────────────────────────
//  DETECT FVG (Fair Value Gap)
//──────────────────────────────────────────────
void DetectFVG()
{
   if(g_fvgCount >= 5) return;  // Max 5 FVGs tracked

   double minSize = FVG_MinSize * g_point;

   for(int i = 1; i <= FVG_MaxAge; i++)
   {
      datetime barT = iTime(_Symbol, PERIOD_M5, i);
      if(barT < g_asian.sweepTime) break;

      // Check if this FVG already exists
      bool exists = false;
      for(int j = 0; j < g_fvgCount; j++)
      {
         if(MathAbs(g_fvg[j].time - barT) < 60) { exists = true; break; }
      }
      if(exists) continue;

      double high3 = iHigh(_Symbol, PERIOD_M5, i + 2);
      double low3  = iLow(_Symbol, PERIOD_M5, i + 2);
      double high1 = iHigh(_Symbol, PERIOD_M5, i);
      double low1  = iLow(_Symbol, PERIOD_M5, i);

      // === BULLISH FVG (after LOW sweep) ===
      if(g_asian.sweepDir == -1)
      {
         // Gap: candle[i+2].high < candle[i].low
         if(high3 < low1 && (low1 - high3) >= minSize)
         {
            g_fvg[g_fvgCount].top     = low1;
            g_fvg[g_fvgCount].bottom  = high3;
            g_fvg[g_fvgCount].mid     = (low1 + high3) / 2.0;
            g_fvg[g_fvgCount].dir     = +1;
            g_fvg[g_fvgCount].time    = barT;
            g_fvg[g_fvgCount].active  = true;
            g_fvg[g_fvgCount].touched = false;

            Print("[GHOST V4] ✓ BULLISH FVG #", g_fvgCount + 1, ": ",
                  g_fvg[g_fvgCount].bottom, " - ", g_fvg[g_fvgCount].top);
            DrawFVGBox(g_fvg[g_fvgCount].bottom, g_fvg[g_fvgCount].top, true, barT, g_fvgCount);
            g_fvgCount++;

            if(g_fvgCount >= 5) return;
         }
      }

      // === BEARISH FVG (after HIGH sweep) ===
      if(g_asian.sweepDir == +1)
      {
         // Gap: candle[i+2].low > candle[i].high
         if(low3 > high1 && (low3 - high1) >= minSize)
         {
            g_fvg[g_fvgCount].top     = low3;
            g_fvg[g_fvgCount].bottom  = high1;
            g_fvg[g_fvgCount].mid     = (low3 + high1) / 2.0;
            g_fvg[g_fvgCount].dir     = -1;
            g_fvg[g_fvgCount].time    = barT;
            g_fvg[g_fvgCount].active  = true;
            g_fvg[g_fvgCount].touched = false;

            Print("[GHOST V4] ✓ BEARISH FVG #", g_fvgCount + 1, ": ",
                  g_fvg[g_fvgCount].bottom, " - ", g_fvg[g_fvgCount].top);
            DrawFVGBox(g_fvg[g_fvgCount].bottom, g_fvg[g_fvgCount].top, false, barT, g_fvgCount);
            g_fvgCount++;

            if(g_fvgCount >= 5) return;
         }
      }
   }
}

//──────────────────────────────────────────────
//  TRY ENTRY
//──────────────────────────────────────────────
void TryEntry(MqlDateTime &dt)
{
   if(g_fvgCount == 0)
   {
      static datetime lastNoFVG = 0;
      if(TimeCurrent() - lastNoFVG > 600)
      {
         Print("[GHOST V4] Nema aktivnih FVG-ova za ulaz");
         lastNoFVG = TimeCurrent();
      }
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATR(g_atrHandle, 1);

   if(atr <= 0) return;

   // H1 bias check (if enabled)
   if(UseH1Bias)
   {
      UpdateH1Bias();
   }

   for(int i = 0; i < g_fvgCount; i++)
   {
      if(!g_fvg[i].active) continue;

      // H1 bias filter
      if(UseH1Bias)
      {
         if(g_fvg[i].dir == +1 && g_h1Bias == -1) continue;
         if(g_fvg[i].dir == -1 && g_h1Bias == +1) continue;
      }

      double sl_pts = atr * ATR_SL_Mult;
      double tp_pts = atr * ATR_TP_Mult;

      // R:R check
      if(tp_pts / sl_pts < MinRR)
      {
         Print("[GHOST V4] R:R premali: ", DoubleToString(tp_pts / sl_pts, 2), " < ", MinRR);
         continue;
      }

      // === BUY ENTRY ===
      if(g_fvg[i].dir == +1)
      {
         // Entry zone: price touches or enters FVG zone
         // Relaxed: also allow entry slightly below FVG (50% extension)
         double entryZoneBottom = g_fvg[i].bottom - (g_fvg[i].top - g_fvg[i].bottom) * 0.5;

         if(ask >= entryZoneBottom && ask <= g_fvg[i].top)
         {
            double sl = NormalizeDouble(ask - sl_pts, g_digits);
            double tp = UseStealthTP ? 0 : NormalizeDouble(ask + tp_pts, g_digits);
            double lot = CalcLot(sl_pts);

            // SL ODMAH - postavlja se odmah pri otvaranju trejda
            if(trade.Buy(lot, _Symbol, ask, sl, tp, StringFormat("GHOST_BUY_%d", i)))
            {
               ulong ticket = trade.ResultOrder();
               Print("[GHOST V4] ══════════════════════════════════════");
               Print("[GHOST V4] ✓ BUY ULAZAN @ ", ask, " (SL ODMAH!)");
               Print("[GHOST V4]   SL: ", sl, " (ODMAH!) | TP (stealth): ", ask + tp_pts);
               Print("[GHOST V4]   Lot: ", lot, " | R:R: ", DoubleToString(tp_pts / sl_pts, 2));
               Print("[GHOST V4]   FVG zona: ", g_fvg[i].bottom, " - ", g_fvg[i].top);
               Print("[GHOST V4]   ENTRY HOUR (GMT): ", dt.hour, ":00 - za analizu performansi");
               Print("[GHOST V4] ══════════════════════════════════════");

               // Track for partial closes (SL vec postavljen)
               AddPartialTrack(ticket, lot, ask, +1);

               g_fvg[i].active = false;
               g_tradesToday++;
               return;
            }
         }
      }

      // === SELL ENTRY ===
      if(g_fvg[i].dir == -1)
      {
         double entryZoneTop = g_fvg[i].top + (g_fvg[i].top - g_fvg[i].bottom) * 0.5;

         if(bid >= g_fvg[i].bottom && bid <= entryZoneTop)
         {
            double sl = NormalizeDouble(bid + sl_pts, g_digits);
            double tp = UseStealthTP ? 0 : NormalizeDouble(bid - tp_pts, g_digits);
            double lot = CalcLot(sl_pts);

            // SL ODMAH - postavlja se odmah pri otvaranju trejda
            if(trade.Sell(lot, _Symbol, bid, sl, tp, StringFormat("GHOST_SELL_%d", i)))
            {
               ulong ticket = trade.ResultOrder();
               Print("[GHOST V4] ══════════════════════════════════════");
               Print("[GHOST V4] ✓ SELL ULAZAN @ ", bid, " (SL ODMAH!)");
               Print("[GHOST V4]   SL: ", sl, " (ODMAH!) | TP (stealth): ", bid - tp_pts);
               Print("[GHOST V4]   Lot: ", lot, " | R:R: ", DoubleToString(tp_pts / sl_pts, 2));
               Print("[GHOST V4]   FVG zona: ", g_fvg[i].bottom, " - ", g_fvg[i].top);
               Print("[GHOST V4]   ENTRY HOUR (GMT): ", dt.hour, ":00 - za analizu performansi");
               Print("[GHOST V4] ══════════════════════════════════════");

               // Track for partial closes (SL vec postavljen)
               AddPartialTrack(ticket, lot, bid, -1);

               g_fvg[i].active = false;
               g_tradesToday++;
               return;
            }
         }
      }
   }
}

//──────────────────────────────────────────────
//  MANAGE OPEN TRADES
//  - Stealth TP (close at target, no TP sent to broker)
//  - 3-target partial close system
//  - 2-level trailing stop
//──────────────────────────────────────────────
void ManageOpenTrades()
{
   double pipValue = g_point * 10;  // 1 pip = 10 points for XAUUSD

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != MagicNumber) continue;

      ulong  ticket = pos.Ticket();
      double open   = pos.PriceOpen();
      double curSL  = pos.StopLoss();
      double curTP  = pos.TakeProfit();
      double curLot = pos.Volume();

      // Find partial tracking
      int pIdx = FindPartialTrack(ticket);

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitPips = (bid - open) / pipValue;

         // === STEALTH TP: Target 1 (33% close) ===
         if(pIdx >= 0 && !g_partials[pIdx].t1_closed && profitPips >= Target1_Pips)
         {
            double closeLot = NormalizeDouble(g_partials[pIdx].originalLot * 0.33, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t1_closed = true;
               Print("[GHOST V4] ✓ TARGET 1 (33%) ZATVOREN @ ", bid, " | +", profitPips, " pips");
            }
         }

         // === STEALTH TP: Target 2 (50% of remaining) ===
         if(pIdx >= 0 && g_partials[pIdx].t1_closed && !g_partials[pIdx].t2_closed && profitPips >= Target2_Pips)
         {
            double remainingLot = curLot;
            double closeLot = NormalizeDouble(remainingLot * 0.5, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t2_closed = true;
               Print("[GHOST V4] ✓ TARGET 2 (50%) ZATVOREN @ ", bid, " | +", profitPips, " pips");
            }
         }

         // === STEALTH TP: Target 3 (close all) ===
         if(profitPips >= Target3_Pips)
         {
            if(trade.PositionClose(ticket))
            {
               Print("[GHOST V4] ✓ TARGET 3 (100%) ZATVOREN @ ", bid, " | +", profitPips, " pips");
               RemovePartialTrack(ticket);
            }
         }

         // === 3-LEVEL TRAILING + MFE ===
         // Update MFE
         if(pIdx >= 0 && profitPips > g_partials[pIdx].maxProfit)
            g_partials[pIdx].maxProfit = profitPips;

         // MFE TRAILING - ako profit >= MFE_Pips, trail MFE_TrailDist iza max
         if(pIdx >= 0 && g_partials[pIdx].trailLevel >= 3 && profitPips >= MFE_Pips)
         {
            double mfeSL = NormalizeDouble(open + (g_partials[pIdx].maxProfit - MFE_TrailDist) * pipValue, g_digits);
            if(mfeSL > curSL)
            {
               trade.PositionModify(ticket, mfeSL, curTP);
               Print("[GHOST V4] MFE TRAIL: SL @ ", mfeSL, " | Max: +", (int)g_partials[pIdx].maxProfit, " pips");
            }
         }
         // L3: Lock 180-220 pips @ 1200 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 2 && profitPips >= TrailingStart3)
         {
            double newSL = NormalizeDouble(open + g_partials[pIdx].randomL3 * pipValue, g_digits);
            if(newSL > curSL)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 3;
                  Print("[GHOST V4] L3: Lock +", g_partials[pIdx].randomL3, " @ ", newSL);
               }
            }
         }
         // L2: Lock 150-200 pips @ 800 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 1 && profitPips >= TrailingStart2)
         {
            double newSL = NormalizeDouble(open + g_partials[pIdx].randomL2 * pipValue, g_digits);
            if(newSL > curSL)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 2;
                  Print("[GHOST V4] L2: Lock +", g_partials[pIdx].randomL2, " @ ", newSL);
               }
            }
         }
         // L1: BE + 38-43 pips @ 500 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 0 && profitPips >= TrailingStart1)
         {
            double newSL = NormalizeDouble(open + g_partials[pIdx].randomBE * pipValue, g_digits);
            if(newSL > curSL)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 1;
                  Print("[GHOST V4] L1: BE+", g_partials[pIdx].randomBE, " @ ", newSL);
               }
            }
         }
      }
      else if(pos.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPips = (open - ask) / pipValue;

         // === STEALTH TP: Target 1 ===
         if(pIdx >= 0 && !g_partials[pIdx].t1_closed && profitPips >= Target1_Pips)
         {
            double closeLot = NormalizeDouble(g_partials[pIdx].originalLot * 0.33, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t1_closed = true;
               Print("[GHOST V4] ✓ TARGET 1 (33%) ZATVOREN @ ", ask, " | +", profitPips, " pips");
            }
         }

         // === STEALTH TP: Target 2 ===
         if(pIdx >= 0 && g_partials[pIdx].t1_closed && !g_partials[pIdx].t2_closed && profitPips >= Target2_Pips)
         {
            double remainingLot = curLot;
            double closeLot = NormalizeDouble(remainingLot * 0.5, 2);
            closeLot = MathMax(closeLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

            if(trade.PositionClosePartial(ticket, closeLot))
            {
               g_partials[pIdx].t2_closed = true;
               Print("[GHOST V4] ✓ TARGET 2 (50%) ZATVOREN @ ", ask, " | +", profitPips, " pips");
            }
         }

         // === STEALTH TP: Target 3 ===
         if(profitPips >= Target3_Pips)
         {
            if(trade.PositionClose(ticket))
            {
               Print("[GHOST V4] ✓ TARGET 3 (100%) ZATVOREN @ ", ask, " | +", profitPips, " pips");
               RemovePartialTrack(ticket);
            }
         }

         // === 3-LEVEL TRAILING + MFE ===
         // Update MFE
         if(pIdx >= 0 && profitPips > g_partials[pIdx].maxProfit)
            g_partials[pIdx].maxProfit = profitPips;

         // MFE TRAILING - ako profit >= MFE_Pips, trail MFE_TrailDist iza max
         if(pIdx >= 0 && g_partials[pIdx].trailLevel >= 3 && profitPips >= MFE_Pips)
         {
            double mfeSL = NormalizeDouble(open - (g_partials[pIdx].maxProfit - MFE_TrailDist) * pipValue, g_digits);
            if(mfeSL < curSL || curSL == 0)
            {
               trade.PositionModify(ticket, mfeSL, curTP);
               Print("[GHOST V4] MFE TRAIL: SL @ ", mfeSL, " | Max: +", (int)g_partials[pIdx].maxProfit, " pips");
            }
         }
         // L3: Lock 180-220 pips @ 1200 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 2 && profitPips >= TrailingStart3)
         {
            double newSL = NormalizeDouble(open - g_partials[pIdx].randomL3 * pipValue, g_digits);
            if(newSL < curSL || curSL == 0)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 3;
                  Print("[GHOST V4] L3: Lock +", g_partials[pIdx].randomL3, " @ ", newSL);
               }
            }
         }
         // L2: Lock 150-200 pips @ 800 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 1 && profitPips >= TrailingStart2)
         {
            double newSL = NormalizeDouble(open - g_partials[pIdx].randomL2 * pipValue, g_digits);
            if(newSL < curSL || curSL == 0)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 2;
                  Print("[GHOST V4] L2: Lock +", g_partials[pIdx].randomL2, " @ ", newSL);
               }
            }
         }
         // L1: BE + 38-43 pips @ 500 pips profit
         else if(pIdx >= 0 && g_partials[pIdx].trailLevel == 0 && profitPips >= TrailingStart1)
         {
            double newSL = NormalizeDouble(open - g_partials[pIdx].randomBE * pipValue, g_digits);
            if(newSL < curSL || curSL == 0)
            {
               if(trade.PositionModify(ticket, newSL, curTP))
               {
                  g_partials[pIdx].trailLevel = 1;
                  Print("[GHOST V4] L1: BE+", g_partials[pIdx].randomBE, " @ ", newSL);
               }
            }
         }
      }
   }
}

//──────────────────────────────────────────────
//  PENDING SL (Delayed Send)
//──────────────────────────────────────────────
void AddPendingSL(ulong ticket, double sl)
{
   int size = ArraySize(g_pendingSL);
   ArrayResize(g_pendingSL, size + 1);

   int delay = SL_DelayMin + MathRand() % (SL_DelayMax - SL_DelayMin + 1);

   g_pendingSL[size].ticket   = ticket;
   g_pendingSL[size].sl       = sl;
   g_pendingSL[size].sendTime = TimeCurrent() + delay;
   g_pendingSL[size].pending  = true;

   Print("[GHOST V4] SL queued for ticket #", ticket, " | Delay: ", delay, "s | SL: ", sl);
}

void ProcessPendingSL()
{
   for(int i = ArraySize(g_pendingSL) - 1; i >= 0; i--)
   {
      if(!g_pendingSL[i].pending) continue;
      if(TimeCurrent() < g_pendingSL[i].sendTime) continue;

      // Time to send SL
      if(PositionSelectByTicket(g_pendingSL[i].ticket))
      {
         double curTP = PositionGetDouble(POSITION_TP);
         if(trade.PositionModify(g_pendingSL[i].ticket, g_pendingSL[i].sl, curTP))
         {
            Print("[GHOST V4] ✓ SL POSLAN (delayed) za ticket #", g_pendingSL[i].ticket, " @ ", g_pendingSL[i].sl);
         }
      }
      g_pendingSL[i].pending = false;
   }

   // Cleanup old entries
   int newSize = 0;
   for(int i = 0; i < ArraySize(g_pendingSL); i++)
   {
      if(g_pendingSL[i].pending)
      {
         if(i != newSize) g_pendingSL[newSize] = g_pendingSL[i];
         newSize++;
      }
   }
   ArrayResize(g_pendingSL, newSize);
}

//──────────────────────────────────────────────
//  PARTIAL CLOSE TRACKING
//──────────────────────────────────────────────
void AddPartialTrack(ulong ticket, double lot, double entry, int dir)
{
   int size = ArraySize(g_partials);
   ArrayResize(g_partials, size + 1);

   g_partials[size].ticket      = ticket;
   g_partials[size].t1_closed   = false;
   g_partials[size].t2_closed   = false;
   g_partials[size].originalLot = lot;
   g_partials[size].entryPrice  = entry;
   g_partials[size].direction   = dir;
   g_partials[size].trailLevel  = 0;
   g_partials[size].randomBE    = BE_LockMin + MathRand() % (BE_LockMax - BE_LockMin + 1);
   g_partials[size].randomL2    = ProfitLockMin + MathRand() % (ProfitLockMax - ProfitLockMin + 1);
   g_partials[size].randomL3    = Lock3Min + MathRand() % (Lock3Max - Lock3Min + 1);
   g_partials[size].maxProfit   = 0;
}

int FindPartialTrack(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_partials); i++)
   {
      if(g_partials[i].ticket == ticket) return i;
   }
   return -1;
}

void RemovePartialTrack(ulong ticket)
{
   int idx = FindPartialTrack(ticket);
   if(idx < 0) return;

   int last = ArraySize(g_partials) - 1;
   if(idx != last) g_partials[idx] = g_partials[last];
   ArrayResize(g_partials, last);
}

//──────────────────────────────────────────────
//  H1 BIAS
//──────────────────────────────────────────────
void UpdateH1Bias()
{
   datetime barH1 = iTime(_Symbol, PERIOD_H1, 0);
   if(barH1 == g_lastBarH1) return;
   g_lastBarH1 = barH1;

   double ema50    = GetATR(g_emaH1Handle, 1);  // reusing helper, it's just buffer read
   double close_h1 = iClose(_Symbol, PERIOD_H1, 1);
   double high1    = iHigh(_Symbol, PERIOD_H1, 1);
   double low1     = iLow(_Symbol, PERIOD_H1, 1);
   double high2    = iHigh(_Symbol, PERIOD_H1, 2);
   double low2     = iLow(_Symbol, PERIOD_H1, 2);

   bool hh = (high1 > high2);
   bool hl = (low1 > low2);
   bool lh = (high1 < high2);
   bool ll = (low1 < low2);
   bool aboveEMA = (close_h1 > ema50);

   // Relaxed bias detection (only need one condition, not both)
   if((hh || hl) && aboveEMA)        g_h1Bias = +1;
   else if((lh || ll) && !aboveEMA)  g_h1Bias = -1;
   else                               g_h1Bias = 0;
}

//──────────────────────────────────────────────
//  HELPERS
//──────────────────────────────────────────────
bool IsWeekendBlocked(MqlDateTime &dt)
{
   int dow  = dt.day_of_week;
   int hour = dt.hour;

   // Friday >= 11:30 GMT (using 11:00 for simplicity)
   if(dow == 5 && hour >= 11) return true;
   // Saturday
   if(dow == 6) return true;
   // Sunday before 00:01
   if(dow == 0 && hour < 1) return true;

   return false;
}

bool IsInKillzone(MqlDateTime &dt)
{
   // Ako je killzone filter ISKLJUČEN, uvijek vraća true (trejda cijeli dan)
   if(!UseKillzoneFilter) return true;

   int h = dt.hour;
   if(UseLondonKZ && h >= LondonKZ_Start && h < LondonKZ_End) return true;
   if(UseNY_KZ    && h >= NY_KZ_Start    && h < NY_KZ_End)    return true;
   return false;
}

double GetATR(int handle, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

double CalcLot(double slPoints)
{
   if(!UseDynamicLot) return FixedLot;

   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * (RiskPercent / 100.0);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickVal <= 0 || tickSize <= 0) return FixedLot;

   double slMoney = (slPoints / tickSize) * tickVal;
   if(slMoney <= 0) return FixedLot;

   double lot = riskAmt / slMoney;
   lot = MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));

   return NormalizeDouble(lot, 2);
}

int CountMyTrades()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == MagicNumber)
         c++;
   }
   return c;
}

void ResetAsianRange()
{
   g_asian.high      = 0;
   g_asian.low       = 0;
   g_asian.mid       = 0;
   g_asian.size      = 0;
   g_asian.valid     = false;
   g_asian.highSwept = false;
   g_asian.lowSwept  = false;
   g_asian.sweepDir  = 0;
   g_asian.sweepPrice = 0;
}

void ResetFVGs()
{
   g_fvgCount = 0;
   for(int i = 0; i < 5; i++)
   {
      g_fvg[i].active = false;
   }
}

//──────────────────────────────────────────────
//  VISUALIZATION (Fixed for MT5)
//──────────────────────────────────────────────
void DrawSweepLine(double price, bool isHigh)
{
   string name = isHigh ? "GHOST_SweepHigh" : "GHOST_SweepLow";
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isHigh ? clrOrangeRed : clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

void DrawFVGBox(double bottom, double top, bool isBull, datetime t, int idx)
{
   string name = StringFormat("GHOST_FVG_%d", idx);
   ObjectDelete(0, name);

   datetime t1 = t - PeriodSeconds(PERIOD_M5) * 2;
   datetime t2 = TimeCurrent() + PeriodSeconds(PERIOD_M5) * 30;

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, bottom, t2, top);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBull ? clrLimeGreen : clrTomato);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawDashboard()
{
   MqlDateTime dt;
   TimeGMT(dt);

   string biasStr = (g_h1Bias == +1) ? "BULLISH" : ((g_h1Bias == -1) ? "BEARISH" : "NEUTRAL");
   string sweepStr = g_asian.highSwept ? "HIGH SWEPT" : (g_asian.lowSwept ? "LOW SWEPT" : "Waiting...");
   string fvgStr = (g_fvgCount > 0) ? StringFormat("%d active", g_fvgCount) : "None";
   string kzStr = UseKillzoneFilter ? (IsInKillzone(dt) ? "IN KZ" : "OUT KZ") : "ALL DAY";

   string txt = StringFormat(
      "GHOST V4 SMART  |  %s\n"
      "GMT: %02d:%02d | Mode: %s\n"
      "Asian: %s [%.2f - %.2f]\n"
      "Sweep: %s\n"
      "FVG: %s\n"
      "H1 Bias: %s\n"
      "Trades: %d/%d",
      _Symbol,
      dt.hour, dt.min, kzStr,
      g_asian.valid ? "OK" : "Building",
      g_asian.low, g_asian.high,
      sweepStr,
      fvgStr,
      biasStr,
      CountMyTrades(), MaxTrades
   );

   Comment(txt);
}
//+------------------------------------------------------------------+
