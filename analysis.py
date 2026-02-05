#!/usr/bin/env python3
"""
Comprehensive XAUUSD M5 Analysis for EA Development
Analyzes candlestick patterns, volatility regimes, session effects,
and constructs rule-based trading setups.
"""
import pandas as pd
import numpy as np
from datetime import datetime, time
import warnings
warnings.filterwarnings('ignore')

# ============================================================
# 1. LOAD DATA
# ============================================================
df = pd.read_csv('/home/user/r1/xauusd_m5_3y.csv')
df['datetime'] = pd.to_datetime(df['day'] + ' ' + df['time'])
df = df.sort_values('datetime').reset_index(drop=True)

print("=" * 80)
print("XAUUSD M5 ANALIZA - PREGLED PODATAKA")
print("=" * 80)
print(f"Ukupno svjećica: {len(df):,}")
print(f"Raspon: {df['day'].iloc[0]} do {df['day'].iloc[-1]}")
print(f"Cijena raspon: {df['low'].min():.2f} - {df['high'].max():.2f}")
print(f"Prosječni volumen: {df['volume'].mean():.0f}")
print()

# ============================================================
# 2. BASIC CANDLE METRICS
# ============================================================
df['body'] = abs(df['close'] - df['open'])
df['range'] = df['high'] - df['low']
df['upper_wick'] = df['high'] - df[['open', 'close']].max(axis=1)
df['lower_wick'] = df[['open', 'close']].min(axis=1) - df['low']
df['bullish'] = (df['close'] > df['open']).astype(int)
df['bearish'] = (df['close'] < df['open']).astype(int)
df['doji'] = (df['body'] < df['range'] * 0.1).astype(int)
df['body_pct'] = df['body'] / df['close'] * 100
df['range_pct'] = df['range'] / df['close'] * 100

# Returns
df['ret'] = df['close'].pct_change()
df['ret_5'] = df['close'].pct_change(5)
df['ret_12'] = df['close'].pct_change(12)

print("=" * 80)
print("OSNOVNA STATISTIKA SVJEĆICA")
print("=" * 80)
print(f"Prosječni range (pips): {df['range'].mean():.2f}")
print(f"Medijalni range (pips): {df['range'].median():.2f}")
print(f"Std range: {df['range'].std():.2f}")
print(f"Prosječno tijelo: {df['body'].mean():.2f}")
print(f"Bullish svjećice: {df['bullish'].sum():,} ({df['bullish'].mean()*100:.1f}%)")
print(f"Bearish svjećice: {df['bearish'].sum():,} ({df['bearish'].mean()*100:.1f}%)")
print(f"Doji svjećice: {df['doji'].sum():,} ({df['doji'].mean()*100:.1f}%)")
print()

# ============================================================
# 3. SESSION ANALYSIS (ICT Killzones)
# ============================================================
df['hour'] = df['datetime'].dt.hour
df['minute'] = df['datetime'].dt.minute
df['dow'] = df['datetime'].dt.dayofweek  # 0=Mon, 4=Fri

def classify_session(row):
    h, m = row['hour'], row['minute']
    t = h * 60 + m
    # NY time approximation (UTC times from data)
    if 1200 <= t < 1440 or 0 <= t < 60:  # 20:00-01:00 Asia
        return 'Asia'
    elif 120 <= t < 300:  # 02:00-05:00 London
        return 'London'
    elif 570 <= t < 660:  # 09:30-11:00 NY_AM
        return 'NY_AM'
    elif 720 <= t < 780:  # 12:00-13:00 NY_Lunch
        return 'NY_Lunch'
    elif 810 <= t < 960:  # 13:30-16:00 NY_PM
        return 'NY_PM'
    else:
        return 'Other'

df['session'] = df.apply(classify_session, axis=1)

