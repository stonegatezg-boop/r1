#!/usr/bin/env python3
"""Clean indicator extraction"""

# From grep output - all 106 indicators with line numbers
raw_indicators = """
5:Smart Money Concepts [LuxAlgo]
860:Squeeze Momentum Indicator [LazyBear]
912:CM_MacD_Ult_MTF
964:Supertrend
1006:CM_Williams_Vix_Fix
1046:WaveTrend [LazyBear]
1082:Support and Resistance Levels with Breaks [LuxAlgo]
1120:Market Structure Break & Order Block (MSB-OB)
1332:ADX and DI for v4
1364:Bollinger + RSI Double Strategy [ChartArt]
1451:Trendlines with Breaks [LuxAlgo]
1550:UT Bot Alerts
1600:ICT Killzones & Pivots [TFO]
2328:Support Resistance Channels
2527:CM_Ultimate_MA_MTF_V2
2624:TMA Overlay
2806:CM_Ultimate_MA_MTF
2877:Candlestick Patterns Identified
2957:Fibonacci Bollinger Bands
3016:Order Block Finder
3200:Machine Learning: Lorentzian Classification
3768:Nadaraya-Watson Envelope [LuxAlgo]
3890:Order Block Detector [LuxAlgo]
4128:Support and Resistance High Volume Boxes [ChartPrime]
4338:CM_SlingShotSystem
4387:MACD + SMA 200 Strategy [ChartArt]
4496:Madrid Moving Average Ribbon
4640:Divergence for Many Indicators v4
5055:Liquidity Swings [LuxAlgo]
5282:Sessions [LuxAlgo]
5915:CM_Price-Action-Bars
5966:Machine Learning Adaptive SuperTrend [AlgoAlpha]
6137:Pivot Point SuperTrend
6212:Support Resistance - Dynamic v2
6369:AlphaTrend
6427:Chandelier Exit
6491:Breakout Finder
6605:Trend Lines v2
6735:Volume Flow Indicator [LazyBear]
6774:SuperTrend AI (Clustering) [LuxAlgo]
7046:CM_Pivot Points_M-W-D_4H_1H_Filtered
7178:CM_RSI_2_Strat_Low
7206:Super OrderBlock / FVG / BoS Tools [makuchaku & eFe]
7506:Order Blocks & Breaker Blocks [LuxAlgo]
7723:Volume-based Support & Resistance Zones V2
8642:SuperTrend STRATEGY
8702:ICT Concepts [LuxAlgo]
9883:VuManChu B Divergences (VMC Cipher_B)
10377:CM_Stochastic_MTF
10450:Breakout Probability (Expo)
10652:RSI Chart Bars
10674:Buyside & Sellside Liquidity [LuxAlgo]
11031:Bjorgum Key Levels
11681:WaveTrend with Crosses [LazyBear]
11719:CM_Ultimate RSI MTF
11771:EMA 20/50/100/200
11792:DIY Custom Strategy Builder [ZP]
16289:Price Action - Support & Resistance [DGT]
16769:Smart Money Breakout Channels [AlgoAlpha]
17086:Hull Suite [InSilico]
17143:Scalping PullBack Tool [JustUncleL]
17391:Optimized Trend Tracker (OTT)
17511:MACD 4 Colour
17532:Pivot Points High Low & Missed Reversal Levels [LuxAlgo]
17716:Auto Chart Patterns [Trendoscope]
17981:Tony's EMA Scalper - Buy/Sell
18014:Volumized Order Blocks [Flux Charts]
18475:Fair Value Gap [LuxAlgo]
18704:Weis Wave Volume [LazyBear]
18722:Volume Profile Free Ultra SLI [RRB]
21122:Supply and Demand Visible Range [LuxAlgo]
21313:Turtle Trade Channels Indicator
21378:Volume Profile / Fixed Range
21500:Ichimoku2c
21521:Moving Average Cross Alert MTF [ChartArt]
21610:Swing Highs/Lows & Candle Patterns [LuxAlgo]
21720:Profit Maximizer (PMax)
21824:VDUB_BINARY_PRO_3_V2
21930:ICT Killzones Toolkit [LuxAlgo]
22640:Volume Profile
22891:BigBeluga - Smart Money Concepts
24567:Market sessions and Volume profile [Leviathan]
24976:RSI Divergence
25001:Divergence for many indicator v3
25355:Support and Resistance Signals MTF [LuxAlgo]
26050:PMax Explorer
26382:Linear Regression Channel
26453:Linear Regression Channel v2
26550:Opening Range with Breakouts & Targets [LuxAlgo]
26869:Smart Money Concept [TradingFinder] OB + FVG (SMC)
28478:Volume Profile v2
28729:CM_Parabolic SAR
28763:Hash Ribbons (Capriole Investments)
28892:Hash Ribbons v2
29034:ZigZag++
29113:CM_RSI_EMA
29135:CM_Laguerre PPO PercentileRank
29205:Volume Profile and Indicator [DGT]
29773:Supertrend Explorer
30072:Trendline Breakouts With Targets [Chartprime]
30352:CM_Enhanced_Ichimoku Cloud-V5
30416:Support Resistance Interactive
30505:SSL Hybrid
30901:Elliott Wave [LuxAlgo]
31429:On Balance Volume Oscillator [LazyBear]
31450:FVG Order Blocks [BigBeluga]
""".strip().split('\n')

