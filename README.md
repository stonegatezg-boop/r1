# XAUUSD Pattern Analysis - Statistical Trading System

## Overview

Comprehensive statistical analysis of **230,400 M15 candlestick data points** for XAUUSD (Gold/USD) spanning **10 years** (2012-2022). The analysis identified statistically significant trading patterns with backtested results, and produced a ready-to-use MT5 Expert Advisor.

**Data Source:** Dukascopy (via ejtraderLabs/historical-data)
**Price Range:** $1,046.23 - $2,074.87
**Total Patterns Tested:** 188 pattern-horizon combinations
**Statistically Significant (p<0.05):** 44 combinations

---

## Key Findings

### XAUUSD Has a Strong Long-Term Bullish Bias

Most SHORT patterns showed **negative expectancy** - meaning gold's natural tendency to appreciate over time overpowers bearish technical signals. The system therefore **favors LONG positions**.

### Top 6 BUY Patterns (Statistically Significant)

| # | Pattern | Win Rate | Profit Factor | Horizon | Occurrences | p-value |
|---|---------|----------|---------------|---------|-------------|---------|
| 1 | MACD Bull Cross + Stoch <30 | **55.6%** | **1.458** | 45min | 331 | 0.027 |
| 2 | London Open + Uptrend + Volume | 47.6% | **1.371** | 15min | 450 | 0.024 |
| 3 | Volume Dryup (Accumulation) | 52.0% | **1.232** | 45min | 12,257 | 0.000 |
| 4 | Volume Spike Bullish | 51.0% | **1.167** | 90min | 7,612 | 0.000 |
| 5 | BB Squeeze Breakout (Bull) | 51.0% | **1.134** | 90min | 3,371 | 0.013 |
| 6 | Stoch Oversold Cross Up | **53.3%** | 1.083 | 15min | 9,152 | 0.023 |

### Top SELL Pattern

| # | Pattern | Win Rate | Profit Factor | Horizon | Occurrences | p-value |
|---|---------|----------|---------------|---------|-------------|---------|
| 1 | London Open + Downtrend + Volume | **53.7%** | **1.552** | 180min | 380 | 0.004 |

### Session Analysis

| Session | Avg Return | Bullish % | Avg Range | Avg Volume |
|---------|-----------|-----------|-----------|------------|
| Asian (00-07 UTC) | +0.0013% | 49.8% | $1.30 | 691 |
| London (07-13 UTC) | -0.0004% | 49.3% | $1.56 | 1,027 |
| New York (13-20 UTC) | -0.0001% | 49.6% | **$2.37** | **1,727** |
| Late NY (20-00 UTC) | -0.0002% | 49.5% | $1.49 | 901 |

**Key insight:** New York session has the highest volatility (range $2.37) and volume (1,727), making it the best session for capturing larger moves.

### Best Trading Hours

| Hour (UTC) | Direction | Return | Bullish % | Range | Volume |
|------------|-----------|--------|-----------|-------|--------|
| 01:00 | Bullish | +0.0055% | 50.4% | $1.13 | 357 |
| 04:00 | Bullish | +0.0019% | 51.3% | $1.62 | 1,004 |
| 08:00 | Bullish | +0.0020% | 51.0% | $1.36 | 815 |
| 15:00 | Bullish | +0.0004% | 49.8% | **$3.10** | 2,073 |
| 17:00 | Bullish | +0.0017% | 51.0% | $2.95 | 2,341 |

### Day of Week

| Day | Avg Return | Bullish % | Range |
|-----|-----------|-----------|-------|
| Monday | -0.0001% | 49.3% | $1.67 |
| Tuesday | -0.0003% | 49.4% | $1.69 |
| Wednesday | 0.0000% | 49.4% | $1.74 |
| Thursday | +0.0003% | 49.6% | $1.77 |
| **Friday** | **+0.0009%** | **50.3%** | $1.76 |

### Monthly Seasonality

