#!/usr/bin/env python3
"""
Mix1_ADX_Cla Backtest
Strategy: EMA26/50 Cross + SMA200 Trend + ATR Channel + ADX/DI
"""
import pandas as pd
import numpy as np
from datetime import datetime, timedelta

# Parameters (from EA)
EMA_FAST = 26
EMA_MEDIUM = 50
MA_TREND = 200
CHANNEL_ATR_MULT = 0.618
ADX_PERIOD = 14
ADX_THRESHOLD = 22
DI_BUFFER = 10.0  # %

# Targets (ATR multiples)
TARGET1_ATR = 1.5
TARGET2_ATR = 2.5
TARGET3_ATR = 3.5
CLOSE_PERCENT1 = 33
CLOSE_PERCENT2 = 50

# SL
SL_MIN = 988  # pips
SL_MAX = 1054
PIP_VALUE = 0.01  # XAUUSD

# Trailing
TRAILING_START_BE = 1000  # pips
BE_OFFSET_MIN = 41
BE_OFFSET_MAX = 46
TRAILING_DISTANCE = 1000


def load_data(filepath):
    df = pd.read_csv(filepath)
    df['datetime'] = pd.to_datetime(df['day'] + ' ' + df['time'])
    df = df.sort_values('datetime').reset_index(drop=True)
    return df


def calc_ema(series, period):
    return series.ewm(span=period, adjust=False).mean()


def calc_sma(series, period):
    return series.rolling(window=period).mean()


def calc_atr(df, period=14):
    high = df['high']
    low = df['low']
    close = df['close']

    tr1 = high - low
    tr2 = abs(high - close.shift(1))
    tr3 = abs(low - close.shift(1))
    tr = pd.concat([tr1, tr2, tr3], axis=1).max(axis=1)

    return tr.rolling(window=period).mean()


def calc_adx_di(df, period=14):
    """Calculate ADX, DI+, DI-"""
    high = df['high'].values
    low = df['low'].values
    close = df['close'].values
    n = len(df)

    plus_dm = np.zeros(n)
    minus_dm = np.zeros(n)
    tr = np.zeros(n)

    for i in range(1, n):
        up_move = high[i] - high[i-1]
        down_move = low[i-1] - low[i]

        if up_move > down_move and up_move > 0:
            plus_dm[i] = up_move
        else:
            plus_dm[i] = 0

        if down_move > up_move and down_move > 0:
            minus_dm[i] = down_move
        else:
            minus_dm[i] = 0

        tr[i] = max(high[i] - low[i],
                   abs(high[i] - close[i-1]),
                   abs(low[i] - close[i-1]))

    # Smoothed averages
    atr = pd.Series(tr).rolling(window=period).mean().values
    plus_dm_smooth = pd.Series(plus_dm).rolling(window=period).mean().values
    minus_dm_smooth = pd.Series(minus_dm).rolling(window=period).mean().values

    # DI+ and DI-
    plus_di = np.zeros(n)
    minus_di = np.zeros(n)
    dx = np.zeros(n)

    for i in range(period, n):
        if atr[i] > 0:
            plus_di[i] = 100 * plus_dm_smooth[i] / atr[i]
            minus_di[i] = 100 * minus_dm_smooth[i] / atr[i]

        di_sum = plus_di[i] + minus_di[i]
        if di_sum > 0:
            dx[i] = 100 * abs(plus_di[i] - minus_di[i]) / di_sum

    adx = pd.Series(dx).rolling(window=period).mean().values

    return adx, plus_di, minus_di


def get_trend_direction(df, i, ema_fast, ema_med, ma_trend, atr):
    """
    Returns: 1 (bullish), -1 (bearish), 0 (neutral/in channel)
    """
    if i < MA_TREND or pd.isna(ema_fast[i]) or pd.isna(ema_med[i]) or pd.isna(ma_trend[i]) or pd.isna(atr[i]) or atr[i] <= 0:
        return 0

    close_price = df['close'].iloc[i]
    open_price = df['open'].iloc[i]

    # MA Direction
    ma_dir = 1 if ema_fast[i] > ema_med[i] else -1

    # Trend Direction
    ma_trend_dir = 1 if close_price >= ma_trend[i] else -1

    # Channel
    range_top = ma_trend[i] + atr[i] * CHANNEL_ATR_MULT
    range_bot = ma_trend[i] - atr[i] * CHANNEL_ATR_MULT

    # In channel check
    in_channel = ((open_price <= range_top or close_price <= range_top) and
                  (open_price >= range_bot or close_price >= range_bot))

    if in_channel:
        return 0

    if ma_trend_dir == 1 and ma_dir == 1:
        return 1

    if ma_trend_dir == -1 and ma_dir == -1:
        return -1

    return 0


