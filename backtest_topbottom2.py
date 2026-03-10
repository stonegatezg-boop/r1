#!/usr/bin/env python3
"""
TopBottom 2 Backtest (TopBottom_New_Cla)
EMA20 Pullback Engulf + Kalman Hull RSI v3.0
- Improved pullback detection (0.2% tolerance)
- TimeFailure 6 bars / 50 pips
- Dynamic SL based on swing
"""

import pandas as pd
import numpy as np
from datetime import datetime

# Parameters from TopBottom_New_Cla.mq5
EMA_FAST = 10
EMA_SLOW = 20
PULLBACK_CANDLES = 5  # Increased from 3
PULLBACK_TOLERANCE = 0.002  # 0.2%

# Targets in pips
TARGET1_PIPS = 300
TARGET2_PIPS = 500
TARGET3_PIPS = 800
SL_PIPS = 300

# Dynamic SL
USE_DYNAMIC_SL = True
SWING_LOOKBACK = 10
SL_BUFFER_PIPS = 30
SL_MIN_MULT = 0.5  # Min SL = SL_PIPS * 0.5
SL_MAX_MULT = 2.0  # Max SL = SL_PIPS * 2.0

# Trailing
TRAIL_L1_PIPS = 500
TRAIL_L1_BE = 40
TRAIL_L2_PIPS = 800
TRAIL_L2_LOCK = 150
TRAIL_L3_PIPS = 1200
TRAIL_L3_LOCK = 200
MFE_ACTIVATE = 1500
MFE_TRAIL = 500

# Failure exits - RELAXED
EARLY_FAILURE_PIPS = 800
TIME_FAILURE_BARS = 6   # Increased from 3
TIME_FAILURE_MIN_PIPS = 50  # Increased from 20

# KHRSI levels
KHRSI_BUY_LEVEL = 45   # Was 50
KHRSI_SELL_LEVEL = 55  # Was 50

PIP_VALUE = 0.01  # XAUUSD: 1 pip = 0.01

def load_data(filepath):
    df = pd.read_csv(filepath)
    df['datetime'] = pd.to_datetime(df['day'] + ' ' + df['time'])
    df = df.sort_values('datetime').reset_index(drop=True)
    return df