| Best Months | Worst Months |
|------------|-------------|
| January (+0.0014%) | November (-0.0015%) |
| August (+0.0010%) | September (-0.0011%) |
| December (+0.0008%) | March (-0.0002%) |

---

## Files

| File | Description |
|------|-------------|
| `XAUUSD_PatternEA.mq5` | MT5 Expert Advisor implementing all winning patterns |
| `xauusd_pattern_analyzer.py` | Python analysis script (full pipeline) |
| `data/xauusd_m15_raw.csv` | Raw M15 data (230,400 candles) |
| `data/pattern_backtest_results.csv` | Full backtest results for all 188 pattern-horizon combos |
| `data/significant_patterns.csv` | Statistically significant patterns only |
| `data/hourly_stats.csv` | Hourly performance statistics |
| `data/daily_stats.csv` | Day-of-week performance statistics |
| `data/session_stats.csv` | Trading session statistics |
| `data/monthly_stats.csv` | Monthly seasonality statistics |
| `data/sr_levels.csv` | Detected support/resistance levels |

---

## EA Installation (MetaTrader 5)

1. Copy `XAUUSD_PatternEA.mq5` to `MT5_DATA\MQL5\Experts\`
2. Open MetaEditor and compile (F7)
3. Attach to XAUUSD M15 chart
4. Enable "Allow Algo Trading"

### EA Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| LotSize | 0.01 | Position size |
| MinSignalScore | 2 | Minimum combined pattern score to enter |
| ATR_SL_Multiplier | 1.0 | Stop Loss = ATR(14) x 1.0 |
| ATR_TP_Multiplier | 1.5 | Take Profit = ATR(14) x 1.5 |
| UseTrailingStop | true | Enable adaptive trailing stop |
| MaxBarsInTrade | 12 | Close after 3 hours if no TP/SL |

### Signal Scoring System

The EA calculates a **combined score** from multiple patterns:

| Signal | Weight | Condition |
|--------|--------|-----------|
| MACD + Stoch Bull | +2 | MACD crosses signal upward + Stoch K < 30 |
| London Trend Bull | +2 | 07:00 UTC + Close > SMA20 + EMA9 > EMA21 + Vol > 1.2x |
| London Trend Bear | -3 | 07:00 UTC + Close < SMA20 + EMA9 < EMA21 + Vol > 1.2x |
| BB Squeeze Bull | +1 | BB width < 20th percentile + Bullish + Range > 1.2 ATR |
| Volume Spike Bull | +1 | Volume > 2x average + Bullish candle |
| Stoch Oversold | +1 | Stoch K crosses D upward below 25 |
| Volume Dryup | +1 | Volume < 30% average (accumulation phase) |

**Trade entry requires minimum score of 2** (configurable).

---

## Trading Rules

### Entry
- Minimum 2 confirming signals required (score >= 2)
- Session filter: London + NY sessions only (default)
- No entry on Friday after 20:00 UTC

### Exit
- **Take Profit:** 1.5x ATR(14) from entry
- **Stop Loss:** 1.0x ATR(14) from entry
- **Trailing Stop:** Starts at 1.0x ATR profit, trails at 0.3x ATR steps
- **Time Exit:** Close after 12 bars (3 hours)
- **Opposite Signal:** Close on opposite signal with score >= 2

### Risk Management
- Max 1 position at a time
- Recommend risking 1-2% of account per trade
- Minimum 1.5:1 reward-to-risk ratio built in

---

## Methodology

1. **Data:** 230,400 M15 candles, 10 years (2012-2022), Dukascopy source
2. **Patterns Detected:** 15 candlestick + 17 technical + 20 combined = 52 unique patterns
3. **Backtesting:** Each pattern tested at 4 time horizons (15min, 45min, 90min, 180min)
4. **Statistical Validation:** Two-tailed t-test, only patterns with p < 0.05 retained
5. **Metrics:** Win rate, profit factor, Sharpe ratio, expectancy per trade

---

## Disclaimer

This analysis is for educational and research purposes. Past statistical patterns do not guarantee future results. Always test on a demo account before live trading. Gold markets can be highly volatile and risky.
