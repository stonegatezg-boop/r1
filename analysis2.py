#!/usr/bin/env python3
"""
Part 2: Fixed Supertrend, deeper setup analysis, proper short-side testing
"""
import pandas as pd
import numpy as np
import warnings
warnings.filterwarnings('ignore')

df = pd.read_csv('/home/user/r1/xauusd_m5_3y.csv')
df['datetime'] = pd.to_datetime(df['day'] + ' ' + df['time'])
df = df.sort_values('datetime').reset_index(drop=True)

# Basic calculations
df['body'] = abs(df['close'] - df['open'])
df['range'] = df['high'] - df['low']
df['bullish'] = (df['close'] > df['open']).astype(int)
df['bearish'] = (df['close'] < df['open']).astype(int)
df['hour'] = df['datetime'].dt.hour
df['atr_20'] = df['range'].rolling(20).mean()
df['atr_50'] = df['range'].rolling(50).mean()
df['ret'] = df['close'].pct_change()

# Session classification
def classify_session(row):
    h, m = row['hour'], row['datetime'].minute
    t = h * 60 + m
    if 1200 <= t < 1440 or 0 <= t < 60:
        return 'Asia'
    elif 120 <= t < 300:
        return 'London'
    elif 570 <= t < 660:
        return 'NY_AM'
    elif 720 <= t < 780:
        return 'NY_Lunch'
    elif 810 <= t < 960:
        return 'NY_PM'
    else:
        return 'Other'
df['session'] = df.apply(classify_session, axis=1)
df['vol_above_avg'] = df['volume'] > df['volume'].rolling(50).mean()

# ============================================================
# FIXED SUPERTREND
# ============================================================
print("=" * 80)
print("SUPERTREND FIKSIRAN (ATR=10, mult=3)")
print("=" * 80)

period = 10
multiplier = 3.0

atr = df['range'].ewm(span=period, adjust=False).mean()
hl2 = (df['high'] + df['low']) / 2
basic_upper = hl2 + multiplier * atr
basic_lower = hl2 - multiplier * atr

final_upper = basic_upper.copy()
final_lower = basic_lower.copy()
st = pd.Series(1, index=df.index)

for i in range(1, len(df)):
    # Final lower band
    if basic_lower.iloc[i] > final_lower.iloc[i-1]:
        final_lower.iloc[i] = basic_lower.iloc[i]
    elif df['close'].iloc[i-1] > final_lower.iloc[i-1]:
        final_lower.iloc[i] = final_lower.iloc[i-1]
    else:
        final_lower.iloc[i] = basic_lower.iloc[i]

    # Final upper band
    if basic_upper.iloc[i] < final_upper.iloc[i-1]:
        final_upper.iloc[i] = basic_upper.iloc[i]
    elif df['close'].iloc[i-1] < final_upper.iloc[i-1]:
        final_upper.iloc[i] = final_upper.iloc[i-1]
    else:
        final_upper.iloc[i] = basic_upper.iloc[i]

    # Trend
    prev_st = st.iloc[i-1]
    if prev_st == 1:
        if df['close'].iloc[i] < final_lower.iloc[i]:
            st.iloc[i] = -1
        else:
            st.iloc[i] = 1
    else:
        if df['close'].iloc[i] > final_upper.iloc[i]:
            st.iloc[i] = 1
        else:
            st.iloc[i] = -1

df['st'] = st
df['st_buy'] = (st == 1) & (st.shift(1) == -1)
df['st_sell'] = (st == -1) & (st.shift(1) == 1)

buys = df['st_buy'].sum()
sells = df['st_sell'].sum()
bull_pct = (st == 1).mean() * 100
print(f"ST Buy signali: {buys}")
print(f"ST Sell signali: {sells}")
print(f"Vrijeme u bullish trendu: {bull_pct:.1f}%")
print(f"Vrijeme u bearish trendu: {100-bull_pct:.1f}%")