def backtest(df):
    trades = []
    position = None

    # Precompute EMAs
    df['ema10'] = df['close'].ewm(span=EMA_FAST, adjust=False).mean()
    df['ema20'] = df['close'].ewm(span=EMA_SLOW, adjust=False).mean()

    # Kalman Hull RSI approximation
    # Using simple RSI on smoothed price as approximation
    # Kalman smoothing
    kf_state = df['close'].iloc[0]
    kf_cov = 1.0
    noise = 3.0
    process = 0.01
    kalman_vals = []

    for price in df['close']:
        pred_cov = kf_cov + process
        gain = pred_cov / (pred_cov + noise)
        kf_state = kf_state + gain * (price - kf_state)
        kf_cov = (1 - gain) * pred_cov
        kalman_vals.append(kf_state)

    df['kalman'] = kalman_vals

    # RSI on Kalman smoothed values
    delta = df['kalman'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=12).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=12).mean()
    rs = gain / loss
    df['khrsi'] = 100 - (100 / (1 + rs))
    df['khrsi'] = df['khrsi'].fillna(50)

    # Daily VWAP
    df['date'] = df['datetime'].dt.date
    df['typical'] = (df['high'] + df['low'] + df['close']) / 3
    df['vol'] = df['volume'].replace(0, 1)
    df['pv'] = df['typical'] * df['vol']
    df['cum_pv'] = df.groupby('date')['pv'].cumsum()
    df['cum_vol'] = df.groupby('date')['vol'].cumsum()
    df['vwap'] = df['cum_pv'] / df['cum_vol']

    # Candle properties
    df['is_green'] = df['close'] > df['open']
    df['is_red'] = df['close'] < df['open']
    df['body'] = abs(df['close'] - df['open'])
    df['range'] = df['high'] - df['low']

    print("Indicators calculated. Running signals...")

    total_bars = len(df)

    for idx in range(50, total_bars):
        if idx % 50000 == 0:
            print(f"  Progress: {idx:,} / {total_bars:,}")

        row = df.iloc[idx]
        prev = df.iloc[idx - 1]
        prev2 = df.iloc[idx - 2]

        # Manage position
        if position is not None:
            current_price = row['close']
            if position['type'] == 'BUY':
                profit_pips = (current_price - position['entry']) / PIP_VALUE
            else:
                profit_pips = (position['entry'] - current_price) / PIP_VALUE

            position['bars'] += 1
            if profit_pips > position['mfe']:
                position['mfe'] = profit_pips

            exit_reason = None
            dynamic_sl = position['sl_pips']

            # Check exits
            if profit_pips <= -dynamic_sl:
                exit_reason = "SL HIT"
            elif profit_pips <= -EARLY_FAILURE_PIPS:
                exit_reason = "EARLY FAILURE"
            elif position['bars'] >= TIME_FAILURE_BARS and profit_pips < TIME_FAILURE_MIN_PIPS and profit_pips > -EARLY_FAILURE_PIPS/2:
                exit_reason = "TIME EXIT"
            elif profit_pips >= TARGET3_PIPS:
                exit_reason = "TARGET 3"
            elif position['trail_level'] >= 3 and profit_pips < TRAIL_L3_LOCK:
                exit_reason = "TRAIL L3 STOP"
            elif position['trail_level'] == 2 and profit_pips < TRAIL_L2_LOCK:
                exit_reason = "TRAIL L2 STOP"
            elif position['trail_level'] == 1 and profit_pips < TRAIL_L1_BE:
                exit_reason = "TRAIL L1 STOP"
            elif position['mfe'] >= MFE_ACTIVATE and profit_pips < (position['mfe'] - MFE_TRAIL):
                exit_reason = "MFE TRAIL"

            # Update trail levels
            if profit_pips >= TRAIL_L3_PIPS:
                position['trail_level'] = 3
            elif profit_pips >= TRAIL_L2_PIPS:
                position['trail_level'] = max(position['trail_level'], 2)
            elif profit_pips >= TRAIL_L1_PIPS:
                position['trail_level'] = max(position['trail_level'], 1)

            if exit_reason:
                trades.append({
                    'entry_time': position['entry_time'],
                    'exit_time': row['datetime'],
                    'type': position['type'],
                    'entry': position['entry'],
                    'exit': current_price,
                    'pips': round(profit_pips, 1),
                    'mfe': round(position['mfe'], 1),
                    'bars': position['bars'],
                    'sl_pips': position['sl_pips'],
                    'exit_reason': exit_reason
                })
                position = None
                continue

        # Check signals (no position)
        if position is None:
            ema10 = prev['ema10']
            ema20 = prev['ema20']
            prev_ema20 = prev2['ema20']
            close = prev['close']
            vwap = prev['vwap']
            khrsi = prev['khrsi']

            # Trend filters
            bull_trend = close > vwap and ema10 > ema20 and ema20 >= prev_ema20
            bear_trend = close < vwap and ema10 < ema20 and ema20 <= prev_ema20

            if not bull_trend and not bear_trend:
                continue

            # Check pullback with tolerance
            bull_pullback = False
            bear_pullback = False
            tol = ema20 * PULLBACK_TOLERANCE

            for i in range(1, min(PULLBACK_CANDLES + 1, idx)):
                pb_row = df.iloc[idx - 1 - i]
                pb_low = pb_row['low']
                pb_high = pb_row['high']
                pb_open = pb_row['open']
                pb_close = pb_row['close']

                if bull_trend:
                    # Red candle near EMA20
                    if pb_row['is_red']:
                        near_ema = (pb_low <= ema20 + tol and pb_low >= ema20 - tol)
                        crosses_ema = (min(pb_open, pb_close) <= ema20 and max(pb_open, pb_close) >= ema20)
                        if near_ema or crosses_ema:
                            bull_pullback = True
                            break
                else:
                    # Green candle near EMA20
                    if pb_row['is_green']:
                        near_ema = (pb_high >= ema20 - tol and pb_high <= ema20 + tol)
                        crosses_ema = (min(pb_open, pb_close) <= ema20 and max(pb_open, pb_close) >= ema20)
                        if near_ema or crosses_ema:
                            bear_pullback = True
                            break

            # Check engulfing or strong candle
            o1, c1 = prev['open'], prev['close']
            o2, c2 = prev2['open'], prev2['close']
            body_ratio = prev['body'] / prev['range'] if prev['range'] > 0 else 0

            bull_engulf = prev['is_green'] and (
                (c1 > max(o2, c2) and o1 < min(o2, c2)) or  # Classic engulf
                (c1 > ema20 and body_ratio > 0.6)  # Strong candle
            )
            bear_engulf = prev['is_red'] and (
                (c1 < min(o2, c2) and o1 > max(o2, c2)) or  # Classic engulf
                (c1 < ema20 and body_ratio > 0.6)  # Strong candle
            )

            # KHRSI with new levels
            khrsi_up = khrsi > KHRSI_BUY_LEVEL
            khrsi_down = khrsi < KHRSI_SELL_LEVEL

            # Calculate dynamic SL
            if USE_DYNAMIC_SL:
                if bull_trend:
                    swing_low = min(df.iloc[idx-SWING_LOOKBACK:idx]['low'])
                    sl_dist = (row['open'] - swing_low) / PIP_VALUE + SL_BUFFER_PIPS
                else:
                    swing_high = max(df.iloc[idx-SWING_LOOKBACK:idx]['high'])
                    sl_dist = (swing_high - row['open']) / PIP_VALUE + SL_BUFFER_PIPS

                dynamic_sl = max(SL_PIPS * SL_MIN_MULT, min(SL_PIPS * SL_MAX_MULT, sl_dist))
            else:
                dynamic_sl = SL_PIPS

            # BUY signal
            if bull_trend and bull_pullback and bull_engulf and khrsi_up:
                position = {
                    'type': 'BUY',
                    'entry': row['open'],
                    'entry_time': row['datetime'],
                    'bars': 0,
                    'trail_level': 0,
                    'mfe': 0,
                    'sl_pips': round(dynamic_sl, 1)
                }
            # SELL signal
            elif bear_trend and bear_pullback and bear_engulf and khrsi_down:
                position = {
                    'type': 'SELL',
                    'entry': row['open'],
                    'entry_time': row['datetime'],
                    'bars': 0,
                    'trail_level': 0,
                    'mfe': 0,
                    'sl_pips': round(dynamic_sl, 1)
                }

    return trades