print("=" * 80)
print("ANALIZA PO SESIJAMA (Killzone koncepti)")
print("=" * 80)
session_stats = df.groupby('session').agg(
    count=('range', 'count'),
    avg_range=('range', 'mean'),
    med_range=('range', 'median'),
    std_range=('range', 'std'),
    avg_volume=('volume', 'mean'),
    avg_body=('body', 'mean'),
    bull_pct=('bullish', 'mean')
).round(3)
print(session_stats.to_string())
print()

# Session range comparison
print("Rangiranje sesija po prosječnom rasponu:")
for sess in session_stats.sort_values('avg_range', ascending=False).index:
    r = session_stats.loc[sess]
    print(f"  {sess:12s}: range={r['avg_range']:.2f}, vol={r['avg_volume']:.0f}, bull%={r['bull_pct']*100:.1f}%")
print()

# ============================================================
# 4. VOLATILITY REGIME ANALYSIS
# ============================================================
# ATR calculation
df['atr_20'] = df['range'].rolling(20).mean()
df['atr_100'] = df['range'].rolling(100).mean()

# Volatility regimes based on percentiles
atr_p25 = df['atr_20'].quantile(0.25)
atr_p50 = df['atr_20'].quantile(0.50)
atr_p75 = df['atr_20'].quantile(0.75)

def vol_regime(atr):
    if pd.isna(atr): return 'Unknown'
    if atr < atr_p25: return 'Low'
    elif atr < atr_p75: return 'Medium'
    else: return 'High'

df['vol_regime'] = df['atr_20'].apply(vol_regime)

print("=" * 80)
print("VOLATILITY REŽIMI")
print("=" * 80)
print(f"ATR(20) percentili: P25={atr_p25:.2f}, P50={atr_p50:.2f}, P75={atr_p75:.2f}")
vol_stats = df[df['vol_regime'] != 'Unknown'].groupby('vol_regime').agg(
    count=('range', 'count'),
    avg_range=('range', 'mean'),
    avg_body=('body', 'mean'),
    avg_volume=('volume', 'mean'),
    next_ret_mean=('ret', lambda x: x.shift(-12).mean()),
).round(5)
print(vol_stats.to_string())
print()

# ============================================================
# 5. COMPRESSION / EXPANSION DETECTION
# ============================================================
# Bollinger Band width as compression metric
df['bb_mid'] = df['close'].rolling(20).mean()
df['bb_std'] = df['close'].rolling(20).std()
df['bb_width'] = (2 * df['bb_std']) / df['bb_mid'] * 100

# Keltner Channel for squeeze detection
df['kc_range'] = df['range'].rolling(20).mean()
df['kc_upper'] = df['bb_mid'] + 1.5 * df['kc_range']
df['kc_lower'] = df['bb_mid'] - 1.5 * df['kc_range']
df['squeeze'] = ((df['bb_mid'] - df['bb_std']) > df['kc_lower']) & \
                ((df['bb_mid'] + df['bb_std']) < df['kc_upper'])

# Squeeze statistics
squeeze_pct = df['squeeze'].mean() * 100
print("=" * 80)
print("KOMPRESIJA / EKSPANZIJA (Squeeze)")
print("=" * 80)
print(f"Svjećica u squeeze-u: {squeeze_pct:.1f}%")

# What happens after squeeze releases?
df['squeeze_release'] = (df['squeeze'].shift(1) == True) & (df['squeeze'] == False)
release_indices = df[df['squeeze_release'] == True].index