# Parse and categorize
indicators = []
for line in raw_indicators:
    if ':' not in line:
        continue
    parts = line.split(':', 1)
    line_num = int(parts[0])
    name = parts[1].strip()

    name_l = name.lower()

    # Category
    if any(x in name_l for x in ['smc', 'smart money', 'order block', 'ob', 'fvg', 'fair value', 'liquidity', 'ict', 'bos', 'choch', 'breaker']):
        cat = 'SMC/Structure'
    elif any(x in name_l for x in ['support', 'resistance', 's&r', 'sr', 'pivot', 'level', 'key level']):
        cat = 'S/R Levels'
    elif any(x in name_l for x in ['supertrend', 'trend line', 'trendline', 'alpha', 'hull', 'ema', 'sma', 'ma ', 'moving average', 'ribbon', 'ott', 'pmax', 'ssl']):
        cat = 'Trend Following'
    elif any(x in name_l for x in ['squeeze', 'bollinger', 'bb', 'keltner', 'atr', 'chandelier', 'envelope', 'nadaraya']):
        cat = 'Volatility'
    elif any(x in name_l for x in ['rsi', 'macd', 'stoch', 'momentum', 'wave', 'cci', 'laguerre']):
        cat = 'Momentum/Oscillator'
    elif any(x in name_l for x in ['volume', 'obv', 'vfi', 'weis', 'vwap']):
        cat = 'Volume'
    elif any(x in name_l for x in ['session', 'killzone', 'opening range']):
        cat = 'Session/Time'
    elif any(x in name_l for x in ['pattern', 'candle', 'candlestick', 'price action', 'swing']):
        cat = 'Patterns'
    elif any(x in name_l for x in ['divergence', 'div']):
        cat = 'Divergence'
    elif any(x in name_l for x in ['breakout', 'break']):
        cat = 'Breakout'
    elif any(x in name_l for x in ['fibonacci', 'fib', 'elliott', 'zigzag']):
        cat = 'Fib/Wave'
    elif any(x in name_l for x in ['ichimoku']):
        cat = 'Ichimoku'
    elif any(x in name_l for x in ['machine learning', 'ml', 'ai', 'lorentzian']):
        cat = 'ML/AI'
    elif 'strategy' in name_l:
        cat = 'Strategy'
    elif any(x in name_l for x in ['hash', 'bitcoin', 'crypto']):
        cat = 'Crypto-specific'
    else:
        cat = 'Other'

    # EA suitability assessment
    # Repainting risk based on typical indicator behavior
    repaint_risk = 'LOW'
    if any(x in name_l for x in ['order block', 'ob', 'fvg', 'smc', 'smart money', 'zigzag', 'swing', 'pivot']):
        repaint_risk = 'HIGH'  # These typically repaint zones
    elif any(x in name_l for x in ['machine learning', 'ml', 'ai', 'lorentzian', 'nadaraya']):
        repaint_risk = 'MEDIUM'  # ML can have lookback issues
    elif any(x in name_l for x in ['divergence']):
        repaint_risk = 'HIGH'  # Divergences need confirmation
    elif any(x in name_l for x in ['pattern', 'elliott']):
        repaint_risk = 'HIGH'  # Pattern detection often repaints
    elif any(x in name_l for x in ['trendline']):
        repaint_risk = 'MEDIUM'  # Depends on implementation

    # M5 scalping score
    score = 0

    # Good for M5
    if 'supertrend' in name_l: score += 10
    if 'ut bot' in name_l: score += 10
    if 'squeeze' in name_l: score += 9
    if 'session' in name_l or 'killzone' in name_l: score += 8
    if 'atr' in name_l or 'chandelier' in name_l: score += 7
    if 'breakout' in name_l: score += 6
    if 'ema' in name_l or 'sma' in name_l: score += 5
    if 'macd' in name_l: score += 5
    if 'rsi' in name_l: score += 4
    if 'stoch' in name_l: score += 4
    if 'hull' in name_l: score += 6
    if 'ssl' in name_l: score += 6
    if 'ott' in name_l or 'pmax' in name_l: score += 7
    if 'alpha' in name_l: score += 6
    if 'scalp' in name_l: score += 8
    if 'volume' in name_l and 'profile' not in name_l: score += 5

    # Penalty for things that don't work well on M5
    if repaint_risk == 'HIGH': score -= 5
    if repaint_risk == 'MEDIUM': score -= 2
    if 'daily' in name_l or 'weekly' in name_l: score -= 4
    if 'profile' in name_l: score -= 3  # Volume profile needs higher TF
    if 'elliott' in name_l: score -= 5  # Too subjective
    if 'ichimoku' in name_l: score -= 3  # Designed for daily
    if 'hash' in name_l or 'bitcoin' in name_l: score -= 10  # Not for gold
    if 'divergence' in name_l: score -= 3  # Lags too much for M5

    indicators.append({
        'line': line_num,
        'name': name,
        'category': cat,
        'repaint': repaint_risk,
        'score': score
    })