def main():
    print("=" * 80)
    print("TOPBOTTOM 2 BACKTEST (TopBottom_New_Cla v3.0)")
    print("EMA20 Pullback Engulf + Kalman Hull RSI | XAUUSD M5")
    print("=" * 80)
    print(f"Pullback candles: {PULLBACK_CANDLES} | Tolerance: {PULLBACK_TOLERANCE*100:.1f}%")
    print(f"Time failure: {TIME_FAILURE_BARS} bars / {TIME_FAILURE_MIN_PIPS} pips")
    print(f"KHRSI levels: Buy > {KHRSI_BUY_LEVEL} | Sell < {KHRSI_SELL_LEVEL}")
    print(f"Dynamic SL: {USE_DYNAMIC_SL} | Range: {SL_PIPS*SL_MIN_MULT:.0f}-{SL_PIPS*SL_MAX_MULT:.0f} pips")
    print("=" * 80)

    df = load_data('/home/user/r1/xauusd_m5_3y.csv')
    print(f"\nData: {df.iloc[0]['datetime']} to {df.iloc[-1]['datetime']}")
    print(f"Total bars: {len(df):,}")

    print("\nRunning backtest...")
    trades = backtest(df)

    if not trades:
        print("No trades found!")
        return

    # Statistics
    total = len(trades)
    winners = [t for t in trades if t['pips'] > 0]
    losers = [t for t in trades if t['pips'] <= 0]
    win_rate = len(winners) / total * 100 if total > 0 else 0

    total_pips = sum(t['pips'] for t in trades)
    avg_win = np.mean([t['pips'] for t in winners]) if winners else 0
    avg_loss = np.mean([t['pips'] for t in losers]) if losers else 0

    # Exit reason breakdown
    exit_reasons = {}
    for t in trades:
        reason = t['exit_reason']
        if reason not in exit_reasons:
            exit_reasons[reason] = {'count': 0, 'pips': 0, 'winners': 0}
        exit_reasons[reason]['count'] += 1
        exit_reasons[reason]['pips'] += t['pips']
        if t['pips'] > 0:
            exit_reasons[reason]['winners'] += 1

    print("\n" + "=" * 80)
    print("REZULTATI IZLAZA (EXIT RESULTS)")
    print("=" * 80)

    print(f"\nUkupno trejdova: {total}")
    print(f"Pobjednici: {len(winners)} ({win_rate:.1f}%)")
    print(f"Gubitnici: {len(losers)} ({100-win_rate:.1f}%)")
    print(f"\nUkupno pips: {total_pips:.1f}")
    print(f"Prosjecni dobitak: +{avg_win:.1f} pips")
    print(f"Prosjecni gubitak: {avg_loss:.1f} pips")

    print("\n" + "-" * 80)
    print("ANALIZA PO IZLAZNOM RAZLOGU:")
    print("-" * 80)
    print(f"{'Razlog':<20} {'Broj':>8} {'Pips':>12} {'Win%':>8} {'Avg Pips':>10}")
    print("-" * 80)

    for reason, data in sorted(exit_reasons.items(), key=lambda x: -x[1]['count']):
        count = data['count']
        pips = data['pips']
        win_pct = data['winners'] / count * 100 if count > 0 else 0
        avg = pips / count if count > 0 else 0
        print(f"{reason:<20} {count:>8} {pips:>+12.1f} {win_pct:>7.1f}% {avg:>+10.1f}")

    # Dynamic SL analysis
    print("\n" + "-" * 80)
    print("DYNAMIC SL ANALIZA:")
    print("-" * 80)
    sl_values = [t['sl_pips'] for t in trades]
    print(f"Min SL: {min(sl_values):.1f} pips | Max SL: {max(sl_values):.1f} pips | Avg: {np.mean(sl_values):.1f} pips")

    # MFE Analysis
    print("\n" + "-" * 80)
    print("MFE ANALIZA (Maximum Favorable Excursion):")
    print("-" * 80)

    mfe_ranges = [(0, 100), (100, 300), (300, 500), (500, 800), (800, 1500), (1500, 9999)]
    for low, high in mfe_ranges:
        range_trades = [t for t in trades if low <= t['mfe'] < high]
        if range_trades:
            range_winners = [t for t in range_trades if t['pips'] > 0]
            range_pips = sum(t['pips'] for t in range_trades)
            label = f"MFE {low}-{high if high < 9999 else '+'}"
            print(f"{label:<15} Trades: {len(range_trades):>4} | Win: {len(range_winners)/len(range_trades)*100:>5.1f}% | Total: {range_pips:>+8.1f} pips")

    # Winners vs Losers comparison
    print("\n" + "-" * 80)
    print("WINNERS vs LOSERS:")
    print("-" * 80)

    if winners:
        win_mfe_avg = np.mean([t['mfe'] for t in winners])
        win_bars_avg = np.mean([t['bars'] for t in winners])
        print(f"Winners avg MFE: {win_mfe_avg:+.1f} pips | Avg duration: {win_bars_avg:.1f} bars")

    if losers:
        loss_mfe_avg = np.mean([t['mfe'] for t in losers])
        loss_bars_avg = np.mean([t['bars'] for t in losers])
        print(f"Losers avg MFE: {loss_mfe_avg:+.1f} pips | Avg duration: {loss_bars_avg:.1f} bars")

    # Type analysis
    buys = [t for t in trades if t['type'] == 'BUY']
    sells = [t for t in trades if t['type'] == 'SELL']

    print("\n" + "-" * 80)
    print("BUY vs SELL:")
    print("-" * 80)
    if buys:
        buy_wins = [t for t in buys if t['pips'] > 0]
        buy_pips = sum(t['pips'] for t in buys)
        print(f"BUY:  {len(buys):>4} trades | Win: {len(buy_wins)/len(buys)*100:>5.1f}% | Total: {buy_pips:>+8.1f} pips")
    if sells:
        sell_wins = [t for t in sells if t['pips'] > 0]
        sell_pips = sum(t['pips'] for t in sells)
        print(f"SELL: {len(sells):>4} trades | Win: {len(sell_wins)/len(sells)*100:>5.1f}% | Total: {sell_pips:>+8.1f} pips")

    # Last 20 trades detail
    print("\n" + "-" * 80)
    print("ZADNJIH 20 TREJDOVA:")
    print("-" * 80)
    print(f"{'Datum':<20} {'Tip':<5} {'Entry':>10} {'Exit':>10} {'Pips':>8} {'MFE':>8} {'SL':>6} {'Izlaz'}")
    print("-" * 80)

    for t in trades[-20:]:
        entry_date = t['entry_time'].strftime('%Y-%m-%d %H:%M')
        print(f"{entry_date:<20} {t['type']:<5} {t['entry']:>10.2f} {t['exit']:>10.2f} {t['pips']:>+8.1f} {t['mfe']:>+8.1f} {t['sl_pips']:>6.0f} {t['exit_reason']}")

    # Save all trades
    trades_df = pd.DataFrame(trades)
    trades_df.to_csv('/home/user/r1/topbottom2_backtest_results.csv', index=False)
    print(f"\nSvi trejdovi spremljeni u: topbottom2_backtest_results.csv")

if __name__ == '__main__':
    main()
