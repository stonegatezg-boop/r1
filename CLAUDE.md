# MQL5 EA Development Standards

## Stealth Execution (OBAVEZNO za sve EA)
- **Stealth TP**: NIKAD ne šalji TP brokeru, zatvori trejd kad cijena dotakne target
- **PRAVI SL ODMAH**: SL se postavlja ODMAH pri otvaranju trejda (NE s odgodom!)
- **Razlog za pravi SL**: Ako se EA restarta ili MT5 crashira, SL ostaje na brokeru i štiti poziciju
- **Backup provjera**: EA dodatno provjerava je li SL postavljen i postavlja ga ako nije

### KRITIČNI FIX (03.03.2026)
**Problem**: Stealth SL s odgodom 7-13 sekundi može failirati ako:
- PositionModify() vrati false (server odbije)
- EA se restarta prije postavljanja SL
- MT5 crashira ili izgubi konekciju

**Rješenje**: SL se postavlja ODMAH kod `trade.Buy()` / `trade.Sell()`:
```cpp
// ISPRAVNO (v2.2+):
trade.Buy(lot, _Symbol, price, sl, 0, "EA_NAME");  // SL odmah, TP=0 (stealth)

// POGREŠNO (staro):
trade.Buy(lot, _Symbol, price, 0, 0, "EA_NAME");   // SL=0, postavlja se kasnije
```

### Ažurirani CALF EA (03.03.2026 22:30 Zagreb)
| EA | Verzija | SL Status |
|----|---------|-----------|
| CALF_A_UTBot | v2.2 | PRAVI SL ODMAH |
| CALF_A_M | v2.2 | PRAVI SL ODMAH (800 pips) |
| CALF_B_EMA | v2.3 | PRAVI SL ODMAH (800 pips) |
| CALF_C_Supertrend | v3.1 | PRAVI SL ODMAH (800 pips) |
| CALF_D_RSI | v2.2 | PRAVI SL ODMAH |
| CALF_E_Breakout | v3.1 | PRAVI SL ODMAH (800 pips) |
| Calf_A_Pro | v2.2 | PRAVI SL ODMAH |

## 3 Target System
- **Target 1**: Zatvori 33% pozicije
- **Target 2**: Zatvori 50% preostalog
- **Target 3**: Zatvori ostatak (trailing ili fiksni)

## 2-Level Trailing Stop
- **Level 1**: Na 500 pips profita → pomakni SL na BE + 38-43 pips
- **Level 2**: Na 800 pips profita → zaključaj 150-200 pips profita

## Filteri (standardni)
- **Spread Filter**: MaxSpread input (tipično 50-80 za XAUUSD)
- **News Filter**: Izbjegavaj trading oko vijesti
- **Large Candle Filter**: Preskoči ako je candle prevelik (ATR multiple)

## Trading Window
- **Start**: Nedjelja 00:01 (server time)
- **End**: Petak 11:30 (server time)
- **Intraday**: NEMA restrikcija (trejdaj cijeli dan)

## Magic Numbers (aktivni EA)
| EA | Magic | Timeframe | Instrument |
|----|-------|-----------|------------|
| ULTRACLA_V1 | 999999 | M5 | XAUUSD |
| AbsorptionScalper_Cla | 778899 | M5 | XAUUSD |
| Vikas_SQZMOM_Cla | 123456 | M5 | XAUUSD |
| Vikas_SQZMOM_15_Cla | 445567 | M15 | XAUUSD |
| RSI_MomDiv_Cla | 889900 | M5 | XAUUSD |
| Mix1_ADX_Cla | 261450 | M5 | XAUUSD |
| SupplyDemand_GMACD_Cla | 556677 | M5 | XAUUSD |
| SwingFree_MACDL_Cla | 667788 | M5 | XAUUSD |
| TopBottom_KHRSI_Cla | 778800 | M5 | XAUUSD |

## Standardni Inputi
```cpp
// Risk Management
input double LotSize = 0.01;
input double MaxSpread = 50;

// Targets (u PIPS, ne points)
input int Target1_Pips = 300;
input int Target2_Pips = 500;
input int Target3_Pips = 800;

// Trailing
input int TrailingStart1 = 500;  // pips za BE
input int TrailingStart2 = 800;  // pips za lock profit
```

## Verzioniranje (OBAVEZNO)
- **Novi EA**: Dodaj datum i vrijeme kreiranja u header (Zagreb time)
- **Ispravke**: Dodaj datum i vrijeme ispravke u header
- **Format**: `// Created: DD.MM.YYYY HH:MM (Zagreb)` ili `// Fixed: DD.MM.YYYY HH:MM (Zagreb)`

```cpp
//+------------------------------------------------------------------+
//|                                                    IME_EA.mq5     |
//|                   Created: 26.02.2026 15:30 (Zagreb)              |
//|                   Fixed: 26.02.2026 16:45 (Zagreb) - opis fix    |
//+------------------------------------------------------------------+
```

## Napomene
- Svi EA su za XAUUSD osim ako nije drugačije specificirano
- **1 pip XAUUSD = 0.01** (100 points = 1 pip, cijena format xxxx.xx)
- Uvijek koristi MagicNumber za identifikaciju svojih trejdova

## XAUUSD Pip Kalkulacija (KRITIČNO!)
```cpp
// ISPRAVNO za XAUUSD:
double pipValue = 0.01;  // 1 pip = 0.01
double sl_distance = SL_Pips * pipValue;  // 800 pips = 8.00

// POGREŠNO (staro):
double pipValue = 0.1;   // OVO JE 10x PREVELIKO!
// 800 pips * 0.1 = 80.00 (zapravo 8000 pipsa!)
```

**Primjer:**
- Cijena: 2650.00
- SL 800 pips = 2650.00 - 8.00 = 2642.00 ✅
- SL 800 pips s greškom (0.1) = 2650.00 - 80.00 = 2570.00 ❌ (8000 pipsa!)