if len(release_indices) > 0:
    fwd_returns_12 = []
    fwd_returns_24 = []
    fwd_ranges_12 = []
    for idx in release_indices:
        if idx + 24 < len(df):
            fwd_returns_12.append(abs(df.loc[idx + 12, 'close'] - df.loc[idx, 'close']))
            fwd_returns_24.append(abs(df.loc[idx + 24, 'close'] - df.loc[idx, 'close']))
            fwd_ranges_12.append(df.loc[idx:idx+12, 'range'].mean())

    avg_normal_range = df['range'].mean()
    print(f"Broj squeeze release-ova: {len(release_indices)}")
    print(f"Prosj. pomak 1h nakon release-a: {np.mean(fwd_returns_12):.2f} (vs normal range {avg_normal_range:.2f})")
    print(f"Prosj. pomak 2h nakon release-a: {np.mean(fwd_returns_24):.2f}")
    print(f"Prosj. range 1h nakon release-a: {np.mean(fwd_ranges_12):.2f} (vs normal {avg_normal_range:.2f})")
    expansion_ratio = np.mean(fwd_ranges_12) / avg_normal_range
    print(f"Expansion ratio (range after/normal): {expansion_ratio:.2f}x")
print()

# ============================================================
# 6. IMPULSIVE vs CORRECTIVE MOVE DETECTION
# ============================================================
# Impulsive: large body relative to range, directional
# Corrective: small body relative to range, overlapping
df['body_range_ratio'] = df['body'] / df['range'].replace(0, np.nan)
df['impulsive'] = (df['body_range_ratio'] > 0.6) & (df['range'] > df['atr_20'] * 1.2)
df['corrective'] = (df['body_range_ratio'] < 0.3) | (df['range'] < df['atr_20'] * 0.5)

print("=" * 80)
print("IMPULSIVNI vs KOREKTIVNI POKRETI")
print("=" * 80)
imp_pct = df['impulsive'].mean() * 100
cor_pct = df['corrective'].mean() * 100
print(f"Impulsivne svjećice: {imp_pct:.1f}%")
print(f"Korektivne svjećice: {cor_pct:.1f}%")

# What follows impulsive candles?
df['after_impulse_bull'] = (df['impulsive'].shift(1) == True) & (df['bullish'].shift(1) == 1)
df['after_impulse_bear'] = (df['impulsive'].shift(1) == True) & (df['bearish'].shift(1) == 1)

bull_impulse_continuation = df[df['after_impulse_bull']]['bullish'].mean() * 100
bear_impulse_continuation = df[df['after_impulse_bear']]['bearish'].mean() * 100
print(f"Nastavak nakon bullish impulsa: {bull_impulse_continuation:.1f}%")
print(f"Nastavak nakon bearish impulsa: {bear_impulse_continuation:.1f}%")
print()

# ============================================================
# 7. CANDLE SEQUENCE ANALYSIS (3-7 bars)
# ============================================================
print("=" * 80)
print("ANALIZA SEKVENCI SVJEĆICA")
print("=" * 80)

# 3-bar patterns
def analyze_sequence(df, n_bars, fwd_bars=12):
    """Analyze n-bar bullish/bearish sequences and what follows."""
    results = []
    for i in range(n_bars, len(df) - fwd_bars):
        seq = df.iloc[i-n_bars:i]
        all_bull = (seq['bullish'] == 1).all()
        all_bear = (seq['bearish'] == 1).all()

        if all_bull or all_bear:
            fwd_ret = df.iloc[i + fwd_bars]['close'] - df.iloc[i]['close']
            entry_price = df.iloc[i]['close']
            fwd_ret_pct = fwd_ret / entry_price * 100
            results.append({
                'type': 'bull_seq' if all_bull else 'bear_seq',
                'fwd_ret': fwd_ret,
                'fwd_ret_pct': fwd_ret_pct,
                'idx': i
            })
    return pd.DataFrame(results) if results else pd.DataFrame()

for n in [3, 4, 5]:
    seq_df = analyze_sequence(df, n)
    if len(seq_df) > 0:
        bull_seqs = seq_df[seq_df['type'] == 'bull_seq']
        bear_seqs = seq_df[seq_df['type'] == 'bear_seq']

        print(f"\n{n}-bar sekvence (forward 1h):")
        if len(bull_seqs) > 0:
            bull_cont = (bull_seqs['fwd_ret'] > 0).mean() * 100
            bull_avg = bull_seqs['fwd_ret'].mean()
            print(f"  {n}x bullish ({len(bull_seqs)} slučajeva): nastavak gore {bull_cont:.1f}%, prosj. pomak {bull_avg:.2f}")
        if len(bear_seqs) > 0:
            bear_cont = (bear_seqs['fwd_ret'] < 0).mean() * 100
            bear_avg = bear_seqs['fwd_ret'].mean()
            print(f"  {n}x bearish ({len(bear_seqs)} slučajeva): nastavak dolje {bear_cont:.1f}%, prosj. pomak {bear_avg:.2f}")
