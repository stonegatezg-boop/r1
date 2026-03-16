#!/usr/bin/env python3
"""
Bounce EA - Kompletna analiza trejdova iz 12 MT5 backtest CSV fajlova
Cross-referenced s XAUUSD M5 cijenama
"""

import os
import csv
import re
from datetime import datetime, timedelta
from collections import defaultdict

# ============================================================
# 1. PARSIRANJE CSV FAJLOVA
# ============================================================

CSV_DIR = "/Users/matkosi/Repozitorij M7"
PRICE_FILE = "/Users/matkosi/Repozitorij M7/r1/xauusd_m5_3y.csv"

QUARTERS = {
    "Bounce 1.csv":   "Q1 2023",
    "Bounce 2.csv":   "Q2 2023",
    "Bounce 3.csv":   "Q3 2023",
    "Bounce 4.csv":   "Q4 2023",
    "Bounce 5.1.csv": "Q1 2024",
    "Bounce 6.csv":   "Q2 2024",
    "Bounce 7.csv":   "Q3 2024",
    "Bounce 8.csv":   "Q4 2024",
    "Bounce 9.csv":   "Q1 2025",
    "Bounce 10.csv":  "Q2 2025",
    "Bounce 11.csv":  "Q3 2025",
    "Bounce 12.csv":  "Q4 2025",
}

def parse_price(s, decimal_sep='.'):
    """Ukloni razmake iz broja i konvertuj u float."""
    if s is None:
        return 0.0
    s = s.strip().replace(' ', '').replace('\xa0', '')
    if s == '' or s == '-':
        return 0.0
    # Zamijeni europski decimalni separator ako je potrebno
    if decimal_sep == ',':
        s = s.replace(',', '.')
    try:
        return float(s)
    except:
        return 0.0

def detect_separator(filepath):
    """Detektuje separator fajla (comma ili semicolon)."""
    with open(filepath, 'r', encoding='utf-8-sig', errors='replace') as f:
        for line in f:
            if ';' in line:
                return ';', ','
            if ',' in line:
                return ',', '.'
    return ',', '.'

