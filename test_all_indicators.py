#!/usr/bin/env python3
"""
Test top 15 EA-suitable indicators on XAUUSD M5 data
With parameter optimization for M5 scalping
"""
import pandas as pd
import numpy as np
import warnings
warnings.filterwarnings('ignore')

# Load data
df = pd.read_csv('/home/user/r1/xauusd_m5_3y.csv')
df['datetime'] = pd.to_datetime(df['day'] + ' ' + df['time'])
df = df.sort_values('datetime').reset_index(drop=True)
df['hour'] = df['datetime'].dt.hour
df['atr_20'] = (df['high'] - df['low']).rolling(20).mean()

print(f"Učitano {len(df):,} svjećica: {df['day'].iloc[0]} do {df['day'].iloc[-1]}")
print("=" * 100)

# ============================================================
# INDICATOR IMPLEMENTATIONS
# ============================================================

def supertrend(df, period=10, multiplier=3.0):
    """Supertrend indicator"""
    atr = (df['high'] - df['low']).ewm(span=period, adjust=False).mean()
    hl2 = (df['high'] + df['low']) / 2
    upper = hl2 + multiplier * atr
    lower = hl2 - multiplier * atr

    trend = pd.Series(1, index=df.index)
    final_upper = upper.copy()
    final_lower = lower.copy()

    for i in range(1, len(df)):
        if lower.iloc[i] > final_lower.iloc[i-1]:
            final_lower.iloc[i] = lower.iloc[i]
        elif df['close'].iloc[i-1] > final_lower.iloc[i-1]:
            final_lower.iloc[i] = final_lower.iloc[i-1]
        else:
            final_lower.iloc[i] = lower.iloc[i]

        if upper.iloc[i] < final_upper.iloc[i-1]:
            final_upper.iloc[i] = upper.iloc[i]
        elif df['close'].iloc[i-1] < final_upper.iloc[i-1]:
            final_upper.iloc[i] = final_upper.iloc[i-1]
        else:
            final_upper.iloc[i] = upper.iloc[i]

        if trend.iloc[i-1] == 1:
            trend.iloc[i] = -1 if df['close'].iloc[i] < final_lower.iloc[i] else 1
        else:
            trend.iloc[i] = 1 if df['close'].iloc[i] > final_upper.iloc[i] else -1

    return trend

def ut_bot(df, key=1, atr_period=10):
    """UT Bot - ATR Trailing Stop"""
    atr = (df['high'] - df['low']).rolling(atr_period).mean()
    nloss = key * atr

    trailing_stop = pd.Series(0.0, index=df.index)
    pos = pd.Series(0, index=df.index)

    for i in range(1, len(df)):
        if pd.isna(nloss.iloc[i]):
            continue
        src = df['close'].iloc[i]
        src_prev = df['close'].iloc[i-1]
        prev_ts = trailing_stop.iloc[i-1]
        nl = nloss.iloc[i]

        if src > prev_ts and src_prev > prev_ts:
            trailing_stop.iloc[i] = max(prev_ts, src - nl)
        elif src < prev_ts and src_prev < prev_ts:
            trailing_stop.iloc[i] = min(prev_ts, src + nl)
        elif src > prev_ts:
            trailing_stop.iloc[i] = src - nl
        else:
            trailing_stop.iloc[i] = src + nl

        if src_prev < prev_ts and src > prev_ts:
            pos.iloc[i] = 1
        elif src_prev > prev_ts and src < prev_ts:
            pos.iloc[i] = -1
        else:
            pos.iloc[i] = pos.iloc[i-1]

    return pos

