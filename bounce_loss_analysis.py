import csv
import re
from datetime import datetime, timedelta
from collections import defaultdict

# Fajlovi
files = {
    'Q1 2023': '/Users/matkosi/Repozitorij M7/Bounce 1.csv',
    'Q2 2023': '/Users/matkosi/Repozitorij M7/Bounce 2.csv',
    'Q3 2023': '/Users/matkosi/Repozitorij M7/Bounce 3.csv',
    'Q4 2023': '/Users/matkosi/Repozitorij M7/Bounce 4.csv',
    'Q1 2024': '/Users/matkosi/Repozitorij M7/Bounce 5.1.csv',
    'Q2 2024': '/Users/matkosi/Repozitorij M7/Bounce 6.csv',
    'Q3 2024': '/Users/matkosi/Repozitorij M7/Bounce 7.csv',
    'Q4 2024': '/Users/matkosi/Repozitorij M7/Bounce 8.csv',
    'Q1 2025': '/Users/matkosi/Repozitorij M7/Bounce 9.csv',
    'Q2 2025': '/Users/matkosi/Repozitorij M7/Bounce 10.csv',
    'Q3 2025': '/Users/matkosi/Repozitorij M7/Bounce 11.csv',
    'Q4 2025': '/Users/matkosi/Repozitorij M7/Bounce 12.csv',
}

def parse_num(s):
    if not s or s.strip() == '': return 0.0
    s = s.strip().replace('\xa0', '').replace(' ', '')
    s = s.replace(',', '.')
    s = s.replace('--', '-')
    try: return float(s)
    except: return 0.0