print()

# ============================================================
# 8. BREAKOUT vs FAKE BREAKOUT ANALYSIS
# ============================================================
print("=" * 80)
print("BREAKOUT vs LAŽNI BREAKOUT")
print("=" * 80)

# Rolling high/low (support/resistance)
lookback = 50  # 50 bars = ~4 hours
df['rolling_high'] = df['high'].rolling(lookback).max().shift(1)
df['rolling_low'] = df['low'].rolling(lookback).min().shift(1)

# Breakout detection
df['breakout_high'] = df['close'] > df['rolling_high']
df['breakout_low'] = df['close'] < df['rolling_low']

# Check if breakout holds after 12 bars
breakout_high_idx = df[df['breakout_high'] == True].index
breakout_low_idx = df[df['breakout_low'] == True].index

if len(breakout_high_idx) > 0:
    true_breakouts_up = 0
    fake_breakouts_up = 0
    for idx in breakout_high_idx:
        if idx + 12 < len(df):
            if df.loc[idx + 12, 'close'] > df.loc[idx, 'rolling_high']:
                true_breakouts_up += 1
            else:
                fake_breakouts_up += 1
    total_up = true_breakouts_up + fake_breakouts_up
    if total_up > 0:
        print(f"Breakout GORE ({total_up} slučajeva):")
        print(f"  Pravi breakout: {true_breakouts_up} ({true_breakouts_up/total_up*100:.1f}%)")
        print(f"  Lažni breakout: {fake_breakouts_up} ({fake_breakouts_up/total_up*100:.1f}%)")

if len(breakout_low_idx) > 0:
    true_breakouts_down = 0
    fake_breakouts_down = 0
    for idx in breakout_low_idx:
        if idx + 12 < len(df):
            if df.loc[idx + 12, 'close'] < df.loc[idx, 'rolling_low']:
                true_breakouts_down += 1
            else:
                fake_breakouts_down += 1
    total_down = true_breakouts_down + fake_breakouts_down
    if total_down > 0:
        print(f"Breakout DOLJE ({total_down} slučajeva):")
        print(f"  Pravi breakout: {true_breakouts_down} ({true_breakouts_down/total_down*100:.1f}%)")
        print(f"  Lažni breakout: {fake_breakouts_down} ({fake_breakouts_down/total_down*100:.1f}%)")
print()

# ============================================================
# 9. DAY OF WEEK ANALYSIS
# ============================================================
print("=" * 80)
print("ANALIZA PO DANU U TJEDNU")
print("=" * 80)
dow_names = {0: 'Pon', 1: 'Uto', 2: 'Sri', 3: 'Čet', 4: 'Pet'}
dow_stats = df.groupby('dow').agg(
    avg_range=('range', 'mean'),
    avg_volume=('volume', 'mean'),
    avg_body=('body', 'mean'),
    bull_pct=('bullish', 'mean')
).round(3)
for dow_num, row in dow_stats.iterrows():
    name = dow_names.get(dow_num, f'Dan {dow_num}')
    print(f"  {name}: range={row['avg_range']:.2f}, vol={row['avg_volume']:.0f}, body={row['avg_body']:.2f}, bull%={row['bull_pct']*100:.1f}%")
print()