def alphatrend(df, coeff=1.0, period=14):
    """AlphaTrend indicator"""
    src = df['close']
    atr = (df['high'] - df['low']).rolling(period).mean()

    up = src - coeff * atr
    dn = src + coeff * atr

    alpha = pd.Series(0.0, index=df.index)
    trend = pd.Series(1, index=df.index)

    # RSI for direction
    delta = src.diff()
    gain = delta.where(delta > 0, 0).rolling(period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(period).mean()
    rs = gain / loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))

    for i in range(period, len(df)):
        if rsi.iloc[i] >= 50:
            if up.iloc[i] > alpha.iloc[i-1]:
                alpha.iloc[i] = up.iloc[i]
            else:
                alpha.iloc[i] = alpha.iloc[i-1]
            trend.iloc[i] = 1
        else:
            if dn.iloc[i] < alpha.iloc[i-1]:
                alpha.iloc[i] = dn.iloc[i]
            else:
                alpha.iloc[i] = alpha.iloc[i-1]
            trend.iloc[i] = -1

    buy = (trend == 1) & (trend.shift(1) == -1)
    sell = (trend == -1) & (trend.shift(1) == 1)

    return trend, buy, sell

def chandelier_exit(df, period=22, mult=3.0):
    """Chandelier Exit"""
    atr = (df['high'] - df['low']).rolling(period).mean()
    highest = df['high'].rolling(period).max()
    lowest = df['low'].rolling(period).min()

    long_stop = highest - mult * atr
    short_stop = lowest + mult * atr

    direction = pd.Series(1, index=df.index)
    for i in range(period, len(df)):
        if df['close'].iloc[i] > short_stop.iloc[i-1]:
            direction.iloc[i] = 1
        elif df['close'].iloc[i] < long_stop.iloc[i-1]:
            direction.iloc[i] = -1
        else:
            direction.iloc[i] = direction.iloc[i-1]

    buy = (direction == 1) & (direction.shift(1) == -1)
    sell = (direction == -1) & (direction.shift(1) == 1)

    return direction, buy, sell

def ott(df, period=2, percent=1.4):
    """Optimized Trend Tracker (OTT)"""
    # VAR moving average
    src = df['close']
    var_ma = src.ewm(span=period, adjust=False).mean()

    long_stop = var_ma * (100 - percent) / 100
    short_stop = var_ma * (100 + percent) / 100

    ott_line = pd.Series(0.0, index=df.index)
    direction = pd.Series(1, index=df.index)

    for i in range(1, len(df)):
        if var_ma.iloc[i] > ott_line.iloc[i-1]:
            ott_line.iloc[i] = max(long_stop.iloc[i], ott_line.iloc[i-1])
            direction.iloc[i] = 1
        else:
            ott_line.iloc[i] = min(short_stop.iloc[i], ott_line.iloc[i-1])
            direction.iloc[i] = -1

    buy = (direction == 1) & (direction.shift(1) == -1)
    sell = (direction == -1) & (direction.shift(1) == 1)

    return direction, buy, sell

def pmax(df, atr_period=10, atr_mult=3.0, ma_period=10):
    """Profit Maximizer (PMax)"""
    src = df['close']
    ma = src.ewm(span=ma_period, adjust=False).mean()
    atr = (df['high'] - df['low']).rolling(atr_period).mean()

    long_stop = ma - atr_mult * atr
    short_stop = ma + atr_mult * atr

    pmax_line = pd.Series(0.0, index=df.index)
    direction = pd.Series(1, index=df.index)

    for i in range(max(atr_period, ma_period), len(df)):
        if ma.iloc[i] > pmax_line.iloc[i-1]:
            pmax_line.iloc[i] = max(long_stop.iloc[i], pmax_line.iloc[i-1])
            direction.iloc[i] = 1
        else:
            pmax_line.iloc[i] = min(short_stop.iloc[i], pmax_line.iloc[i-1])
            direction.iloc[i] = -1

    buy = (direction == 1) & (direction.shift(1) == -1)
    sell = (direction == -1) & (direction.shift(1) == 1)

    return direction, buy, sell