def parse_deals(filepath):
    deals = []
    in_deals = False
    # Detect separator
    with open(filepath, 'r', encoding='utf-8-sig', errors='replace') as f:
        first_line = f.readline()
    sep = ';' if ';' in first_line else ','
    
    with open(filepath, 'r', encoding='utf-8-sig', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not in_deals:
                if line.startswith('Deals') or line.startswith('Deals;') or line.startswith('Deals,'):
                    in_deals = True
                continue
            parts = line.split(sep)
            if len(parts) < 8: continue
            time_str = parts[0].strip()
            if not time_str or time_str == 'Time': continue
            try:
                dt = datetime.strptime(time_str, '%Y.%m.%d %H:%M:%S')
            except:
                continue
            direction = parts[4].strip() if len(parts) > 4 else ''
            trade_type = parts[3].strip() if len(parts) > 3 else ''
            if direction not in ('in', 'out'): continue
            symbol = parts[2].strip()
            volume = parse_num(parts[5]) if len(parts) > 5 else 0
            price = parse_num(parts[6]) if len(parts) > 6 else 0
            profit = parse_num(parts[10]) if len(parts) > 10 else 0
            comment = parts[12].strip() if len(parts) > 12 else ''
            deals.append({
                'time': dt, 'type': trade_type, 'direction': direction,
                'symbol': symbol, 'volume': volume, 'price': price,
                'profit': profit, 'comment': comment
            })
    return deals

def build_trades(deals):
    trades = []
    open_pos = None
    for d in deals:
        if d['direction'] == 'in':
            open_pos = d
        elif d['direction'] == 'out' and open_pos:
            duration = (d['time'] - open_pos['time']).total_seconds()
            trades.append({
                'entry_time': open_pos['time'],
                'exit_time': d['time'],
                'direction': open_pos['type'],
                'entry_price': open_pos['price'],
                'exit_price': d['price'],
                'profit': d['profit'],
                'duration': duration,
                'comment': d['comment']
            })
            open_pos = None
    return trades

# Load XAUUSD candles
print("Učitavam XAUUSD cijene...")
candles = []
with open('/Users/matkosi/Repozitorij M7/r1/xauusd_m5_3y.csv', 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            dt = datetime.strptime(row['day'] + ' ' + row['time'], '%Y-%m-%d %H:%M')
            candles.append({
                'time': dt,
                'open': float(row['open']),
                'close': float(row['close']),
                'high': float(row['high']),
                'low': float(row['low']),
            })
        except: pass
candles.sort(key=lambda x: x['time'])
candle_index = {c['time']: i for i, c in enumerate(candles)}
print(f"Candles: {len(candles)}, od {candles[0]['time']} do {candles[-1]['time']}")

def get_candle_idx(dt):
    # Round down to nearest 5-min bar
    rounded = dt.replace(second=0, microsecond=0)
    minutes = (rounded.minute // 5) * 5
    rounded = rounded.replace(minute=minutes)
    return candle_index.get(rounded, None)

def get_trend(idx, n=12):
    if idx is None or idx < n: return 'unknown'
    closes = [candles[idx-i]['close'] for i in range(n, 0, -1)]
    slope = closes[-1] - closes[0]
    if slope > 0.5: return 'bullish'
    elif slope < -0.5: return 'bearish'
    return 'sideways'

def get_atr(idx, n=14):
    if idx is None or idx < n+1: return 0
    trs = []
    for i in range(n):
        c = candles[idx-i]
        prev_close = candles[idx-i-1]['close']
        tr = max(c['high']-c['low'], abs(c['high']-prev_close), abs(c['low']-prev_close))
        trs.append(tr)
    return sum(trs)/len(trs)

# Parse all trades
all_trades = []
losing_trades = []
quarter_stats = {}

for quarter, filepath in files.items():
    deals = parse_deals(filepath)
    trades = build_trades(deals)
    all_trades.extend(trades)
    losses = [t for t in trades if t['profit'] < -0.01]
    quarter_stats[quarter] = {
        'total': len(trades),
        'losses': len(losses),
        'loss_amount': sum(t['profit'] for t in losses),
        'total_profit': sum(t['profit'] for t in trades)
    }
    for t in losses:
        t['quarter'] = quarter
        losing_trades.append(t)

print(f"\nUkupno trejdova: {len(all_trades)}")
print(f"Gubitnih: {len(losing_trades)}")

# Cross-reference with candles
hour_count = defaultdict(int)
day_count = defaultdict(int)
trend_count = defaultdict(int)
trade_vs_trend = defaultdict(int)  # 'with'/'against'
atr_buckets = defaultdict(int)
duration_buckets = defaultdict(int)

days = ['Pon', 'Uto', 'Sri', 'Čet', 'Pet', 'Sub', 'Ned']

for t in losing_trades:
    hour_count[t['entry_time'].hour] += 1
    day_count[days[t['entry_time'].weekday()]] += 1
    
    idx = get_candle_idx(t['entry_time'])
    trend_1h = get_trend(idx, 12)
    trend_15m = get_trend(idx, 3)
    atr = get_atr(idx, 14)
    
    trend_count[trend_1h] += 1
    
    # Je li trejd u smjeru ili protiv 1h trenda
    is_buy = 'buy' in t['direction'].lower()
    if trend_1h == 'bullish':
        trade_vs_trend['buy_in_bull' if is_buy else 'sell_in_bull'] += 1
    elif trend_1h == 'bearish':
        trade_vs_trend['sell_in_bear' if not is_buy else 'buy_in_bear'] += 1
    else:
        trade_vs_trend['sideways'] += 1
    
    if atr < 0.3: atr_buckets['nizak (<0.3)'] += 1
    elif atr < 0.8: atr_buckets['srednji (0.3-0.8)'] += 1
    else: atr_buckets['visok (>0.8)'] += 1
    
    dur = t['duration']
    if dur < 60: duration_buckets['<1 min'] += 1
    elif dur < 300: duration_buckets['1-5 min'] += 1
    elif dur < 1800: duration_buckets['5-30 min'] += 1
    elif dur < 7200: duration_buckets['30min-2h'] += 1
    else: duration_buckets['>2h'] += 1

print("\n" + "="*60)
print("GUBITNI TREJDOVI — PO KVARTALIMA")
print("="*60)
for q, s in quarter_stats.items():
    if s['losses'] > 0:
        print(f"{q}: {s['losses']} gubitaka, ukupno {s['loss_amount']:.2f}$, profit kvartala: {s['total_profit']:.2f}$")

print("\n" + "="*60)
print("PO SATU ULASKA (top 5)")
print("="*60)
for h, c in sorted(hour_count.items(), key=lambda x: -x[1])[:10]:
    print(f"  {h:02d}:00 — {c} gubitaka")

print("\n" + "="*60)
print("PO DANU U TJEDNU")
print("="*60)
for d, c in sorted(day_count.items(), key=lambda x: -x[1]):
    print(f"  {d}: {c} gubitaka")

print("\n" + "="*60)
print("TREND 1H U MOMENTU ENTRYA")
print("="*60)
for tr, c in sorted(trend_count.items(), key=lambda x: -x[1]):
    print(f"  {tr}: {c} gubitaka")

print("\n" + "="*60)
print("SMJER TREJDA vs TREND")
print("="*60)
for k, c in sorted(trade_vs_trend.items(), key=lambda x: -x[1]):
    print(f"  {k}: {c}")

print("\n" + "="*60)
print("ATR KOD GUBITNIH ENTRYA")
print("="*60)
for b, c in sorted(atr_buckets.items(), key=lambda x: -x[1]):
    print(f"  {b}: {c}")

print("\n" + "="*60)
print("TRAJANJE GUBITNIH TREJDOVA")
print("="*60)
for b, c in sorted(duration_buckets.items(), key=lambda x: -x[1]):
    print(f"  {b}: {c}")

print("\n" + "="*60)
print("NAJGORI TREJDOVI (top 10)")
print("="*60)
worst = sorted(losing_trades, key=lambda x: x['profit'])[:10]
for t in worst:
    idx = get_candle_idx(t['entry_time'])
    trend = get_trend(idx, 12)
    atr = get_atr(idx, 14)
    print(f"  {t['entry_time']} | {t['direction']:4s} | {t['profit']:.2f}$ | {int(t['duration']//60)}min | trend:{trend} | ATR:{atr:.2f}")