# ============================================================
# SUPERTREND TRADE RESULTS
# ============================================================
st_signals = df[(df['st_buy'] == True) | (df['st_sell'] == True)].index.tolist()
trades = []
for i in range(len(st_signals) - 1):
    idx = st_signals[i]
    next_idx = st_signals[i+1]
    entry = df.loc[idx, 'close']
    exit_p = df.loc[next_idx, 'close']
    direction = 1 if df.loc[idx, 'st_buy'] else -1
    pnl = (exit_p - entry) * direction
    bars = next_idx - idx
    trades.append({'pnl': pnl, 'dir': direction, 'bars': bars})

if trades:
    tdf = pd.DataFrame(trades)
    total = len(tdf)
    wr = (tdf['pnl'] > 0).mean() * 100
    avg_w = tdf[tdf['pnl'] > 0]['pnl'].mean()
    avg_l = abs(tdf[tdf['pnl'] <= 0]['pnl'].mean()) if (tdf['pnl'] <= 0).any() else 0
    pf = tdf[tdf['pnl'] > 0]['pnl'].sum() / abs(tdf[tdf['pnl'] <= 0]['pnl'].sum()) if (tdf['pnl'] <= 0).any() else float('inf')
    avg_bars = tdf['bars'].mean()
    print(f"\nSupertrend trade rezultati:")
    print(f"  Ukupno: {total}, WinRate: {wr:.1f}%")
    print(f"  Avg Win: {avg_w:.2f}, Avg Loss: {avg_l:.2f}")
    print(f"  Profit Factor: {pf:.2f}")
    print(f"  Prosj. trajanje: {avg_bars:.0f} barova ({avg_bars*5/60:.1f}h)")
    print(f"  Ukupni PnL: {tdf['pnl'].sum():.2f}")

    # Long vs Short
    longs = tdf[tdf['dir'] == 1]
    shorts = tdf[tdf['dir'] == -1]
    if len(longs) > 0:
        print(f"\n  Long ({len(longs)}): WR={( longs['pnl']>0).mean()*100:.1f}%, PF={longs[longs['pnl']>0]['pnl'].sum()/abs(longs[longs['pnl']<=0]['pnl'].sum()) if (longs['pnl']<=0).any() else 0:.2f}")
    if len(shorts) > 0:
        print(f"  Short ({len(shorts)}): WR={(shorts['pnl']>0).mean()*100:.1f}%, PF={shorts[shorts['pnl']>0]['pnl'].sum()/abs(shorts[shorts['pnl']<=0]['pnl'].sum()) if (shorts['pnl']<=0).any() else 0:.2f}")

print()

# ============================================================
# UT BOT
# ============================================================
key_value = 1
atr_period = 10
xatr = df['range'].rolling(atr_period).mean()
nloss = key_value * xatr

trailing_stop = pd.Series(0.0, index=df.index)
ut_pos = pd.Series(0, index=df.index)

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
        ut_pos.iloc[i] = 1
    elif src_prev > prev_ts and src < prev_ts:
        ut_pos.iloc[i] = -1
    else:
        ut_pos.iloc[i] = ut_pos.iloc[i-1]

df['ut_pos'] = ut_pos
df['ut_buy'] = (ut_pos == 1) & (ut_pos.shift(1) != 1)
df['ut_sell'] = (ut_pos == -1) & (ut_pos.shift(1) != -1)

# ============================================================
# Squeeze
# ============================================================
bb_mid = df['close'].rolling(20).mean()
bb_std = df['close'].rolling(20).std()
kc_range = df['range'].rolling(20).mean()
kc_upper = bb_mid + 1.5 * kc_range
kc_lower = bb_mid - 1.5 * kc_range
df['squeeze'] = ((bb_mid - bb_std) > kc_lower) & ((bb_mid + bb_std) < kc_upper)
df['squeeze_release'] = (df['squeeze'].shift(1) == True) & (df['squeeze'] == False)

# Momentum
hh = df['high'].rolling(20).max()
ll = df['low'].rolling(20).min()
df['sqz_val'] = df['close'] - ((hh + ll)/2 + bb_mid)/2
df['sqz_buy'] = (df['squeeze_release'] == True) & (df['sqz_val'] > 0)
df['sqz_sell'] = (df['squeeze_release'] == True) & (df['sqz_val'] < 0)