def hull_ma(df, period=55):
    """Hull Moving Average with trend direction"""
    src = df['close']
    wma_half = src.rolling(period // 2).apply(lambda x: np.average(x, weights=range(1, len(x)+1)))
    wma_full = src.rolling(period).apply(lambda x: np.average(x, weights=range(1, len(x)+1)))
    raw = 2 * wma_half - wma_full
    sqrt_period = int(np.sqrt(period))
    hma = raw.rolling(sqrt_period).apply(lambda x: np.average(x, weights=range(1, len(x)+1)))

    direction = (hma > hma.shift(1)).astype(int) * 2 - 1
    buy = (direction == 1) & (direction.shift(1) == -1)
    sell = (direction == -1) & (direction.shift(1) == 1)

    return direction, buy, sell

def ssl_hybrid(df, period=10):
    """SSL Hybrid - SMA High/Low Channel"""
    sma_high = df['high'].rolling(period).mean()
    sma_low = df['low'].rolling(period).mean()

    direction = pd.Series(0, index=df.index)
    for i in range(period, len(df)):
        if df['close'].iloc[i] > sma_high.iloc[i]:
            direction.iloc[i] = 1
        elif df['close'].iloc[i] < sma_low.iloc[i]:
            direction.iloc[i] = -1
        else:
            direction.iloc[i] = direction.iloc[i-1]

    buy = (direction == 1) & (direction.shift(1) == -1)
    sell = (direction == -1) & (direction.shift(1) == 1)

    return direction, buy, sell

def squeeze_momentum(df, bb_length=20, kc_length=20, kc_mult=1.5):
    """Squeeze Momentum Indicator"""
    src = df['close']
    bb_mid = src.rolling(bb_length).mean()
    bb_std = src.rolling(bb_length).std()
    bb_upper = bb_mid + 2 * bb_std
    bb_lower = bb_mid - 2 * bb_std

    atr = (df['high'] - df['low']).rolling(kc_length).mean()
    kc_upper = bb_mid + kc_mult * atr
    kc_lower = bb_mid - kc_mult * atr

    squeeze = (bb_lower > kc_lower) & (bb_upper < kc_upper)

    # Momentum
    hh = df['high'].rolling(kc_length).max()
    ll = df['low'].rolling(kc_length).min()
    momentum = src - ((hh + ll) / 2 + bb_mid) / 2

    # Squeeze release signals
    release = (squeeze.shift(1) == True) & (squeeze == False)
    buy = release & (momentum > 0)
    sell = release & (momentum < 0)

    return squeeze, momentum, buy, sell

def macd_signal(df, fast=12, slow=26, signal=9):
    """MACD crossover signals"""
    ema_fast = df['close'].ewm(span=fast, adjust=False).mean()
    ema_slow = df['close'].ewm(span=slow, adjust=False).mean()
    macd = ema_fast - ema_slow
    signal_line = macd.ewm(span=signal, adjust=False).mean()

    direction = (macd > signal_line).astype(int) * 2 - 1
    buy = (macd > signal_line) & (macd.shift(1) <= signal_line.shift(1))
    sell = (macd < signal_line) & (macd.shift(1) >= signal_line.shift(1))

    return direction, buy, sell

def rsi_signal(df, period=14, ob=70, os=30):
    """RSI overbought/oversold signals"""
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0).rolling(period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(period).mean()
    rs = gain / loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))

    buy = (rsi < os) & (rsi.shift(1) >= os)  # Cross below oversold
    sell = (rsi > ob) & (rsi.shift(1) <= ob)  # Cross above overbought

    return rsi, buy, sell

# ============================================================
# BACKTESTING FUNCTION
# ============================================================