# ============================================================
# 10. HOUR OF DAY ANALYSIS
# ============================================================
print("=" * 80)
print("ANALIZA PO SATU U DANU (top 10 po range-u)")
print("=" * 80)
hour_stats = df.groupby('hour').agg(
    avg_range=('range', 'mean'),
    avg_volume=('volume', 'mean'),
    count=('range', 'count')
).round(2)
hour_sorted = hour_stats.sort_values('avg_range', ascending=False).head(10)
for h, row in hour_sorted.iterrows():
    print(f"  {h:02d}:00 - range={row['avg_range']:.2f}, vol={row['avg_volume']:.0f}")
print()

# ============================================================
# 11. SUPERTREND SIMULATION
# ============================================================
print("=" * 80)
print("SUPERTREND SIMULACIJA (ATR period=10, mult=3)")
print("=" * 80)

def supertrend(df, period=10, multiplier=3.0):
    hl2 = (df['high'] + df['low']) / 2
    atr = df['range'].rolling(period).mean()

    upper = hl2 + multiplier * atr
    lower = hl2 - multiplier * atr

    st_trend = pd.Series(1, index=df.index)
    final_upper = upper.copy()
    final_lower = lower.copy()

    for i in range(1, len(df)):
        if pd.isna(atr.iloc[i]):
            continue
        # Upper band
        if lower.iloc[i] > final_lower.iloc[i-1] or df['close'].iloc[i-1] <= final_lower.iloc[i-1]:
            final_lower.iloc[i] = lower.iloc[i]
        else:
            final_lower.iloc[i] = final_lower.iloc[i-1]
        # Lower band
        if upper.iloc[i] < final_upper.iloc[i-1] or df['close'].iloc[i-1] >= final_upper.iloc[i-1]:
            final_upper.iloc[i] = upper.iloc[i]
        else:
            final_upper.iloc[i] = final_upper.iloc[i-1]

        # Trend
        if st_trend.iloc[i-1] == -1 and df['close'].iloc[i] > final_upper.iloc[i-1]:
            st_trend.iloc[i] = 1
        elif st_trend.iloc[i-1] == 1 and df['close'].iloc[i] < final_lower.iloc[i-1]:
            st_trend.iloc[i] = -1
        else:
            st_trend.iloc[i] = st_trend.iloc[i-1]

    return st_trend

df['st_trend'] = supertrend(df)
df['st_signal'] = df['st_trend'].diff()

st_buys = (df['st_signal'] == 2).sum()
st_sells = (df['st_signal'] == -2).sum()
print(f"Buy signali: {st_buys}")
print(f"Sell signali: {st_sells}")

# Supertrend performance
st_signal_idx = df[df['st_signal'].abs() == 2].index
trades = []
for i, idx in enumerate(st_signal_idx):
    if i + 1 < len(st_signal_idx):
        next_idx = st_signal_idx[i + 1]
        entry = df.loc[idx, 'close']
        exit_price = df.loc[next_idx, 'close']
        direction = 1 if df.loc[idx, 'st_signal'] == 2 else -1
        pnl = (exit_price - entry) * direction
        bars = next_idx - idx
        trades.append({'pnl': pnl, 'direction': direction, 'bars': bars, 'entry': entry})

if trades:
    trades_df = pd.DataFrame(trades)
    winners = (trades_df['pnl'] > 0).sum()
    losers = (trades_df['pnl'] <= 0).sum()
    total = len(trades_df)
    win_rate = winners / total * 100
    avg_win = trades_df[trades_df['pnl'] > 0]['pnl'].mean()
    avg_loss = abs(trades_df[trades_df['pnl'] <= 0]['pnl'].mean())
    profit_factor = trades_df[trades_df['pnl'] > 0]['pnl'].sum() / abs(trades_df[trades_df['pnl'] <= 0]['pnl'].sum()) if losers > 0 else 0
    avg_bars = trades_df['bars'].mean()

    print(f"Ukupno trade-ova: {total}")
    print(f"Win rate: {win_rate:.1f}%")
    print(f"Prosječni win: {avg_win:.2f}")
    print(f"Prosječni loss: {avg_loss:.2f}")
    print(f"Profit factor: {profit_factor:.2f}")
    print(f"Prosj. trajanje: {avg_bars:.0f} barova ({avg_bars*5:.0f} min)")