def get_adx_di_signal(adx, di_plus, di_minus, i):
    """
    Returns: 1 (bullish), -1 (bearish), 0 (neutral)
    """
    if i < ADX_PERIOD * 2 or adx[i] <= 0:
        return 0

    buffer_plus = di_plus[i] * DI_BUFFER / 100.0
    buffer_minus = di_minus[i] * DI_BUFFER / 100.0

    bullish = di_plus[i] > (di_minus[i] + buffer_plus)
    bearish = di_minus[i] > (di_plus[i] + buffer_minus)

    # Strong signal (ADX > threshold)
    if bullish and adx[i] > ADX_THRESHOLD:
        return 1
    if bearish and adx[i] > ADX_THRESHOLD:
        return -1

    # Weak signal (ADX > 11)
    if bullish and adx[i] > 11:
        return 1
    if bearish and adx[i] > 11:
        return -1

    return 0


def is_trading_window(dt):
    """Check if in trading window"""
    # Skip weekends
    if dt.weekday() == 5:  # Saturday
        return False
    if dt.weekday() == 6:  # Sunday
        if dt.hour == 0 and dt.minute < 1:
            return False

    # Friday close at 11:00
    if dt.weekday() == 4 and dt.hour >= 11:
        return False

    return True


def backtest(df):
    results = []

    # Calculate indicators
    ema_fast = calc_ema(df['close'], EMA_FAST)
    ema_med = calc_ema(df['close'], EMA_MEDIUM)
    ma_trend = calc_sma(df['close'], MA_TREND)
    atr = calc_atr(df, 14)
    adx, di_plus, di_minus = calc_adx_di(df, ADX_PERIOD)

    position = None
    prev_trend_dir = 0

    np.random.seed(42)  # For reproducibility

    for i in range(MA_TREND + 1, len(df)):
        current_time = df['datetime'].iloc[i]

        # Check position exits first
        if position is not None:
            high = df['high'].iloc[i]
            low = df['low'].iloc[i]
            close_price = df['close'].iloc[i]
            position['bars'] += 1

            if position['type'] == 'BUY':
                current_profit_pips = (high - position['entry']) / PIP_VALUE
                position['mfe'] = max(position['mfe'], current_profit_pips)

                # Check SL
                if low <= position['sl']:
                    pips = (position['sl'] - position['entry']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'BUY',
                        'entry': position['entry'],
                        'exit': position['sl'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': 'SL HIT'
                    })
                    position = None
                    continue

                # Check Trailing/BE+
                profit_pips = (close_price - position['entry']) / PIP_VALUE
                if profit_pips >= TRAILING_START_BE and not position['be_activated']:
                    # Activate BE+
                    position['be_activated'] = True
                    be_offset = np.random.randint(BE_OFFSET_MIN, BE_OFFSET_MAX + 1)
                    position['sl'] = position['entry'] + be_offset * PIP_VALUE

                if position['be_activated']:
                    # Trailing
                    new_sl = high - TRAILING_DISTANCE * PIP_VALUE
                    if new_sl > position['sl']:
                        position['sl'] = new_sl

                # Check Targets (stealth)
                if position['target_hit'] == 0 and high >= position['tp1']:
                    position['target_hit'] = 1
                if position['target_hit'] == 1 and high >= position['tp2']:
                    position['target_hit'] = 2
                if high >= position['tp3']:
                    pips = (position['tp3'] - position['entry']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'BUY',
                        'entry': position['entry'],
                        'exit': position['tp3'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': 'TARGET 3'
                    })
                    position = None
                    continue

                # Trailing stop hit
                if position['be_activated'] and low <= position['sl']:
                    pips = (position['sl'] - position['entry']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'BUY',
                        'entry': position['entry'],
                        'exit': position['sl'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': f'TRAIL STOP'
                    })
                    position = None
                    continue

            else:  # SELL
                current_profit_pips = (position['entry'] - low) / PIP_VALUE
                position['mfe'] = max(position['mfe'], current_profit_pips)

                # Check SL
                if high >= position['sl']:
                    pips = (position['entry'] - position['sl']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'SELL',
                        'entry': position['entry'],
                        'exit': position['sl'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': 'SL HIT'
                    })
                    position = None
                    continue

                # Check Trailing/BE+
                profit_pips = (position['entry'] - close_price) / PIP_VALUE
                if profit_pips >= TRAILING_START_BE and not position['be_activated']:
                    position['be_activated'] = True
                    be_offset = np.random.randint(BE_OFFSET_MIN, BE_OFFSET_MAX + 1)
                    position['sl'] = position['entry'] - be_offset * PIP_VALUE

                if position['be_activated']:
                    new_sl = low + TRAILING_DISTANCE * PIP_VALUE
                    if new_sl < position['sl']:
                        position['sl'] = new_sl

                # Check Targets
                if position['target_hit'] == 0 and low <= position['tp1']:
                    position['target_hit'] = 1
                if position['target_hit'] == 1 and low <= position['tp2']:
                    position['target_hit'] = 2
                if low <= position['tp3']:
                    pips = (position['entry'] - position['tp3']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'SELL',
                        'entry': position['entry'],
                        'exit': position['tp3'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': 'TARGET 3'
                    })
                    position = None
                    continue

                # Trailing stop hit
                if position['be_activated'] and high >= position['sl']:
                    pips = (position['entry'] - position['sl']) / PIP_VALUE
                    results.append({
                        'entry_time': position['entry_time'],
                        'exit_time': current_time,
                        'type': 'SELL',
                        'entry': position['entry'],
                        'exit': position['sl'],
                        'pips': round(pips, 1),
                        'mfe': round(position['mfe'], 1),
                        'bars': position['bars'],
                        'exit_reason': f'TRAIL STOP'
                    })
                    position = None
                    continue

        # Check for new signals
        if position is None and is_trading_window(current_time):
            trend_dir = get_trend_direction(df, i, ema_fast, ema_med, ma_trend, atr)
            adx_signal = get_adx_di_signal(adx, di_plus, di_minus, i)

            close_price = df['close'].iloc[i]
            open_price = df['open'].iloc[i]
            is_bullish = close_price > open_price
            is_bearish = close_price < open_price

            current_atr = atr[i] if not pd.isna(atr[i]) else 5.0

            # BUY signal
            if trend_dir == 1 and adx_signal == 1 and is_bullish:
                sl_pips = np.random.randint(SL_MIN, SL_MAX + 1)
                entry_price = close_price

                position = {
                    'type': 'BUY',
                    'entry': entry_price,
                    'entry_time': current_time,
                    'sl': entry_price - sl_pips * PIP_VALUE,
                    'tp1': entry_price + TARGET1_ATR * current_atr,
                    'tp2': entry_price + TARGET2_ATR * current_atr,
                    'tp3': entry_price + TARGET3_ATR * current_atr,
                    'bars': 0,
                    'mfe': 0,
                    'target_hit': 0,
                    'be_activated': False
                }

            # SELL signal
            elif trend_dir == -1 and adx_signal == -1 and is_bearish:
                sl_pips = np.random.randint(SL_MIN, SL_MAX + 1)
                entry_price = close_price

                position = {
                    'type': 'SELL',
                    'entry': entry_price,
                    'entry_time': current_time,
                    'sl': entry_price + sl_pips * PIP_VALUE,
                    'tp1': entry_price - TARGET1_ATR * current_atr,
                    'tp2': entry_price - TARGET2_ATR * current_atr,
                    'tp3': entry_price - TARGET3_ATR * current_atr,
                    'bars': 0,
                    'mfe': 0,
                    'target_hit': 0,
                    'be_activated': False
                }

            prev_trend_dir = trend_dir

    return pd.DataFrame(results)