def backtest_indicator(df, buy_col, sell_col, name, sl_mult=1.5, tp_mult=2.5, max_bars=48):
    """Backtest an indicator's signals"""
    trades = []
    cooldown = 0

    for i in range(100, len(df)):
        if cooldown > 0:
            cooldown -= 1
            continue

        atr = df['atr_20'].iloc[i]
        if pd.isna(atr) or atr == 0:
            continue

        is_long = df[buy_col].iloc[i] if buy_col in df.columns else False
        is_short = df[sell_col].iloc[i] if sell_col in df.columns else False

        if not is_long and not is_short:
            continue

        entry = df['close'].iloc[i]
        direction = 1 if is_long else -1
        sl = entry - direction * sl_mult * atr
        tp = entry + direction * tp_mult * atr

        exit_type = 'TIME'
        exit_bar = min(i + max_bars, len(df) - 1)
        pnl = 0

        for j in range(i + 1, min(i + max_bars + 1, len(df))):
            if direction == 1:
                if df['low'].iloc[j] <= sl:
                    pnl = -sl_mult * atr
                    exit_type = 'SL'
                    exit_bar = j
                    break
                if df['high'].iloc[j] >= tp:
                    pnl = tp_mult * atr
                    exit_type = 'TP'
                    exit_bar = j
                    break
            else:
                if df['high'].iloc[j] >= sl:
                    pnl = -sl_mult * atr
                    exit_type = 'SL'
                    exit_bar = j
                    break
                if df['low'].iloc[j] <= tp:
                    pnl = tp_mult * atr
                    exit_type = 'TP'
                    exit_bar = j
                    break
        else:
            pnl = (df['close'].iloc[exit_bar] - entry) * direction

        cooldown = exit_bar - i
        trades.append({'pnl': pnl, 'dir': direction, 'exit': exit_type, 'bars': exit_bar - i})

    if not trades:
        return None

    tdf = pd.DataFrame(trades)
    total = len(tdf)
    wr = (tdf['pnl'] > 0).mean() * 100
    avg_w = tdf[tdf['pnl'] > 0]['pnl'].mean() if (tdf['pnl'] > 0).any() else 0
    avg_l = abs(tdf[tdf['pnl'] <= 0]['pnl'].mean()) if (tdf['pnl'] <= 0).any() else 0
    pf = tdf[tdf['pnl'] > 0]['pnl'].sum() / abs(tdf[tdf['pnl'] <= 0]['pnl'].sum()) if (tdf['pnl'] <= 0).any() and (tdf['pnl'] > 0).any() else 0
    total_pnl = tdf['pnl'].sum()
    exp = tdf['pnl'].mean()
    rr = avg_w / avg_l if avg_l > 0 else 0

    return {
        'name': name,
        'trades': total,
        'wr': wr,
        'pf': pf,
        'total_pnl': total_pnl,
        'exp': exp,
        'rr': rr,
        'avg_bars': tdf['bars'].mean()
    }

# ============================================================
# RUN ALL INDICATORS
# ============================================================

print("\nGeneriranje signala za sve indikatore...")

# 1. Supertrend (multiple params)
for period, mult in [(10, 3), (7, 2), (14, 4)]:
    col = f'st_{period}_{mult}'
    df[col] = supertrend(df, period, mult)
    df[f'{col}_buy'] = (df[col] == 1) & (df[col].shift(1) == -1)
    df[f'{col}_sell'] = (df[col] == -1) & (df[col].shift(1) == 1)

# 2. UT Bot (multiple params)
for key, period in [(1, 10), (2, 14), (1.5, 7)]:
    col = f'ut_{key}_{period}'
    df[col] = ut_bot(df, key, period)
    df[f'{col}_buy'] = (df[col] == 1) & (df[col].shift(1) != 1)
    df[f'{col}_sell'] = (df[col] == -1) & (df[col].shift(1) != -1)

# 3. AlphaTrend
for coeff, period in [(1, 14), (1.5, 10), (0.8, 7)]:
    col = f'alpha_{coeff}_{period}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = alphatrend(df, coeff, period)

# 4. Chandelier Exit
for period, mult in [(22, 3), (14, 2), (10, 2.5)]:
    col = f'chand_{period}_{mult}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = chandelier_exit(df, period, mult)

# 5. OTT
for period, pct in [(2, 1.4), (3, 2.0), (5, 1.0)]:
    col = f'ott_{period}_{pct}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = ott(df, period, pct)

# 6. PMax
for atr_p, mult, ma_p in [(10, 3, 10), (7, 2, 5), (14, 3, 14)]:
    col = f'pmax_{atr_p}_{mult}_{ma_p}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = pmax(df, atr_p, mult, ma_p)

# 7. Hull MA
for period in [55, 20, 9]:
    col = f'hull_{period}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = hull_ma(df, period)

# 8. SSL Hybrid
for period in [10, 14, 5]:
    col = f'ssl_{period}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = ssl_hybrid(df, period)

# 9. Squeeze Momentum
for bb_len, kc_len, kc_mult in [(20, 20, 1.5), (14, 14, 1.5), (10, 10, 1.0)]:
    col = f'sqz_{bb_len}_{kc_len}'
    df[f'{col}_squeeze'], df[f'{col}_mom'], df[f'{col}_buy'], df[f'{col}_sell'] = squeeze_momentum(df, bb_len, kc_len, kc_mult)