# Impulsive
df['body_range_ratio'] = df['body'] / df['range'].replace(0, np.nan)
df['impulsive'] = (df['body_range_ratio'] > 0.6) & (df['range'] > df['atr_20'] * 1.2)

# ============================================================
# COMBINED SETUPS WITH FIXED SUPERTREND
# ============================================================
print("=" * 80)
print("KOMBINIRANI SETUPI (popravljen Supertrend)")
print("=" * 80)

def forward_analysis(df, signal_col, direction, fwd_bars=12):
    idx_list = df[df[signal_col] == True].index
    rets = []
    for idx in idx_list:
        if idx + fwd_bars < len(df):
            ret = (df.loc[idx + fwd_bars, 'close'] - df.loc[idx, 'close']) * direction
            rets.append(ret)
    if rets:
        rets = np.array(rets)
        return len(rets), (rets > 0).mean() * 100, rets.mean()
    return 0, 0, 0

# Setup 1: Squeeze + ST + Session
df['s1_long'] = (df['sqz_buy']) & (df['st'] == 1) & (df['session'].isin(['London', 'NY_AM', 'NY_PM']))
df['s1_short'] = (df['sqz_sell']) & (df['st'] == -1) & (df['session'].isin(['London', 'NY_AM', 'NY_PM']))

# Setup 2: UT Bot + ST + Volume
df['s2_long'] = (df['ut_buy']) & (df['st'] == 1) & (df['vol_above_avg'])
df['s2_short'] = (df['ut_sell']) & (df['st'] == -1) & (df['vol_above_avg'])

# Setup 3: Impulse + ST + Session
df['s3_long'] = (df['impulsive']) & (df['bullish'] == 1) & (df['st'] == 1) & (df['session'].isin(['London', 'NY_AM', 'NY_PM']))
df['s3_short'] = (df['impulsive']) & (df['bearish'] == 1) & (df['st'] == -1) & (df['session'].isin(['London', 'NY_AM', 'NY_PM']))

# Setup 4: UT Bot crossover during squeeze release (confluence)
df['s4_long'] = (df['ut_buy']) & (df['squeeze'].shift(5) == True) & (df['st'] == 1)
df['s4_short'] = (df['ut_sell']) & (df['squeeze'].shift(5) == True) & (df['st'] == -1)

# Setup 5: Pure UT Bot + Session (no ST filter)
df['s5_long'] = (df['ut_buy']) & (df['session'].isin(['London', 'NY_AM', 'NY_PM'])) & (df['vol_above_avg'])
df['s5_short'] = (df['ut_sell']) & (df['session'].isin(['London', 'NY_AM', 'NY_PM'])) & (df['vol_above_avg'])

setups = [
    ('S1: Squeeze+ST+Session', 's1_long', 's1_short'),
    ('S2: UT+ST+Volume', 's2_long', 's2_short'),
    ('S3: Impulse+ST+Session', 's3_long', 's3_short'),
    ('S4: UT+SqzRelease+ST', 's4_long', 's4_short'),
    ('S5: UT+Session+Volume', 's5_long', 's5_short'),
]

for name, long_col, short_col in setups:
    print(f"\n{name}:")
    for fwd in [6, 12, 24]:
        mins = fwd * 5
        nl, wrl, arl = forward_analysis(df, long_col, 1, fwd)
        ns, wrs, ars = forward_analysis(df, short_col, -1, fwd)
        print(f"  {mins}min -> Long: {nl} sig, WR={wrl:.1f}%, avg={arl:.2f} | Short: {ns} sig, WR={wrs:.1f}%, avg={ars:.2f}")

# ============================================================
# FULL BACKTEST WITH SL/TP
# ============================================================
print()
print("=" * 80)
print("BACKTEST SA SL/TP (SL=1.5*ATR, TP=2.5*ATR, max 48 barova)")
print("=" * 80)