# Sort by score
indicators.sort(key=lambda x: -x['score'])

print("=" * 100)
print(f"SVIH {len(indicators)} INDIKATORA - SORTIRANIH PO M5 PRIKLADNOSTI")
print("=" * 100)
print(f"{'#':>3} {'Score':>5} {'Repaint':>7} {'Kategorija':<18} {'Naziv':<50}")
print("-" * 100)

for i, ind in enumerate(indicators, 1):
    print(f"{i:>3} {ind['score']:>5} {ind['repaint']:>7} {ind['category']:<18} {ind['name'][:50]:<50}")

print("\n" + "=" * 100)
print("PREPORUKA ZA M5 XAUUSD - TOP 25 KANDIDATA")
print("=" * 100)

# Group by category for top scorers
from collections import defaultdict
by_cat = defaultdict(list)
for ind in indicators[:35]:  # Top 35
    by_cat[ind['category']].append(ind)

for cat in ['Trend Following', 'Volatility', 'Session/Time', 'Momentum/Oscillator', 'Breakout', 'Volume']:
    if cat in by_cat:
        print(f"\n{cat}:")
        for ind in by_cat[cat][:5]:
            print(f"  [{ind['score']:>2}] {ind['name']:<50} (repaint: {ind['repaint']})")

print("\n" + "=" * 100)
print("INDIKATORI KOJI NE REPAINTAJU (LOW RISK) - ZA EA")
print("=" * 100)
no_repaint = [ind for ind in indicators if ind['repaint'] == 'LOW' and ind['score'] > 0]
print(f"\nUkupno: {len(no_repaint)}\n")
for ind in no_repaint[:30]:
    print(f"  [{ind['score']:>2}] {ind['name']:<50} ({ind['category']})")

print("\n" + "=" * 100)
print("IZBJEGAVATI ZA M5 EA (HIGH REPAINT RISK)")
print("=" * 100)
high_repaint = [ind for ind in indicators if ind['repaint'] == 'HIGH']
print(f"\nUkupno: {len(high_repaint)}\n")
for ind in high_repaint:
    print(f"  {ind['name']:<50} ({ind['category']})")