# 10. MACD
for fast, slow, sig in [(12, 26, 9), (8, 17, 9), (5, 13, 5)]:
    col = f'macd_{fast}_{slow}_{sig}'
    df[f'{col}_dir'], df[f'{col}_buy'], df[f'{col}_sell'] = macd_signal(df, fast, slow, sig)

# 11. RSI
for period, ob, os in [(14, 70, 30), (7, 80, 20), (21, 65, 35)]:
    col = f'rsi_{period}'
    df[f'{col}_val'], df[f'{col}_buy'], df[f'{col}_sell'] = rsi_signal(df, period, ob, os)

print("Signali generirani. Pokrećem backtest...")

# ============================================================
# BACKTEST ALL
# ============================================================

results = []

# Supertrend
for period, mult in [(10, 3), (7, 2), (14, 4)]:
    col = f'st_{period}_{mult}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'Supertrend({period},{mult})')
    if r: results.append(r)

# UT Bot
for key, period in [(1, 10), (2, 14), (1.5, 7)]:
    col = f'ut_{key}_{period}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'UT Bot({key},{period})')
    if r: results.append(r)

# AlphaTrend
for coeff, period in [(1, 14), (1.5, 10), (0.8, 7)]:
    col = f'alpha_{coeff}_{period}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'AlphaTrend({coeff},{period})')
    if r: results.append(r)

# Chandelier
for period, mult in [(22, 3), (14, 2), (10, 2.5)]:
    col = f'chand_{period}_{mult}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'Chandelier({period},{mult})')
    if r: results.append(r)

# OTT
for period, pct in [(2, 1.4), (3, 2.0), (5, 1.0)]:
    col = f'ott_{period}_{pct}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'OTT({period},{pct})')
    if r: results.append(r)

# PMax
for atr_p, mult, ma_p in [(10, 3, 10), (7, 2, 5), (14, 3, 14)]:
    col = f'pmax_{atr_p}_{mult}_{ma_p}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'PMax({atr_p},{mult},{ma_p})')
    if r: results.append(r)

# Hull
for period in [55, 20, 9]:
    col = f'hull_{period}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'Hull MA({period})')
    if r: results.append(r)

# SSL
for period in [10, 14, 5]:
    col = f'ssl_{period}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'SSL Hybrid({period})')
    if r: results.append(r)

# Squeeze
for bb_len, kc_len, kc_mult in [(20, 20, 1.5), (14, 14, 1.5), (10, 10, 1.0)]:
    col = f'sqz_{bb_len}_{kc_len}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'Squeeze({bb_len},{kc_len})')
    if r: results.append(r)

# MACD
for fast, slow, sig in [(12, 26, 9), (8, 17, 9), (5, 13, 5)]:
    col = f'macd_{fast}_{slow}_{sig}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'MACD({fast},{slow},{sig})')
    if r: results.append(r)

# RSI
for period, ob, os in [(14, 70, 30), (7, 80, 20), (21, 65, 35)]:
    col = f'rsi_{period}'
    r = backtest_indicator(df, f'{col}_buy', f'{col}_sell', f'RSI({period},{ob}/{os})')
    if r: results.append(r)

# Sort by profit factor
results.sort(key=lambda x: -x['pf'])

print("\n" + "=" * 100)
print("REZULTATI SVIH INDIKATORA - SORTIRANO PO PROFIT FACTORU")
print("=" * 100)
print(f"{'Indikator':<30} {'Trades':>7} {'WR%':>7} {'PF':>7} {'R:R':>6} {'PnL':>10} {'Exp':>8} {'Bars':>5}")
print("-" * 100)

for r in results:
    print(f"{r['name']:<30} {r['trades']:>7} {r['wr']:>6.1f}% {r['pf']:>7.2f} {r['rr']:>6.2f} {r['total_pnl']:>10.0f} {r['exp']:>8.2f} {r['avg_bars']:>5.0f}")