def backtest(df, long_col, short_col, sl_mult=1.5, tp_mult=2.5, max_bars=48):
    trades = []
    cooldown = 0
    for i in range(100, len(df)):
        if cooldown > 0:
            cooldown -= 1
            continue

        atr = df['atr_20'].iloc[i]
        if pd.isna(atr) or atr == 0:
            continue

        is_long = df[long_col].iloc[i]
        is_short = df[short_col].iloc[i]

        if not is_long and not is_short:
            continue

        entry = df['close'].iloc[i]
        direction = 1 if is_long else -1
        sl_dist = sl_mult * atr
        tp_dist = tp_mult * atr

        sl = entry - sl_dist * direction
        tp = entry + tp_dist * direction

        exit_type = 'TIME'
        exit_bar = min(i + max_bars, len(df) - 1)
        pnl = 0

        for j in range(i + 1, min(i + max_bars + 1, len(df))):
            if direction == 1:
                if df['low'].iloc[j] <= sl:
                    pnl = -sl_dist
                    exit_type = 'SL'
                    exit_bar = j
                    break
                if df['high'].iloc[j] >= tp:
                    pnl = tp_dist
                    exit_type = 'TP'
                    exit_bar = j
                    break
            else:
                if df['high'].iloc[j] >= sl:
                    pnl = -sl_dist
                    exit_type = 'SL'
                    exit_bar = j
                    break
                if df['low'].iloc[j] <= tp:
                    pnl = tp_dist
                    exit_type = 'TP'
                    exit_bar = j
                    break
        else:
            pnl = (df['close'].iloc[exit_bar] - entry) * direction

        cooldown = exit_bar - i
        trades.append({
            'pnl': pnl, 'dir': direction, 'exit': exit_type,
            'bars': exit_bar - i, 'entry_price': entry, 'atr': atr
        })

    return pd.DataFrame(trades) if trades else pd.DataFrame()

for name, long_col, short_col in setups:
    bt = backtest(df, long_col, short_col)
    if len(bt) == 0:
        print(f"\n{name}: Nema trgovina")
        continue

    total = len(bt)
    wr = (bt['pnl'] > 0).mean() * 100
    avg_w = bt[bt['pnl'] > 0]['pnl'].mean() if (bt['pnl'] > 0).any() else 0
    avg_l = abs(bt[bt['pnl'] <= 0]['pnl'].mean()) if (bt['pnl'] <= 0).any() else 0
    pf = bt[bt['pnl'] > 0]['pnl'].sum() / abs(bt[bt['pnl'] <= 0]['pnl'].sum()) if (bt['pnl'] <= 0).any() else 0
    total_pnl = bt['pnl'].sum()
    avg_bars = bt['bars'].mean()
    expectancy = bt['pnl'].mean()

    # Risk-adjusted (per-trade risk = 1 ATR unit)
    risk_reward = avg_w / avg_l if avg_l > 0 else 0

    print(f"\n{name}:")
    print(f"  Trgovina: {total}")
    print(f"  Win Rate: {wr:.1f}%")
    print(f"  Avg Win: {avg_w:.2f}, Avg Loss: {avg_l:.2f}, R:R = {risk_reward:.2f}")
    print(f"  Profit Factor: {pf:.2f}")
    print(f"  Expectancy/trade: {expectancy:.2f}")
    print(f"  Ukupni PnL: {total_pnl:.2f}")
    print(f"  Prosj. trajanje: {avg_bars:.0f} barova ({avg_bars*5:.0f} min)")

    # Long vs Short breakdown
    longs = bt[bt['dir'] == 1]
    shorts = bt[bt['dir'] == -1]
    if len(longs) > 0:
        l_wr = (longs['pnl'] > 0).mean() * 100
        l_pf = longs[longs['pnl'] > 0]['pnl'].sum() / abs(longs[longs['pnl'] <= 0]['pnl'].sum()) if (longs['pnl'] <= 0).any() else 0
        print(f"  Long  ({len(longs)}): WR={l_wr:.1f}%, PF={l_pf:.2f}, PnL={longs['pnl'].sum():.2f}")
    if len(shorts) > 0:
        s_wr = (shorts['pnl'] > 0).mean() * 100
        s_pf = shorts[shorts['pnl'] > 0]['pnl'].sum() / abs(shorts[shorts['pnl'] <= 0]['pnl'].sum()) if (shorts['pnl'] <= 0).any() else 0
        print(f"  Short ({len(shorts)}): WR={s_wr:.1f}%, PF={s_pf:.2f}, PnL={shorts['pnl'].sum():.2f}")

    by_exit = bt.groupby('exit').agg(count=('pnl', 'count'), avg_pnl=('pnl', 'mean'), total_pnl=('pnl', 'sum')).round(2)
    print(f"  Exit breakdown:\n{by_exit.to_string()}")

