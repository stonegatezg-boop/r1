# Vikas+Stoch EA - MT5 Expert Advisor

**Version:** 1.0
**Created:** 2026-02-02

## Overview

Expert Advisor that reads BUY/SELL signals from the existing **VIKAS SuperTrend** indicator and executes trades automatically.

**Important:** This EA does NOT calculate signals itself. It only reads arrows from your existing VIKAS indicator.

## Files

| File | Description |
|------|-------------|
| `Vikas+Stoch_EA.mq5` | Expert Advisor - reads arrows and executes trades |

## Installation

### Prerequisites
- Your existing **VIKAS SuperTrend** indicator must be installed and attached to the chart
- Indicator must create arrows with names: `VIKAS_BuyArrow_<time>` and `VIKAS_SellArrow_<time>`

### Install EA
1. Copy `Vikas+Stoch_EA.mq5` to: `MT5_DATA_FOLDER\MQL5\Experts\`
2. Compile in MetaEditor (F7)
3. Attach EA to the SAME chart where VIKAS indicator is running
4. Enable "Allow Algo Trading" in MT5

## EA Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Lot Size | 0.01 | Fixed lot size per trade |
| Min Human Delay | 1000 | Minimum delay before entry (ms) |
| Max Human Delay | 3000 | Maximum delay before entry (ms) |
| Min Pip Target | 490 | Min profit target (if candle against) |
| Max Pip Target | 550 | Max profit target (if candle against) |
| Magic Number | 123456 | EA identification number |

## Trading Logic

### Entry Rules
- Timeframe: Any (recommended M5)
- Maximum 1 position at a time
- Entry only after signal bar closes
- Human delay (1-3 seconds) before order

### Exit Rules

**Profit Exit (Candle Matches Signal):**
- If BUY position and candle closes GREEN (bullish) → close after 1-3 sec delay
- If SELL position and candle closes RED (bearish) → close after 1-3 sec delay

**Profit Exit (Candle Against Signal):**
- If candle closes against position direction → wait for 490-550 pip profit

**Stop Loss:**
- Set at open price of previous candle

**Opposite Signal:**
- Immediately closes current position

## Signal Arrow Naming Convention

The indicator creates arrows with these names:
- BUY: `VikasStoch_BUY_<timestamp>`
- SELL: `VikasStoch_SELL_<timestamp>`

The EA reads these arrows to detect signals.

## Important Notes

1. **ALWAYS** attach the indicator FIRST, then the EA
2. EA does NOT calculate signals - it only reads indicator arrows
3. Allow algorithmic trading in MT5 settings
4. Test on demo account before live trading

## Supported Instruments

- Forex pairs (5/3 digit brokers)
- Metals (XAUUSD, XAGUSD)
- Crypto (BTCUSD)