def parse_deals_from_file(filepath, quarter):
    """Parsira Deals sekciju iz MT5 backtest CSV fajla."""
    deals = []
    in_deals = False
    header_found = False

    sep, dec_sep = detect_separator(filepath)

    with open(filepath, 'r', encoding='utf-8-sig', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')

            # Detektuj Deals sekciju
            if not in_deals:
                if line.startswith('Deals'):
                    in_deals = True
                continue

            # Preskoči header red
            if not header_found:
                if 'Time' in line and 'Deal' in line:
                    header_found = True
                continue

            # Parsiramo deal redove
            parts = line.split(sep)
            if len(parts) < 12:
                continue

            time_str = parts[0].strip()
            deal_id  = parts[1].strip()
            symbol   = parts[2].strip()
            dtype    = parts[3].strip().lower()   # buy/sell/balance
            direction= parts[4].strip().lower()   # in/out
            volume   = parse_price(parts[5], dec_sep)
            price    = parse_price(parts[6], dec_sep)
            order    = parts[7].strip()
            commission= parse_price(parts[8], dec_sep)
            swap     = parse_price(parts[9], dec_sep)
            profit   = parse_price(parts[10], dec_sep)
            balance  = parse_price(parts[11], dec_sep)
            comment  = parts[12].strip() if len(parts) > 12 else ''

            # Preskoči balance i prazne redove
            if dtype == 'balance' or not deal_id:
                continue
            if direction not in ('in', 'out'):
                continue

            try:
                dt = datetime.strptime(time_str, '%Y.%m.%d %H:%M:%S')
            except:
                continue

            deals.append({
                'time': dt,
                'deal_id': deal_id,
                'symbol': symbol,
                'type': dtype,
                'direction': direction,
                'volume': volume,
                'price': price,
                'order': order,
                'profit': profit,
                'balance': balance,
                'comment': comment,
                'quarter': quarter,
                'file': os.path.basename(filepath),
            })

    return deals

def pair_deals_into_trades(deals):
    """Sparuje 'in' i 'out' dealove u kompletne trejdove."""
    trades = []
    open_trades = {}  # order -> deal_in

    for deal in deals:
        order = deal['order']
        if deal['direction'] == 'in':
            open_trades[order] = deal
        elif deal['direction'] == 'out':
            # Pronađi odgovarajući in deal
            in_deal = open_trades.pop(order, None)
            if in_deal is None:
                # Pokušaj pronaći po redoslijedu (fallback)
                if open_trades:
                    # Uzmi najstariji otvoreni
                    oldest_key = min(open_trades.keys(), key=lambda k: open_trades[k]['time'])
                    in_deal = open_trades.pop(oldest_key)
                else:
                    continue

            duration_sec = (deal['time'] - in_deal['time']).total_seconds()

            # Entry i exit cijena
            entry_price = in_deal['price']
            exit_price  = deal['price']

            # Smjer
            trade_dir = in_deal['type']  # 'buy' ili 'sell'

            # Profit (iz out deala)
            profit = deal['profit']

            # Pip movement (XAUUSD: 1 pip = 0.1)
            if trade_dir == 'buy':
                pips = (exit_price - entry_price) / 0.1
            else:
                pips = (entry_price - exit_price) / 0.1

            trades.append({
                'quarter': in_deal['quarter'],
                'file': in_deal['file'],
                'entry_time': in_deal['time'],
                'exit_time': deal['time'],
                'direction': trade_dir,
                'entry_price': entry_price,
                'exit_price': exit_price,
                'volume': in_deal['volume'],
                'profit': profit,
                'duration_sec': duration_sec,
                'comment_exit': deal['comment'],
                'pips': pips,
                'order': order,
            })

    return trades

# ============================================================
# 2. UČITAVANJE SVIH FAJLOVA
# ============================================================

print("=" * 70)
print("BOUNCE EA - KOMPLETNA ANALIZA TREJDOVA")
print("=" * 70)
print()

all_deals = []
for filename, quarter in QUARTERS.items():
    filepath = os.path.join(CSV_DIR, filename)
    if not os.path.exists(filepath):
        print(f"  [NIJE PRONAĐEN] {filepath}")
        continue
    deals = parse_deals_from_file(filepath, quarter)
    print(f"  {filename:25s} -> {quarter}: {len(deals):5d} dealova")
    all_deals.extend(deals)

print(f"\nUKUPNO DEALOVA: {len(all_deals)}")

# Grupiraj po fajlu za parovanje
deals_by_file = defaultdict(list)
for d in all_deals:
    deals_by_file[d['file']].append(d)

all_trades = []
for fname, deals in deals_by_file.items():
    trades = pair_deals_into_trades(deals)
    all_trades.extend(trades)

print(f"UKUPNO TREJDOVA (parovi): {len(all_trades)}")

# ============================================================
# 3. OSNOVNA STATISTIKA
# ============================================================

winning = [t for t in all_trades if t['profit'] > 0]
losing  = [t for t in all_trades if t['profit'] < 0]
breakeven = [t for t in all_trades if t['profit'] == 0]

print()
print("=" * 70)
print("3. OSNOVNA STATISTIKA")
print("=" * 70)
print(f"  Dobitni trejdovi:  {len(winning):5d}  ({100*len(winning)/len(all_trades):.1f}%)")
print(f"  Gubitni trejdovi:  {len(losing):5d}  ({100*len(losing)/len(all_trades):.1f}%)")
print(f"  Break-even:        {len(breakeven):5d}  ({100*len(breakeven)/len(all_trades):.1f}%)")
print(f"  Ukupni profit:     ${sum(t['profit'] for t in all_trades):.2f}")
print(f"  Gross profit:      ${sum(t['profit'] for t in winning):.2f}")
print(f"  Gross loss:        ${sum(t['profit'] for t in losing):.2f}")

# ============================================================
# 4. DISTRIBUCIJA TRAJANJA
# ============================================================

def classify_duration(sec):
    if sec <= 30:
        return "0-30s"
    elif sec <= 60:
        return "30-60s"
    elif sec <= 300:
        return "1-5min"
    elif sec <= 1800:
        return "5-30min"
    else:
        return "30min+"

def duration_histogram(trades, label):
    buckets = {"0-30s": 0, "30-60s": 0, "1-5min": 0, "5-30min": 0, "30min+": 0}
    for t in trades:
        b = classify_duration(t['duration_sec'])
        buckets[b] += 1
    total = len(trades)
    print(f"\n  {label} (ukupno: {total})")
    print(f"  {'Trajanje':<12} {'Broj':>6} {'%':>8} {'Bar':}")
    for k, v in buckets.items():
        pct = 100 * v / total if total else 0
        bar = '#' * int(pct / 2)
        print(f"  {k:<12} {v:>6} {pct:>7.1f}%  {bar}")

    # Prosječno trajanje
    if trades:
        avg_sec = sum(t['duration_sec'] for t in trades) / len(trades)
        med_trades = sorted(trades, key=lambda x: x['duration_sec'])
        med_sec = med_trades[len(med_trades)//2]['duration_sec']
        print(f"  Prosječno trajanje: {avg_sec:.0f}s ({timedelta(seconds=int(avg_sec))})")
        print(f"  Medijalno trajanje: {med_sec:.0f}s ({timedelta(seconds=int(med_sec))})")
    return buckets

print()
print("=" * 70)
print("4. DISTRIBUCIJA TRAJANJA TREJDOVA")
print("=" * 70)

win_buckets  = duration_histogram(winning, "DOBITNI TREJDOVI")
loss_buckets = duration_histogram(losing,  "GUBITNI TREJDOVI")

# % zatvorenih u prvih 60 sekundi
win_60s  = (win_buckets["0-30s"] + win_buckets["30-60s"])
loss_60s = (loss_buckets["0-30s"] + loss_buckets["30-60s"])
all_60s  = win_60s + loss_60s

print(f"\n  UKUPNO ZATVORENIH U PRVIH 60s: {all_60s}/{len(all_trades)} = {100*all_60s/len(all_trades):.1f}%")
print(f"  Dobitnih zatvorenih u 60s: {win_60s}/{len(winning)} = {100*win_60s/len(winning):.1f}%")
if losing:
    print(f"  Gubitnih zatvorenih u 60s: {loss_60s}/{len(losing)} = {100*loss_60s/len(losing):.1f}%")

# ============================================================
# 5. PROFIT PO KVARTALU
# ============================================================

print()
print("=" * 70)
print("5. PROFIT/GUBITAK PO KVARTALU")
print("=" * 70)
print(f"  {'Kvartal':<12} {'Trejdova':>9} {'Dobitnih':>10} {'Gubitnih':>10} {'Profit':>10} {'Avg/Trade':>10} {'Win%':>7}")

quarter_order = list(QUARTERS.values())
quarter_stats = defaultdict(lambda: {'trades': [], 'wins': 0, 'losses': 0, 'profit': 0.0})

for t in all_trades:
    q = t['quarter']
    quarter_stats[q]['trades'].append(t)
    quarter_stats[q]['profit'] += t['profit']
    if t['profit'] > 0:
        quarter_stats[q]['wins'] += 1
    elif t['profit'] < 0:
        quarter_stats[q]['losses'] += 1

for q in quarter_order:
    if q not in quarter_stats:
        continue
    s = quarter_stats[q]
    n = len(s['trades'])
    avg = s['profit'] / n if n else 0
    winpct = 100 * s['wins'] / n if n else 0
    print(f"  {q:<12} {n:>9} {s['wins']:>10} {s['losses']:>10} {s['profit']:>10.2f} {avg:>10.4f} {winpct:>6.1f}%")

# ============================================================
# 6. GUBITNI TREJDOVI - PIPS ANALIZA
# ============================================================

print()
print("=" * 70)
print("6. GUBITNI TREJDOVI - ANALIZA PIPA")
print("=" * 70)

if losing:
    pip_vals = [abs(t['pips']) for t in losing]
    avg_pip_loss = sum(pip_vals) / len(pip_vals)
    max_pip_loss = max(pip_vals)
    min_pip_loss = min(pip_vals)

    # Sortiranje po veličini gubitka
    sorted_losing = sorted(losing, key=lambda x: x['profit'])

    print(f"  Prosječni pips gubitak:  {avg_pip_loss:.1f} pipa")
    print(f"  Maksimalni pips gubitak: {max_pip_loss:.1f} pipa")
    print(f"  Minimalni pips gubitak:  {min_pip_loss:.1f} pipa")

    # Distribucija pip gubitaka
    print(f"\n  Distribucija pip gubitaka:")
    pip_buckets = {"<10": 0, "10-30": 0, "30-70": 0, "70-100": 0, "100+": 0}
    for pv in pip_vals:
        if pv < 10:    pip_buckets["<10"] += 1
        elif pv < 30:  pip_buckets["10-30"] += 1
        elif pv < 70:  pip_buckets["30-70"] += 1
        elif pv < 100: pip_buckets["70-100"] += 1
        else:          pip_buckets["100+"] += 1

    for k, v in pip_buckets.items():
        pct = 100 * v / len(losing)
        bar = '#' * int(pct / 2)
        print(f"  {k:<10} {v:>5} ({pct:>5.1f}%)  {bar}")

    # Top 10 najvećih gubitaka
    print(f"\n  TOP 10 NAJVEĆIH GUBITAKA:")
    print(f"  {'Datum entry':<22} {'Smjer':<6} {'Entry':>8} {'Exit':>8} {'Profit':>8} {'Pips':>8} {'Trajanje':<12} {'Komentar'}")
    for t in sorted_losing[:10]:
        dur = str(timedelta(seconds=int(t['duration_sec'])))
        print(f"  {str(t['entry_time']):<22} {t['direction']:<6} {t['entry_price']:>8.2f} {t['exit_price']:>8.2f} {t['profit']:>8.2f} {t['pips']:>8.1f} {dur:<12} {t['comment_exit']}")

# ============================================================
# 7. UČITAVANJE XAUUSD M5 CIJENA
# ============================================================

print()
print("=" * 70)
print("7. UČITAVANJE XAUUSD M5 CIJENA")
print("=" * 70)

price_data = {}  # (date, time) -> row

with open(PRICE_FILE, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            dt = datetime.strptime(f"{row['day']} {row['time']}", "%Y-%m-%d %H:%M")
            price_data[dt] = {
                'open':   float(row['open']),
                'close':  float(row['close']),
                'high':   float(row['high']),
                'low':    float(row['low']),
                'volume': float(row['volume']),
            }
        except:
            pass

print(f"  Učitano {len(price_data)} M5 svijeća")
print(f"  Raspon: {min(price_data.keys())} do {max(price_data.keys())}")

def get_candles_around(dt, before_min=30, after_min=30):
    """Dohvati M5 candles oko zadanog trenutka."""
    candles = []
    start = dt - timedelta(minutes=before_min)
    end   = dt + timedelta(minutes=after_min)
    t = start
    while t <= end:
        # Zaokruži na 5min
        t5 = t.replace(second=0, microsecond=0)
        t5 = t5 - timedelta(minutes=t5.minute % 5)
        if t5 in price_data:
            candles.append((t5, price_data[t5]))
        t += timedelta(minutes=5)
    return candles

def calc_volatility(candles):
    """ATR aproksimacija (high-low raspon) za niz svijeća."""
    if not candles:
        return 0
    ranges = [c['high'] - c['low'] for _, c in candles]
    return sum(ranges) / len(ranges)

def detect_trend(candles):
    """Jednostavna trend detekcija na osnovu prvih i zadnjih candles."""
    if len(candles) < 2:
        return "neutral"
    first_close = candles[0][1]['close']
    last_close  = candles[-1][1]['close']
    diff = last_close - first_close
    if diff > 2.0:
        return "BULLISH"
    elif diff < -2.0:
        return "BEARISH"
    else:
        return "SIDEWAYS"

# ============================================================
# 8. CROSS-REFERENCE: GUBITNI TREJDOVI vs TRŽIŠNE CIJENE
# ============================================================

print()
print("=" * 70)
print("8. CROSS-REFERENCE: 25 GUBITNIH TREJDOVA vs XAUUSD M5 TRŽIŠTE")
print("=" * 70)

# Filtriraj gubitne koji imaju cijene u bazi
losing_with_prices = []
for t in losing:
    entry_candles = get_candles_around(t['entry_time'], before_min=15, after_min=60)
    if entry_candles:
        losing_with_prices.append((t, entry_candles))

# Odaberi do 25 trejdova - raspoređenih po kvartalima
# Sortiramo po profitu (najgori prvi) pa uzimamo sample
sorted_losing_w_prices = sorted(losing_with_prices, key=lambda x: x[0]['profit'])

# Uzmi max 25, ali pokušaj pokriti sve kvartale
selected = []
per_quarter = defaultdict(list)
for item in sorted_losing_w_prices:
    per_quarter[item[0]['quarter']].append(item)

# Uzmi 2-3 po kvartalu
for q in quarter_order:
    items = per_quarter.get(q, [])
    selected.extend(items[:3])
    if len(selected) >= 25:
        break

if len(selected) < 25:
    # Dodaj još najgorih
    existing_keys = {id(s[0]) for s in selected}
    for item in sorted_losing_w_prices:
        if id(item[0]) not in existing_keys:
            selected.append(item)
            if len(selected) >= 25:
                break

selected = selected[:25]

print(f"\n  Analiziram {len(selected)} gubitnih trejdova...\n")

print(f"  {'#':<3} {'Kvartal':<10} {'Entry Time':<22} {'Dir':<5} {'EntryP':>7} {'ExitP':>7} "
      f"{'Profit':>8} {'Pips':>6} {'Trend':>10} {'Volatil':>9} {'Komentar'}")
print(f"  {'-'*3} {'-'*10} {'-'*22} {'-'*5} {'-'*7} {'-'*7} {'-'*8} {'-'*6} {'-'*10} {'-'*9} {'-'*20}")

market_context_details = []

for i, (t, candles) in enumerate(selected, 1):
    # Trend - gledamo 30min prije entry-a
    pre_candles  = [(dt, c) for dt, c in candles if dt < t['entry_time']]
    post_candles = [(dt, c) for dt, c in candles if dt >= t['entry_time']]

    trend     = detect_trend(pre_candles[-6:]) if len(pre_candles) >= 2 else "N/A"
    volatil   = calc_volatility(pre_candles[-6:])

    # Šta se događalo za vrijeme trejda
    trade_candles = [(dt, c) for dt, c in candles
                     if t['entry_time'] <= dt <= t['exit_time']]

    # Maksimalni adverse excursion (MAE) - koliko je cijena išla protiv nas
    if trade_candles:
        if t['direction'] == 'buy':
            worst_price = min(c['low'] for _, c in trade_candles)
            mae_pips = (t['entry_price'] - worst_price) / 0.1
        else:
            worst_price = max(c['high'] for _, c in trade_candles)
            mae_pips = (worst_price - t['entry_price']) / 0.1
    else:
        mae_pips = abs(t['pips'])

    market_context_details.append({
        'trade': t,
        'trend': trend,
        'volatility': volatil,
        'mae_pips': mae_pips,
        'pre_candles': pre_candles,
    })

    print(f"  {i:<3} {t['quarter']:<10} {str(t['entry_time']):<22} {t['direction']:<5} "
          f"{t['entry_price']:>7.2f} {t['exit_price']:>7.2f} {t['profit']:>8.2f} "
          f"{t['pips']:>6.1f} {trend:>10} {volatil:>9.2f} {t['comment_exit']}")

# ============================================================
# 9. DETALJNA ANALIZA TRŽIŠNOG KONTEKSTA
# ============================================================

print()
print("=" * 70)
print("9. DETALJNA ANALIZA TRŽIŠNOG KONTEKSTA ZA GUBITNE TREJDOVE")
print("=" * 70)

# Grupiranje po trendu
trend_groups = defaultdict(list)
for ctx in market_context_details:
    trend_groups[ctx['trend']].append(ctx)

print("\n  GUBICI PO TRŽIŠNOM TRENDU:")
for trend, items in sorted(trend_groups.items()):
    total_loss = sum(ctx['trade']['profit'] for ctx in items)
    avg_mae    = sum(ctx['mae_pips'] for ctx in items) / len(items)
    print(f"  {trend:<12}: {len(items):3d} trejdova, ukupni gubitak: ${total_loss:.2f}, prosječni MAE: {avg_mae:.1f} pipa")

# Volatilnost analiza
print("\n  VOLATILNOST U TRENUTKU GUBITNIH TREJDOVA:")
low_vol  = [ctx for ctx in market_context_details if ctx['volatility'] < 1.0]
med_vol  = [ctx for ctx in market_context_details if 1.0 <= ctx['volatility'] < 3.0]
high_vol = [ctx for ctx in market_context_details if ctx['volatility'] >= 3.0]

for label, items in [("Niska (<1.0 $)", low_vol), ("Srednja (1-3 $)", med_vol), ("Visoka (>3.0 $)", high_vol)]:
    if items:
        avg_loss = sum(ctx['trade']['profit'] for ctx in items) / len(items)
        print(f"  {label:<20}: {len(items):3d} trejdova, prosječni gubitak: ${avg_loss:.2f}")

# ============================================================
# 10. SMJER ANALIZA
# ============================================================

print()
print("=" * 70)
print("10. ANALIZA PO SMJERU TREJDA (BUY vs SELL)")
print("=" * 70)

for direction in ['buy', 'sell']:
    dir_trades = [t for t in all_trades if t['direction'] == direction]
    dir_win    = [t for t in dir_trades if t['profit'] > 0]
    dir_loss   = [t for t in dir_trades if t['profit'] < 0]

    if not dir_trades:
        continue

    total_profit = sum(t['profit'] for t in dir_trades)
    win_pct = 100 * len(dir_win) / len(dir_trades)
    avg_dur = sum(t['duration_sec'] for t in dir_trades) / len(dir_trades)

    print(f"\n  {direction.upper()}:")
    print(f"  Ukupno trejdova: {len(dir_trades)}")
    print(f"  Dobitnih: {len(dir_win)} ({win_pct:.1f}%)")
    print(f"  Gubitnih: {len(dir_loss)} ({100-win_pct:.1f}%)")
    print(f"  Ukupni profit: ${total_profit:.2f}")
    print(f"  Prosječno trajanje: {avg_dur:.0f}s")

# ============================================================
# 11. KOMENTAR ANALIZA - TRAILING STOP
# ============================================================

print()
print("=" * 70)
print("11. ANALIZA KOMENTARA PRI IZLASKU (Trailing SL)")
print("=" * 70)

comment_stats = defaultdict(lambda: {'count': 0, 'profit': 0.0})
for t in all_trades:
    # Klasifikuj komentar
    c = t['comment_exit'].lower()
    if c.startswith('sl '):
        comment_stats['Trailing SL']['count'] += 1
        comment_stats['Trailing SL']['profit'] += t['profit']
    elif 'tp' in c:
        comment_stats['Take Profit']['count'] += 1
        comment_stats['Take Profit']['profit'] += t['profit']
    elif c == '':
        comment_stats['Bez komentara']['count'] += 1
        comment_stats['Bez komentara']['profit'] += t['profit']
    else:
        comment_stats[f'Ostalo: {c[:20]}']['count'] += 1
        comment_stats[f'Ostalo: {c[:20]}']['profit'] += t['profit']

for label, stats in sorted(comment_stats.items(), key=lambda x: -x[1]['count']):
    avg = stats['profit'] / stats['count'] if stats['count'] else 0
    print(f"  {label:<30}: {stats['count']:5d} trejdova, ukupno: ${stats['profit']:9.2f}, prosjek: ${avg:.4f}")

# ============================================================
# 12. SAŽETAK
# ============================================================

print()
print("=" * 70)
print("12. FINALNI SAŽETAK")
print("=" * 70)

total_profit_all = sum(t['profit'] for t in all_trades)
all_60_count = sum(1 for t in all_trades
                   if classify_duration(t['duration_sec']) in ('0-30s', '30-60s'))

print(f"""
  UKUPNO TREJDOVA:      {len(all_trades)}
  DOBITNIH:             {len(winning)} ({100*len(winning)/len(all_trades):.1f}%)
  GUBITNIH:             {len(losing)} ({100*len(losing)/len(all_trades):.1f}%)
  BREAK-EVEN:           {len(breakeven)} ({100*len(breakeven)/len(all_trades):.1f}%)

  UKUPNI NETO PROFIT:   ${total_profit_all:.2f}
  GROSS PROFIT:         ${sum(t['profit'] for t in winning):.2f}
  GROSS LOSS:           ${sum(t['profit'] for t in losing):.2f}

  ZATVORENIH U 60s:     {all_60_count} ({100*all_60_count/len(all_trades):.1f}%)

  PROSJEČNI GUBITAK:    ${sum(t['profit'] for t in losing)/len(losing):.4f} (po trejdu) [{len(losing)} trejdova]
  PROSJEČNI DOBITAK:    ${sum(t['profit'] for t in winning)/len(winning):.4f} (po trejdu) [{len(winning)} trejdova]

  PROSJEČNI PIPS GUBITAK: {sum(abs(t['pips']) for t in losing)/len(losing):.1f} pipa
  PROSJEČNO TRAJANJE WIN:  {sum(t['duration_sec'] for t in winning)/len(winning):.0f}s
  PROSJEČNO TRAJANJE LOSS: {sum(t['duration_sec'] for t in losing)/len(losing):.0f}s
""")

print("=" * 70)
print("Analiza završena.")
print("=" * 70)