# ============================================================
# YEARLY BREAKDOWN FOR BEST SETUP
# ============================================================
print()
print("=" * 80)
print("GODIŠNJA ANALIZA - Setup 3 (Impulse+ST+Session)")
print("=" * 80)

bt = backtest(df, 's3_long', 's3_short')
if len(bt) > 0:
    # Map trade indices back to dates
    signal_indices = []
    cooldown = 0
    for i in range(100, len(df)):
        if cooldown > 0:
            cooldown -= 1
            continue
        if df['s3_long'].iloc[i] or df['s3_short'].iloc[i]:
            signal_indices.append(i)
            # find exit bar
            atr = df['atr_20'].iloc[i]
            entry = df['close'].iloc[i]
            direction = 1 if df['s3_long'].iloc[i] else -1
            exit_bar = i
            for j in range(i+1, min(i+49, len(df))):
                if direction == 1:
                    if df['low'].iloc[j] <= entry - 1.5*atr or df['high'].iloc[j] >= entry + 2.5*atr:
                        exit_bar = j
                        break
                else:
                    if df['high'].iloc[j] >= entry + 1.5*atr or df['low'].iloc[j] <= entry - 2.5*atr:
                        exit_bar = j
                        break
            else:
                exit_bar = min(i+48, len(df)-1)
            cooldown = exit_bar - i

    if len(signal_indices) == len(bt):
        bt['date'] = [df['datetime'].iloc[idx] for idx in signal_indices]
        bt['year'] = bt['date'].dt.year
        yearly = bt.groupby('year').agg(
            trades=('pnl', 'count'),
            win_rate=('pnl', lambda x: (x > 0).mean() * 100),
            total_pnl=('pnl', 'sum'),
            avg_pnl=('pnl', 'mean')
        ).round(2)
        print(yearly.to_string())

# ============================================================
# OPTIMAL SL/TP SEARCH
# ============================================================
print()
print("=" * 80)
print("OPTIMIZACIJA SL/TP - Setup 3")
print("=" * 80)

best_pf = 0
best_params = (0, 0)
results = []

for sl in [1.0, 1.5, 2.0]:
    for tp in [1.5, 2.0, 2.5, 3.0, 4.0]:
        bt = backtest(df, 's3_long', 's3_short', sl_mult=sl, tp_mult=tp, max_bars=48)
        if len(bt) > 0 and (bt['pnl'] <= 0).any():
            wr = (bt['pnl'] > 0).mean() * 100
            pf = bt[bt['pnl'] > 0]['pnl'].sum() / abs(bt[bt['pnl'] <= 0]['pnl'].sum())
            total_pnl = bt['pnl'].sum()
            exp = bt['pnl'].mean()
            results.append({'SL': sl, 'TP': tp, 'Trades': len(bt), 'WR': wr, 'PF': pf, 'PnL': total_pnl, 'Exp': exp})
            if pf > best_pf:
                best_pf = pf
                best_params = (sl, tp)

if results:
    rdf = pd.DataFrame(results).round(2)
    print(rdf.to_string(index=False))
    print(f"\nNajbolji parametri: SL={best_params[0]}*ATR, TP={best_params[1]}*ATR, PF={best_pf:.2f}")

# ============================================================
# FILTER: AVOID BAD CONDITIONS
# ============================================================
print()
print("=" * 80)
print("FILTER LOŠIH UVJETA")
print("=" * 80)

# Test: filter out low volatility
df['s3f_long'] = df['s3_long'] & (df['atr_20'] > df['atr_50'])
df['s3f_short'] = df['s3_short'] & (df['atr_20'] > df['atr_50'])

