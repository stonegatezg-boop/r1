#!/usr/bin/env python3
"""Extract and categorize all indicators from Indikatori file"""
import re

with open('/home/user/r1/Indikatori', 'r') as f:
    content = f.read()

# Split by ... separator
sections = re.split(r'\n\.\.\.\n', content)

indicators = []

for i, section in enumerate(sections):
    if not section.strip():
        continue

    # Find indicator/study/strategy declaration
    match = re.search(r'(indicator|study|strategy)\s*\([^)]*["\']([^"\']+)["\']', section, re.IGNORECASE)
    if match:
        ind_type = match.group(1)
        name = match.group(2)
    else:
        # Try to find title in different format
        match2 = re.search(r'title\s*=\s*["\']([^"\']+)["\']', section, re.IGNORECASE)
        if match2:
            name = match2.group(1)
            ind_type = 'unknown'
        else:
            continue

    # Check for overlay
    overlay = 'overlay=true' in section.lower() or 'overlay = true' in section.lower()

    # Check for potential repainting issues
    repaints = []
    if 'lookahead' in section.lower() and 'lookahead_on' in section.lower():
        repaints.append('lookahead_on')
    if re.search(r'security\s*\(', section, re.IGNORECASE):
        repaints.append('security()')
    if 'barstate.isrealtime' in section.lower():
        repaints.append('realtime_check')
    if 'barstate.islast' in section.lower():
        repaints.append('last_bar')

    # Categorize
    name_lower = name.lower()
    section_lower = section.lower()

    if any(x in name_lower for x in ['smc', 'smart money', 'order block', 'ob', 'fvg', 'fair value', 'bos', 'choch', 'liquidity', 'ict']):
        category = 'SMC/Structure'
    elif any(x in name_lower for x in ['support', 'resistance', 's&r', 'sr', 'pivot', 'level']):
        category = 'S/R'
    elif any(x in name_lower for x in ['trend', 'supertrend', 'ma', 'moving average', 'ema', 'sma', 'hull', 'ribbon']):
        category = 'Trend'
    elif any(x in name_lower for x in ['rsi', 'macd', 'stoch', 'momentum', 'cci', 'oscillator', 'wave']):
        category = 'Momentum'
    elif any(x in name_lower for x in ['volume', 'vwap', 'obv', 'vfi']):
        category = 'Volume'
    elif any(x in name_lower for x in ['atr', 'bollinger', 'bb', 'keltner', 'squeeze', 'volatility', 'vix', 'envelope']):
        category = 'Volatility'
    elif any(x in name_lower for x in ['session', 'killzone', 'time', 'market hour']):
        category = 'Session'
    elif any(x in name_lower for x in ['pattern', 'candle', 'candlestick', 'doji', 'engulf']):
        category = 'Pattern'
    elif any(x in name_lower for x in ['channel', 'breakout', 'break']):
        category = 'Breakout'
    elif any(x in name_lower for x in ['divergence', 'div']):
        category = 'Divergence'
    elif any(x in name_lower for x in ['fibonacci', 'fib', 'elliott', 'wave']):
        category = 'Fibonacci/Wave'
    elif any(x in name_lower for x in ['ichimoku', 'cloud']):
        category = 'Ichimoku'
    elif any(x in name_lower for x in ['zigzag', 'swing']):
        category = 'Swing'
    elif 'strategy' in ind_type.lower():
        category = 'Strategy'
    elif any(x in name_lower for x in ['machine learning', 'ml', 'ai', 'adaptive']):
        category = 'ML/AI'
    else:
        category = 'Other'

    # Extract key inputs
    inputs = re.findall(r'input\s*\(\s*(\d+)', section)[:5]  # First 5 numeric inputs
    inputs_str = ','.join(inputs) if inputs else '-'

    # Check for specific useful indicators
    has_alerts = 'alertcondition' in section.lower()
    has_signals = any(x in section_lower for x in ['buy', 'sell', 'long', 'short', 'signal'])

    indicators.append({
        'idx': len(indicators) + 1,
        'name': name[:60],
        'type': ind_type,
        'category': category,
        'overlay': overlay,
        'repaints': repaints,
        'has_alerts': has_alerts,
        'has_signals': has_signals,
        'inputs': inputs_str,
        'lines': len(section.split('\n'))
    })

# Print summary
print("=" * 120)
print(f"UKUPNO INDIKATORA: {len(indicators)}")
print("=" * 120)

# By category
print("\nPO KATEGORIJI:")
from collections import Counter
cats = Counter(ind['category'] for ind in indicators)
for cat, count in cats.most_common():
    print(f"  {cat}: {count}")

print("\n" + "=" * 120)
print("KOMPLETNA LISTA INDIKATORA")
print("=" * 120)
print(f"{'#':>3} {'Naziv':<55} {'Kategorija':<15} {'Overlay':<8} {'Signali':<8} {'Repaint rizik':<20}")
print("-" * 120)

for ind in indicators:
    repaint_str = ','.join(ind['repaints']) if ind['repaints'] else 'OK'
    print(f"{ind['idx']:>3} {ind['name']:<55} {ind['category']:<15} {'Da' if ind['overlay'] else 'Ne':<8} {'Da' if ind['has_signals'] else 'Ne':<8} {repaint_str:<20}")

# Filter EA-suitable
print("\n" + "=" * 120)
print("EA-PRIKLADNI INDIKATORI (ne repaintaju, imaju signale, overlay ili oscillator)")
print("=" * 120)

ea_suitable = []
for ind in indicators:
    # Kriteriji: nema lookahead_on, ima signale ili alert
    if 'lookahead_on' not in ind['repaints']:
        if ind['has_signals'] or ind['has_alerts']:
            ea_suitable.append(ind)

print(f"\nUkupno EA-prikladnih: {len(ea_suitable)}\n")
for ind in ea_suitable:
    repaint_str = ','.join(ind['repaints']) if ind['repaints'] else 'ČISTO'
    print(f"{ind['idx']:>3}. {ind['name']:<55} [{ind['category']}] - {repaint_str}")

# Group by usefulness for M5 scalping
print("\n" + "=" * 120)
print("PREPORUKA ZA M5 SCALPING - TOP KANDIDATI")
print("=" * 120)

m5_priority = []
for ind in ea_suitable:
    score = 0
    name_l = ind['name'].lower()

    # Bonus za trend following
    if ind['category'] == 'Trend': score += 3
    if 'supertrend' in name_l: score += 5
    if 'ut bot' in name_l: score += 4

    # Bonus za volatility
    if ind['category'] == 'Volatility': score += 3
    if 'squeeze' in name_l: score += 5
    if 'atr' in name_l: score += 2

    # Bonus za momentum
    if ind['category'] == 'Momentum': score += 2
    if 'macd' in name_l: score += 2

    # Bonus za session
    if ind['category'] == 'Session': score += 3
    if 'killzone' in name_l: score += 4

    # Bonus za breakout
    if ind['category'] == 'Breakout': score += 2

    # Malus za SMC (subjektivno)
    if ind['category'] == 'SMC/Structure': score -= 2

    # Malus za ML (kompleksno)
    if ind['category'] == 'ML/AI': score -= 1

    # Bonus ako nema nikakvih repaint rizika
    if not ind['repaints']: score += 2

    m5_priority.append((score, ind))

m5_priority.sort(key=lambda x: -x[0])

print("\nTOP 30 za M5:\n")
for score, ind in m5_priority[:30]:
    repaint_str = ','.join(ind['repaints']) if ind['repaints'] else 'ČISTO'
    print(f"  [{score:>2}] {ind['name']:<55} ({ind['category']}) - {repaint_str}")