print()

# ============================================================
# 12. SQUEEZE MOMENTUM SIMULATION
# ============================================================
print("=" * 80)
print("SQUEEZE MOMENTUM ANALIZA")
print("=" * 80)

# LinReg momentum calculation
length_kc = 20
df['hh'] = df['high'].rolling(length_kc).max()
df['ll'] = df['low'].rolling(length_kc).min()
df['sqz_val'] = df['close'] - ((df['hh'] + df['ll'])/2 + df['bb_mid'])/2

# Momentum direction
df['sqz_mom_up'] = (df['sqz_val'] > 0) & (df['sqz_val'] > df['sqz_val'].shift(1))
df['sqz_mom_dn'] = (df['sqz_val'] < 0) & (df['sqz_val'] < df['sqz_val'].shift(1))

# Squeeze + momentum release signal
df['sqz_buy'] = (df['squeeze'].shift(1) == True) & (df['squeeze'] == False) & (df['sqz_val'] > 0)
df['sqz_sell'] = (df['squeeze'].shift(1) == True) & (df['squeeze'] == False) & (df['sqz_val'] < 0)

sqz_buy_count = df['sqz_buy'].sum()
sqz_sell_count = df['sqz_sell'].sum()
print(f"Squeeze buy signali: {sqz_buy_count}")
print(f"Squeeze sell signali: {sqz_sell_count}")

# Forward returns after squeeze signals
def forward_analysis(df, signal_col, direction, fwd_bars=12):
    idx_list = df[df[signal_col] == True].index
    rets = []
    for idx in idx_list:
        if idx + fwd_bars < len(df):
            ret = (df.loc[idx + fwd_bars, 'close'] - df.loc[idx, 'close']) * direction
            rets.append(ret)
    if rets:
        rets = np.array(rets)
        win_rate = (rets > 0).mean() * 100
        avg_ret = rets.mean()
        return len(rets), win_rate, avg_ret
    return 0, 0, 0

n, wr, ar = forward_analysis(df, 'sqz_buy', 1, 12)
print(f"Squeeze buy -> 1h: {n} signala, winrate={wr:.1f}%, prosj={ar:.2f}")
n, wr, ar = forward_analysis(df, 'sqz_sell', -1, 12)
print(f"Squeeze sell -> 1h: {n} signala, winrate={wr:.1f}%, prosj={ar:.2f}")
print()

# ============================================================
# 13. UT BOT (ATR Trailing Stop) SIMULATION
# ============================================================
print("=" * 80)
print("UT BOT SIMULACIJA (key=1, ATR period=10)")
print("=" * 80)

key_value = 1
atr_period = 10

df['xatr'] = df['range'].rolling(atr_period).mean()
df['nloss'] = key_value * df['xatr']

trailing_stop = pd.Series(0.0, index=df.index)
pos = pd.Series(0, index=df.index)

for i in range(1, len(df)):
    if pd.isna(df['nloss'].iloc[i]):
        continue
    src = df['close'].iloc[i]
    src_prev = df['close'].iloc[i-1]
    prev_ts = trailing_stop.iloc[i-1]
    nl = df['nloss'].iloc[i]

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

df['ut_pos'] = pos
df['ut_buy'] = (pos == 1) & (pos.shift(1) != 1)
df['ut_sell'] = (pos == -1) & (pos.shift(1) != -1)

ut_buys = df['ut_buy'].sum()
ut_sells = df['ut_sell'].sum()
print(f"UT Buy signali: {ut_buys}")
print(f"UT Sell signali: {ut_sells}")