# Top 10
print("\n" + "=" * 100)
print("TOP 10 INDIKATORA ZA XAUUSD M5")
print("=" * 100)
for i, r in enumerate(results[:10], 1):
    print(f"{i:>2}. {r['name']:<28} PF={r['pf']:.2f}, WR={r['wr']:.1f}%, Trades={r['trades']}, PnL={r['total_pnl']:.0f}")

# Best by category
print("\n" + "=" * 100)
print("NAJBOLJI PO KATEGORIJI")
print("=" * 100)

categories = {
    'Supertrend': [r for r in results if 'Supertrend' in r['name']],
    'UT Bot': [r for r in results if 'UT Bot' in r['name']],
    'AlphaTrend': [r for r in results if 'AlphaTrend' in r['name']],
    'Chandelier': [r for r in results if 'Chandelier' in r['name']],
    'OTT': [r for r in results if 'OTT' in r['name']],
    'PMax': [r for r in results if 'PMax' in r['name']],
    'Hull MA': [r for r in results if 'Hull' in r['name']],
    'SSL': [r for r in results if 'SSL' in r['name']],
    'Squeeze': [r for r in results if 'Squeeze' in r['name']],
    'MACD': [r for r in results if 'MACD' in r['name']],
    'RSI': [r for r in results if 'RSI' in r['name']],
}

for cat, cat_results in categories.items():
    if cat_results:
        best = max(cat_results, key=lambda x: x['pf'])
        print(f"{cat:<15}: {best['name']:<25} PF={best['pf']:.2f}, WR={best['wr']:.1f}%")

# ============================================================
# COMBINED SETUPS WITH BEST INDICATORS
# ============================================================
print("\n" + "=" * 100)
print("KOMBINIRANI SETUPI - NAJBOLJI INDIKATORI")
print("=" * 100)

# Session filter
def is_good_session(hour):
    return hour in [2, 3, 4, 9, 10, 13, 14, 15, 16, 17]  # London + NY

df['good_session'] = df['hour'].apply(is_good_session)
df['vol_above'] = df['volume'] > df['volume'].rolling(50).mean()

# Best Supertrend + Best Squeeze + Session
st_best = 'st_10_3'
sqz_best = 'sqz_20_20'

df['combo1_buy'] = df[f'{st_best}_buy'] & df[f'{sqz_best}_buy'].shift(1).fillna(False) & df['good_session']
df['combo1_sell'] = df[f'{st_best}_sell'] & df[f'{sqz_best}_sell'].shift(1).fillna(False) & df['good_session']

# AlphaTrend + UT Bot confluence
alpha_best = 'alpha_1_14'
ut_best = 'ut_1_10'

df['combo2_buy'] = df[f'{alpha_best}_buy'] & (df[f'{ut_best}'] == 1) & df['good_session']
df['combo2_sell'] = df[f'{alpha_best}_sell'] & (df[f'{ut_best}'] == -1) & df['good_session']

# Chandelier + Hull MA + Volume
chand_best = 'chand_14_2'
hull_best = 'hull_9'

df['combo3_buy'] = df[f'{chand_best}_buy'] & (df[f'{hull_best}_dir'] == 1) & df['vol_above']
df['combo3_sell'] = df[f'{chand_best}_sell'] & (df[f'{hull_best}_dir'] == -1) & df['vol_above']

# Test combined
combos = [
    ('ST + Squeeze + Session', 'combo1_buy', 'combo1_sell'),
    ('AlphaTrend + UT Bot + Session', 'combo2_buy', 'combo2_sell'),
    ('Chandelier + Hull + Volume', 'combo3_buy', 'combo3_sell'),
]

for name, buy_col, sell_col in combos:
    r = backtest_indicator(df, buy_col, sell_col, name)
    if r:
        print(f"\n{name}:")
        print(f"  Trades: {r['trades']}, WR: {r['wr']:.1f}%, PF: {r['pf']:.2f}, R:R: {r['rr']:.2f}")
        print(f"  Total PnL: {r['total_pnl']:.0f}, Expectancy: {r['exp']:.2f}, Avg bars: {r['avg_bars']:.0f}")

print("\n" + "=" * 100)
print("ANALIZA ZAVRŠENA")
print("=" * 100)
