# MQL5 EA Development Standards

## Stealth Execution (OBAVEZNO za sve EA)
- **Stealth TP**: NIKAD ne šalji TP brokeru, zatvori trejd kad cijena dotakne target
- **Stealth SL**: Pošalji SL brokeru s odgodom 7-13 sekundi (random)
- **Razlog**: Broker ne vidi naše nivoe unaprijed

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

## Napomene
- Svi EA su za XAUUSD osim ako nije drugačije specificirano
- 1 pip XAUUSD = 0.1 (100 points = 10 pips)
- Uvijek koristi MagicNumber za identifikaciju svojih trejdova