n, wr, ar = forward_analysis(df, 'ut_buy', 1, 12)
print(f"UT buy -> 1h: {n} signala, winrate={wr:.1f}%, prosj={ar:.2f}")
n, wr, ar = forward_analysis(df, 'ut_sell', -1, 12)
print(f"UT sell -> 1h: {n} signala, winrate={wr:.1f}%, prosj={ar:.2f}")
print()

# ============================================================
# 14. COMBINED SETUP ANALYSIS
# ============================================================
print("=" * 80)
print("KOMBINIRANI SETUP ANALIZA")
print("=" * 80)

# Setup 1: Squeeze Release + Supertrend alignment + Session filter
df['setup1_long'] = (df['sqz_buy'] == True) & (df['st_trend'] == 1) & \
                    (df['session'].isin(['London', 'NY_AM']))
df['setup1_short'] = (df['sqz_sell'] == True) & (df['st_trend'] == -1) & \
                     (df['session'].isin(['London', 'NY_AM']))

print("\nSetup 1: Squeeze Release + Supertrend + Sesija (London/NY AM)")
n, wr, ar = forward_analysis(df, 'setup1_long', 1, 12)
print(f"  Long: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")
n, wr, ar = forward_analysis(df, 'setup1_short', -1, 12)
print(f"  Short: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")

# Setup 2: UT Bot + Supertrend alignment + Volume above average
df['vol_above_avg'] = df['volume'] > df['volume'].rolling(50).mean()
df['setup2_long'] = (df['ut_buy'] == True) & (df['st_trend'] == 1) & (df['vol_above_avg'] == True)
df['setup2_short'] = (df['ut_sell'] == True) & (df['st_trend'] == -1) & (df['vol_above_avg'] == True)

print("\nSetup 2: UT Bot + Supertrend + Volume filter")
n, wr, ar = forward_analysis(df, 'setup2_long', 1, 12)
print(f"  Long: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")
n, wr, ar = forward_analysis(df, 'setup2_short', -1, 12)
print(f"  Short: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")

# Setup 3: Impulse + ATR expansion + Session
df['range_expansion'] = df['range'] > df['atr_20'] * 1.5
df['setup3_long'] = (df['impulsive'] == True) & (df['bullish'] == 1) & \
                    (df['st_trend'] == 1) & (df['session'].isin(['London', 'NY_AM']))
df['setup3_short'] = (df['impulsive'] == True) & (df['bearish'] == 1) & \
                     (df['st_trend'] == -1) & (df['session'].isin(['London', 'NY_AM']))

print("\nSetup 3: Impulse candle + Supertrend + Sesija")
n, wr, ar = forward_analysis(df, 'setup3_long', 1, 12)
print(f"  Long: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")
n, wr, ar = forward_analysis(df, 'setup3_short', -1, 12)
print(f"  Short: {n} signala, winrate={wr:.1f}%, prosj. pomak 1h={ar:.2f}")

# Multi-timeframe analysis for setups
for bars in [6, 12, 24, 48]:
    mins = bars * 5
    print(f"\n--- Forward analiza za {mins} min ---")
    for setup, name in [('setup1_long', 'S1 Long'), ('setup1_short', 'S1 Short'),
                         ('setup2_long', 'S2 Long'), ('setup2_short', 'S2 Short'),
                         ('setup3_long', 'S3 Long'), ('setup3_short', 'S3 Short')]:
        direction = 1 if 'long' in setup.lower() else -1
        n, wr, ar = forward_analysis(df, setup, direction, bars)
        if n > 0:
            print(f"  {name}: {n} signala, winrate={wr:.1f}%, prosj={ar:.2f}")

print()

# ============================================================
# 15. FULL BACKTEST - BEST SETUP
# ============================================================
print("=" * 80)
print("BACKTEST - SETUP 2 (UT Bot + Supertrend + Volume)")
print("=" * 80)

