# PROMPT - MFE Risk Logic (PIP BASED)

**Koristi ovaj prompt za implementaciju nove risk logike na bilo koji EA.**

---

## PROMPT:

```
Modify my MQL5 Expert Advisor.

IMPORTANT:
- Do NOT change entry logic.
- Do NOT change Take Profit logic.
- Modify ONLY Stop Loss and Trailing logic.
- All calculations must be PIP-BASED (not USD).

Instrument: XAUUSD
1 pip = 0.1 (10 points)


## 1. REMOVE OLD LOGIC

Completely remove:
- Any Break Even logic
- Any BE offset logic
- Any existing trailing stop logic
- Old SL calculation (ATR-based, percentage, etc.)

Do not leave unused variables.


## 2. NEW HARD STOP LOSS

Implement fixed hard SL:
**800 pips**

Rules:
- Calculate profit in pips using price distance
- If floating loss reaches -800 pips: Close position immediately
- Must work for both BUY and SELL
- STEALTH: Do NOT send SL to broker - monitor internally


## 3. TRAILING ACTIVATION

Trailing activates ONLY when profit reaches:
**1000 pips**

Before 1000 pips profit:
- Do NOT modify SL
- Do NOT move to break even
- Just let the trade run with Hard SL protection


## 4. TRAILING RULE (MFE TRACKING)

After profit reaches 1000 pips:

Track MFE (Maximum Favorable Excursion) - the highest profit reached.

Trailing distance: **500 pips**

Calculate locked profit:
new_locked_pips = MFE - 500 pips

Convert to price:
- BUY: SL_price = entry_price + locked_pips * point
- SELL: SL_price = entry_price - locked_pips * point

Rules:
- SL must only move FORWARD (in profit direction)
- SL must NEVER move backward
- Update continuously when new MFE highs are made
- If price reverses 500 pips from MFE: Close position


## 5. IMPLEMENTATION REQUIREMENTS

Structure needed per position:
- ticket (ulong)
- entryPrice (double)
- maxProfit (double) - MFE in pips
- trailActive (bool)
- lockedProfitPrice (double) - current trailing SL price

Must:
- Track MFE per position independently
- Reset MFE when new trade opens
- Use price distance for pip calculation
- Work for both BUY and SELL
- Be clean and production-ready
- No redundant calculations


## 6. EDGE CASES

- If TP is hit before trailing activation: Close normally (TP takes priority)
- If Hard SL (-800 pips) is hit before trailing: Close immediately
- Trailing must not interfere with TP
- SL must not jump backward even if MFE calculation changes


## 7. EXAMPLE FLOW

Trade opens at 2000.00 (BUY):
- Price goes to 2005.00 (+500 pips): Nothing happens, Hard SL active at 1992.00
- Price goes to 2010.00 (+1000 pips): TRAIL ACTIVATED, MFE=1000, Lock=500, SL at 2005.00
- Price goes to 2012.00 (+1200 pips): MFE=1200, Lock=700, SL moves to 2007.00
- Price goes to 2015.00 (+1500 pips): MFE=1500, Lock=1000, SL moves to 2010.00
- Price drops to 2010.00: TRAIL SL HIT, Close with +1000 pips profit


Return the complete modified EA code with clear comments.
```

---

## PARAMETRI (input variables):

```cpp
input group "=== RISK MANAGEMENT (PIPS) ==="
input int      HardSL_Pips           = 800;    // Hard Stop Loss
input int      TrailActivation_Pips  = 1000;   // Trailing aktivacija
input int      TrailDistance_Pips    = 500;    // Trailing udaljenost
input double   FixedLotSize          = 0.01;   // Fiksni lot size
```

---

## KONVERZIJA USD <-> PIPS (za XAUUSD, 0.01 lot):

| PIPS | USD |
|------|-----|
| 100  | 1   |
| 500  | 5   |
| 800  | 8   |
| 1000 | 10  |

---

## STARA LOGIKA (NE KORISTI VISE):

~~2-Level Trailing Stop~~
~~- Level 1: Na 500 pips profita → pomakni SL na BE + 38-43 pips~~
~~- Level 2: Na 800 pips profita → zaključaj 150-200 pips profita~~

**NOVA LOGIKA:**
- Hard SL: -800 pips (fiksno)
- Trail aktivacija: +1000 pips
- Trail udaljenost: 500 pips (MFE - 500)
- Kontinuirano praćenje MFE

---

## TEMPLATE FILE:

Vidi: `TEMPLATE_RiskLogic.mq5` za čistu implementaciju samo risk logike.

---

*Created: 03.03.2026*