def main():
    print("Loading data...")
    df = load_data('xauusd_m5_3y.csv')
    print(f"Loaded {len(df)} bars from {df['datetime'].iloc[0]} to {df['datetime'].iloc[-1]}")

    print("\nRunning backtest...")
    results = backtest(df)

    # Save results
    results.to_csv('mix1_backtest_results.csv', index=False)
    print(f"\nSaved {len(results)} trades to mix1_backtest_results.csv")

    # Statistics
    if len(results) > 0:
        wins = results[results['pips'] > 0]
        losses = results[results['pips'] <= 0]

        print("\n" + "="*60)
        print("MIX1_ADX_CLA BACKTEST RESULTS")
        print("="*60)
        print(f"Total trades: {len(results)}")
        print(f"Winners: {len(wins)} ({100*len(wins)/len(results):.1f}%)")
        print(f"Losers: {len(losses)} ({100*len(losses)/len(results):.1f}%)")
        print(f"Total pips: {results['pips'].sum():.1f}")
        print(f"Avg pips/trade: {results['pips'].mean():.1f}")
        print(f"Max win: {results['pips'].max():.1f}")
        print(f"Max loss: {results['pips'].min():.1f}")
        print(f"Avg MFE: {results['mfe'].mean():.1f}")

        # By exit reason
        print("\nBy Exit Reason:")
        for reason in results['exit_reason'].unique():
            subset = results[results['exit_reason'] == reason]
            print(f"  {reason}: {len(subset)} trades, {subset['pips'].sum():.1f} pips")


if __name__ == "__main__":
    main()