def backtest_setup(df, long_col, short_col, sl_atr_mult=1.5, tp_atr_mult=2.0, max_bars=48):
    """Simple backtest with ATR-based SL/TP."""
    trades = []
    in_trade = False

    for i in range(100, len(df)):
        if in_trade:
            continue

        if df[long_col].iloc[i]:
            entry = df['close'].iloc[i]
            sl = entry - sl_atr_mult * df['atr_20'].iloc[i]
            tp = entry + tp_atr_mult * df['atr_20'].iloc[i]

            for j in range(i+1, min(i+max_bars, len(df))):
                if df['low'].iloc[j] <= sl:
                    trades.append({'pnl': sl - entry, 'type': 'long', 'exit': 'SL', 'bars': j-i})
                    break
                elif df['high'].iloc[j] >= tp:
                    trades.append({'pnl': tp - entry, 'type': 'long', 'exit': 'TP', 'bars': j-i})
                    break
            else:
                # Time exit
                exit_price = df['close'].iloc[min(i+max_bars-1, len(df)-1)]
                trades.append({'pnl': exit_price - entry, 'type': 'long', 'exit': 'TIME', 'bars': max_bars})

        elif df[short_col].iloc[i]:
            entry = df['close'].iloc[i]
            sl = entry + sl_atr_mult * df['atr_20'].iloc[i]
            tp = entry - tp_atr_mult * df['atr_20'].iloc[i]

            for j in range(i+1, min(i+max_bars, len(df))):
                if df['high'].iloc[j] >= sl:
                    trades.append({'pnl': entry - sl, 'type': 'short', 'exit': 'SL', 'bars': j-i})
                    break
                elif df['low'].iloc[j] <= tp:
                    trades.append({'pnl': entry - tp, 'type': 'short', 'exit': 'TP', 'bars': j-i})
                    break
            else:
                exit_price = df['close'].iloc[min(i+max_bars-1, len(df)-1)]
                trades.append({'pnl': entry - exit_price, 'type': 'short', 'exit': 'TIME', 'bars': max_bars})

    return pd.DataFrame(trades)

# Backtest all setups
for setup_name, long_col, short_col in [
    ('Setup 1 (Squeeze+ST+Session)', 'setup1_long', 'setup1_short'),
    ('Setup 2 (UT+ST+Volume)', 'setup2_long', 'setup2_short'),
    ('Setup 3 (Impulse+ST+Session)', 'setup3_long', 'setup3_short')
]:
    bt = backtest_setup(df, long_col, short_col, sl_atr_mult=1.5, tp_atr_mult=2.5, max_bars=48)
    if len(bt) > 0:
        total = len(bt)
        winners = (bt['pnl'] > 0).sum()
        wr = winners / total * 100
        avg_win = bt[bt['pnl'] > 0]['pnl'].mean() if winners > 0 else 0
        avg_loss = abs(bt[bt['pnl'] <= 0]['pnl'].mean()) if (bt['pnl'] <= 0).sum() > 0 else 0
        pf = bt[bt['pnl'] > 0]['pnl'].sum() / abs(bt[bt['pnl'] <= 0]['pnl'].sum()) if (bt['pnl'] <= 0).sum() > 0 else 0
        total_pnl = bt['pnl'].sum()
        by_exit = bt.groupby('exit')['pnl'].agg(['count', 'mean']).round(2)
        avg_bars = bt['bars'].mean()

        print(f"\n{setup_name}:")
        print(f"  Trgovina: {total}")
        print(f"  Win rate: {wr:.1f}%")
        print(f"  Prosj. win: {avg_win:.2f}, Prosj. loss: {avg_loss:.2f}")
        print(f"  Profit factor: {pf:.2f}")
        print(f"  Ukupni P&L (pips): {total_pnl:.2f}")
        print(f"  Prosj. trajanje: {avg_bars:.0f} barova ({avg_bars*5:.0f} min)")
        print(f"  Po exit tipu:")
        print(f"  {by_exit.to_string()}")

print()
print("=" * 80)
print("ANALIZA ZAVRŠENA")
print("=" * 80)