bt_filtered = backtest(df, 's3f_long', 's3f_short')
if len(bt_filtered) > 0:
    wr = (bt_filtered['pnl'] > 0).mean() * 100
    pf = bt_filtered[bt_filtered['pnl'] > 0]['pnl'].sum() / abs(bt_filtered[bt_filtered['pnl'] <= 0]['pnl'].sum()) if (bt_filtered['pnl'] <= 0).any() else 0
    print(f"S3 + ATR filter (ATR20 > ATR50):")
    print(f"  Trades: {len(bt_filtered)}, WR: {wr:.1f}%, PF: {pf:.2f}, PnL: {bt_filtered['pnl'].sum():.2f}")

# Filter: only trade during high-volume hours
df['high_vol_hour'] = df['hour'].isin([15, 16, 17, 18])
df['s3h_long'] = df['s3_long'] & df['high_vol_hour']
df['s3h_short'] = df['s3_short'] & df['high_vol_hour']

bt_hvol = backtest(df, 's3h_long', 's3h_short')
if len(bt_hvol) > 0:
    wr = (bt_hvol['pnl'] > 0).mean() * 100
    pf = bt_hvol[bt_hvol['pnl'] > 0]['pnl'].sum() / abs(bt_hvol[bt_hvol['pnl'] <= 0]['pnl'].sum()) if (bt_hvol['pnl'] <= 0).any() else 0
    print(f"\nS3 + Peak hours (15-18 UTC):")
    print(f"  Trades: {len(bt_hvol)}, WR: {wr:.1f}%, PF: {pf:.2f}, PnL: {bt_hvol['pnl'].sum():.2f}")

# Filter: avoid Monday and Friday
df['mid_week'] = df['datetime'].dt.dayofweek.isin([1, 2, 3])
df['s3m_long'] = df['s3_long'] & df['mid_week']
df['s3m_short'] = df['s3_short'] & df['mid_week']

bt_mid = backtest(df, 's3m_long', 's3m_short')
if len(bt_mid) > 0:
    wr = (bt_mid['pnl'] > 0).mean() * 100
    pf = bt_mid[bt_mid['pnl'] > 0]['pnl'].sum() / abs(bt_mid[bt_mid['pnl'] <= 0]['pnl'].sum()) if (bt_mid['pnl'] <= 0).any() else 0
    print(f"\nS3 + Mid-week (Uto-Čet):")
    print(f"  Trades: {len(bt_mid)}, WR: {wr:.1f}%, PF: {pf:.2f}, PnL: {bt_mid['pnl'].sum():.2f}")

# Combined: best filters
df['s3best_long'] = df['s3_long'] & (df['atr_20'] > df['atr_50']) & df['vol_above_avg']
df['s3best_short'] = df['s3_short'] & (df['atr_20'] > df['atr_50']) & df['vol_above_avg']

bt_best = backtest(df, 's3best_long', 's3best_short')
if len(bt_best) > 0:
    wr = (bt_best['pnl'] > 0).mean() * 100
    pf = bt_best[bt_best['pnl'] > 0]['pnl'].sum() / abs(bt_best[bt_best['pnl'] <= 0]['pnl'].sum()) if (bt_best['pnl'] <= 0).any() else 0
    exp = bt_best['pnl'].mean()
    print(f"\nS3 + ATR filter + Volume filter:")
    print(f"  Trades: {len(bt_best)}, WR: {wr:.1f}%, PF: {pf:.2f}, PnL: {bt_best['pnl'].sum():.2f}, Exp: {exp:.2f}")
    longs = bt_best[bt_best['dir'] == 1]
    shorts = bt_best[bt_best['dir'] == -1]
    if len(longs) > 0:
        print(f"  Longs: {len(longs)}, PnL: {longs['pnl'].sum():.2f}")
    if len(shorts) > 0:
        print(f"  Shorts: {len(shorts)}, PnL: {shorts['pnl'].sum():.2f}")

print()
print("=" * 80)
print("ANALIZA 2 ZAVRŠENA")
print("=" * 80)
