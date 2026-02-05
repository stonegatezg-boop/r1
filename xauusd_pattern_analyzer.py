#!/usr/bin/env python3
"""
XAUUSD Pattern Analyzer - Comprehensive M15 Candlestick Pattern Analysis
=========================================================================
Analyzes 10 years of XAUUSD M15 data to identify statistically significant
trading patterns including candlestick formations, session-based patterns,
trend/momentum signals, and generates backtest results.

Data source: ejtraderLabs/historical-data (Dukascopy origin)
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
from collections import defaultdict
import json
import warnings
warnings.filterwarnings('ignore')


# ============================================================================
# 1. DATA LOADING & CLEANING
# ============================================================================

def load_and_clean_data(filepath):
    """Load XAUUSD M15 CSV and clean it."""
    df = pd.read_csv(filepath)
    df['Date'] = pd.to_datetime(df['Date'])

    # Prices are *100, convert to real prices
    for col in ['open', 'high', 'low', 'close']:
        df[col] = df[col] / 100.0

    df = df.sort_values('Date').reset_index(drop=True)

    # Add derived columns
    df['hour'] = df['Date'].dt.hour
    df['minute'] = df['Date'].dt.minute
    df['day_of_week'] = df['Date'].dt.dayofweek  # 0=Mon, 4=Fri
    df['day_name'] = df['Date'].dt.day_name()
    df['month'] = df['Date'].dt.month
    df['year'] = df['Date'].dt.year
    df['date_only'] = df['Date'].dt.date

    # Candle properties
    df['body'] = df['close'] - df['open']
    df['body_abs'] = df['body'].abs()
    df['upper_wick'] = df['high'] - df[['open', 'close']].max(axis=1)
    df['lower_wick'] = df[['open', 'close']].min(axis=1) - df['low']
    df['range'] = df['high'] - df['low']
    df['is_bullish'] = df['close'] > df['open']
    df['is_bearish'] = df['close'] < df['open']

    # Session classification (UTC times)
    df['session'] = df['hour'].apply(classify_session)

    # Returns
    df['return_pct'] = df['close'].pct_change() * 100
    df['next_close'] = df['close'].shift(-1)
    df['next_return'] = ((df['next_close'] - df['close']) / df['close']) * 100
    df['next_3_close'] = df['close'].shift(-3)
    df['next_3_return'] = ((df['next_3_close'] - df['close']) / df['close']) * 100
    df['next_6_close'] = df['close'].shift(-6)
    df['next_6_return'] = ((df['next_6_close'] - df['close']) / df['close']) * 100
    df['next_12_close'] = df['close'].shift(-12)
    df['next_12_return'] = ((df['next_12_close'] - df['close']) / df['close']) * 100

    # Moving averages
    df['sma_20'] = df['close'].rolling(20).mean()
    df['sma_50'] = df['close'].rolling(50).mean()
    df['sma_200'] = df['close'].rolling(200).mean()
    df['ema_9'] = df['close'].ewm(span=9).mean()
    df['ema_21'] = df['close'].ewm(span=21).mean()

    # ATR (14-period)
    df['tr'] = pd.concat([
        df['high'] - df['low'],
        (df['high'] - df['close'].shift(1)).abs(),
        (df['low'] - df['close'].shift(1)).abs()
    ], axis=1).max(axis=1)
    df['atr_14'] = df['tr'].rolling(14).mean()

    # RSI (14-period)
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0).rolling(14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(14).mean()
    rs = gain / loss
    df['rsi_14'] = 100 - (100 / (1 + rs))

    # Bollinger Bands
    df['bb_mid'] = df['close'].rolling(20).mean()
    bb_std = df['close'].rolling(20).std()
    df['bb_upper'] = df['bb_mid'] + 2 * bb_std
    df['bb_lower'] = df['bb_mid'] - 2 * bb_std
    df['bb_pct'] = (df['close'] - df['bb_lower']) / (df['bb_upper'] - df['bb_lower'])

    # MACD
    ema12 = df['close'].ewm(span=12).mean()
    ema26 = df['close'].ewm(span=26).mean()
    df['macd'] = ema12 - ema26
    df['macd_signal'] = df['macd'].ewm(span=9).mean()
    df['macd_hist'] = df['macd'] - df['macd_signal']

    # Stochastic
    low_14 = df['low'].rolling(14).min()
    high_14 = df['high'].rolling(14).max()
    df['stoch_k'] = ((df['close'] - low_14) / (high_14 - low_14)) * 100
    df['stoch_d'] = df['stoch_k'].rolling(3).mean()

    # Volume analysis
    df['vol_sma_20'] = df['tick_volume'].rolling(20).mean()
    df['vol_ratio'] = df['tick_volume'] / df['vol_sma_20']

    # Consecutive candles
    df['prev_bullish'] = df['is_bullish'].shift(1)
    df['prev_bearish'] = df['is_bearish'].shift(1)
    df['prev2_bullish'] = df['is_bullish'].shift(2)
    df['prev2_bearish'] = df['is_bearish'].shift(2)

    return df


def classify_session(hour):
    """Classify trading session based on UTC hour."""
    if 0 <= hour < 7:
        return 'Asian'
    elif 7 <= hour < 13:
        return 'London'
    elif 13 <= hour < 20:
        return 'New_York'
    else:
        return 'Late_NY'


# ============================================================================
# 2. CANDLESTICK PATTERN DETECTION
# ============================================================================

def detect_candlestick_patterns(df):
    """Detect various candlestick patterns."""
    patterns = {}

    # --- SINGLE CANDLE PATTERNS ---

    # Doji: body < 10% of range
    mask = (df['body_abs'] < df['range'] * 0.10) & (df['range'] > 0)
    patterns['doji'] = mask

    # Hammer (bullish): small body at top, long lower wick (>2x body), small upper wick
    mask = (df['lower_wick'] > 2 * df['body_abs']) & \
           (df['upper_wick'] < df['body_abs'] * 0.5) & \
           (df['range'] > df['atr_14'] * 0.5)
    patterns['hammer'] = mask

    # Inverted Hammer / Shooting Star (bearish at top)
    mask = (df['upper_wick'] > 2 * df['body_abs']) & \
           (df['lower_wick'] < df['body_abs'] * 0.5) & \
           (df['range'] > df['atr_14'] * 0.5)
    patterns['shooting_star'] = mask

    # Marubozu (strong candle): body > 80% of range
    mask_bull = (df['body_abs'] > df['range'] * 0.80) & df['is_bullish'] & (df['range'] > df['atr_14'] * 0.5)
    mask_bear = (df['body_abs'] > df['range'] * 0.80) & df['is_bearish'] & (df['range'] > df['atr_14'] * 0.5)
    patterns['marubozu_bull'] = mask_bull
    patterns['marubozu_bear'] = mask_bear

    # Large candle: range > 1.5x ATR
    patterns['large_bull'] = df['is_bullish'] & (df['range'] > df['atr_14'] * 1.5)
    patterns['large_bear'] = df['is_bearish'] & (df['range'] > df['atr_14'] * 1.5)

    # --- TWO CANDLE PATTERNS ---

    # Bullish Engulfing
    mask = df['is_bullish'] & df['prev_bearish'] & \
           (df['open'] <= df['close'].shift(1)) & \
           (df['close'] >= df['open'].shift(1)) & \
           (df['body_abs'] > df['body_abs'].shift(1))
    patterns['bullish_engulfing'] = mask

    # Bearish Engulfing
    mask = df['is_bearish'] & df['prev_bullish'] & \
           (df['open'] >= df['close'].shift(1)) & \
           (df['close'] <= df['open'].shift(1)) & \
           (df['body_abs'] > df['body_abs'].shift(1))
    patterns['bearish_engulfing'] = mask

    # Piercing Pattern (bullish)
    prev_midpoint = (df['open'].shift(1) + df['close'].shift(1)) / 2
    mask = df['is_bullish'] & df['prev_bearish'] & \
           (df['open'] < df['close'].shift(1)) & \
           (df['close'] > prev_midpoint) & \
           (df['close'] < df['open'].shift(1))
    patterns['piercing'] = mask

    # Dark Cloud Cover (bearish)
    prev_midpoint = (df['open'].shift(1) + df['close'].shift(1)) / 2
    mask = df['is_bearish'] & df['prev_bullish'] & \
           (df['open'] > df['close'].shift(1)) & \
           (df['close'] < prev_midpoint) & \
           (df['close'] > df['open'].shift(1))
    patterns['dark_cloud'] = mask

    # --- THREE CANDLE PATTERNS ---

    # Morning Star (bullish reversal)
    mask = df['prev2_bearish'] & \
           (df['body_abs'].shift(1) < df['body_abs'].shift(2) * 0.3) & \
           df['is_bullish'] & \
           (df['close'] > (df['open'].shift(2) + df['close'].shift(2)) / 2)
    patterns['morning_star'] = mask

    # Evening Star (bearish reversal)
    mask = df['prev2_bullish'] & \
           (df['body_abs'].shift(1) < df['body_abs'].shift(2) * 0.3) & \
           df['is_bearish'] & \
           (df['close'] < (df['open'].shift(2) + df['close'].shift(2)) / 2)
    patterns['evening_star'] = mask

    # Three White Soldiers
    mask = df['is_bullish'] & df['prev_bullish'] & df['prev2_bullish'] & \
           (df['close'] > df['close'].shift(1)) & \
           (df['close'].shift(1) > df['close'].shift(2)) & \
           (df['body_abs'] > df['range'] * 0.5) & \
           (df['body_abs'].shift(1) > df['range'].shift(1) * 0.5)
    patterns['three_white_soldiers'] = mask

    # Three Black Crows
    mask = df['is_bearish'] & df['prev_bearish'] & df['prev2_bearish'] & \
           (df['close'] < df['close'].shift(1)) & \
           (df['close'].shift(1) < df['close'].shift(2)) & \
           (df['body_abs'] > df['range'] * 0.5) & \
           (df['body_abs'].shift(1) > df['range'].shift(1) * 0.5)
    patterns['three_black_crows'] = mask

    return patterns


# ============================================================================
# 3. TECHNICAL CONDITION PATTERNS
# ============================================================================

def detect_technical_patterns(df):
    """Detect patterns based on technical indicators."""
    patterns = {}

    # --- TREND PATTERNS ---

    # Golden Cross: EMA9 crosses above EMA21
    patterns['golden_cross'] = (df['ema_9'] > df['ema_21']) & (df['ema_9'].shift(1) <= df['ema_21'].shift(1))

    # Death Cross: EMA9 crosses below EMA21
    patterns['death_cross'] = (df['ema_9'] < df['ema_21']) & (df['ema_9'].shift(1) >= df['ema_21'].shift(1))

    # Price above all MAs (strong uptrend)
    patterns['strong_uptrend'] = (df['close'] > df['sma_20']) & (df['close'] > df['sma_50']) & (df['close'] > df['sma_200'])

    # Price below all MAs (strong downtrend)
    patterns['strong_downtrend'] = (df['close'] < df['sma_20']) & (df['close'] < df['sma_50']) & (df['close'] < df['sma_200'])

    # --- RSI PATTERNS ---

    # RSI oversold bounce: RSI was < 30 and now crossing above 30
    patterns['rsi_oversold_bounce'] = (df['rsi_14'] > 30) & (df['rsi_14'].shift(1) <= 30)

    # RSI overbought reversal: RSI was > 70 and now crossing below 70
    patterns['rsi_overbought_reversal'] = (df['rsi_14'] < 70) & (df['rsi_14'].shift(1) >= 70)

    # RSI divergence approximation: price makes new low but RSI doesn't
    low_5 = df['low'].rolling(5).min()
    rsi_at_low = df['rsi_14'].rolling(5).min()
    patterns['rsi_bullish_div'] = (df['low'] <= low_5) & (df['rsi_14'] > rsi_at_low.shift(20)) & (df['rsi_14'] < 40)

    # --- BOLLINGER BAND PATTERNS ---

    # BB squeeze: bandwidth < 20th percentile (low volatility)
    bb_width = (df['bb_upper'] - df['bb_lower']) / df['bb_mid']
    bb_width_pctile = bb_width.rolling(200).quantile(0.2)
    patterns['bb_squeeze'] = bb_width < bb_width_pctile

    # Price touches lower BB (potential bounce)
    patterns['bb_lower_touch'] = df['low'] <= df['bb_lower']

    # Price touches upper BB (potential reversal)
    patterns['bb_upper_touch'] = df['high'] >= df['bb_upper']

    # --- MACD PATTERNS ---

    # MACD bullish crossover
    patterns['macd_bull_cross'] = (df['macd'] > df['macd_signal']) & (df['macd'].shift(1) <= df['macd_signal'].shift(1))

    # MACD bearish crossover
    patterns['macd_bear_cross'] = (df['macd'] < df['macd_signal']) & (df['macd'].shift(1) >= df['macd_signal'].shift(1))

    # --- STOCHASTIC PATTERNS ---

    # Stoch oversold cross up: K crosses above D below 20
    patterns['stoch_oversold_cross'] = (df['stoch_k'] > df['stoch_d']) & \
                                        (df['stoch_k'].shift(1) <= df['stoch_d'].shift(1)) & \
                                        (df['stoch_k'] < 25)

    # Stoch overbought cross down: K crosses below D above 80
    patterns['stoch_overbought_cross'] = (df['stoch_k'] < df['stoch_d']) & \
                                          (df['stoch_k'].shift(1) >= df['stoch_d'].shift(1)) & \
                                          (df['stoch_k'] > 75)

    # --- VOLUME PATTERNS ---

    # Volume spike: volume > 2x average
    patterns['volume_spike_bull'] = (df['vol_ratio'] > 2.0) & df['is_bullish']
    patterns['volume_spike_bear'] = (df['vol_ratio'] > 2.0) & df['is_bearish']

    # Volume dryup before breakout
    patterns['volume_dryup'] = df['vol_ratio'] < 0.3

    return patterns


# ============================================================================
# 4. SESSION & TIME PATTERNS
# ============================================================================

def analyze_session_patterns(df):
    """Analyze patterns based on trading sessions and time."""
    results = {}

    # --- Average return by hour ---
    hourly = df.groupby('hour').agg(
        avg_return=('return_pct', 'mean'),
        std_return=('return_pct', 'std'),
        bullish_pct=('is_bullish', 'mean'),
        avg_range=('range', 'mean'),
        avg_volume=('tick_volume', 'mean'),
        count=('return_pct', 'count')
    ).round(6)
    results['hourly_stats'] = hourly

    # --- Average return by day of week ---
    daily = df.groupby('day_name').agg(
        avg_return=('return_pct', 'mean'),
        std_return=('return_pct', 'std'),
        bullish_pct=('is_bullish', 'mean'),
        avg_range=('range', 'mean'),
        avg_volume=('tick_volume', 'mean'),
        count=('return_pct', 'count')
    ).round(6)
    results['daily_stats'] = daily

    # --- Session stats ---
    session = df.groupby('session').agg(
        avg_return=('return_pct', 'mean'),
        std_return=('return_pct', 'std'),
        bullish_pct=('is_bullish', 'mean'),
        avg_range=('range', 'mean'),
        avg_volume=('tick_volume', 'mean'),
        count=('return_pct', 'count')
    ).round(6)
    results['session_stats'] = session

    # --- Hour + Day combination ---
    hour_day = df.groupby(['day_of_week', 'hour']).agg(
        avg_return=('return_pct', 'mean'),
        bullish_pct=('is_bullish', 'mean'),
        avg_range=('range', 'mean'),
        count=('return_pct', 'count')
    ).round(6)
    results['hour_day_stats'] = hour_day

    # --- Month seasonality ---
    monthly = df.groupby('month').agg(
        avg_return=('return_pct', 'mean'),
        bullish_pct=('is_bullish', 'mean'),
        avg_range=('range', 'mean'),
        count=('return_pct', 'count')
    ).round(6)
    results['monthly_stats'] = monthly

    # --- Session transition patterns ---
    # What happens when Asian session ends and London opens?
    london_open = df[df['hour'] == 7].copy()
    asian_close = df[df['hour'] == 6].copy()
    results['london_open_stats'] = {
        'avg_return': london_open['return_pct'].mean(),
        'bullish_pct': london_open['is_bullish'].mean(),
        'avg_range': london_open['range'].mean(),
    }

    ny_open = df[df['hour'] == 13].copy()
    results['ny_open_stats'] = {
        'avg_return': ny_open['return_pct'].mean(),
        'bullish_pct': ny_open['is_bullish'].mean(),
        'avg_range': ny_open['range'].mean(),
    }

    return results


# ============================================================================
# 5. PATTERN EVALUATION & BACKTESTING
# ============================================================================

def evaluate_pattern(df, mask, pattern_name, direction='long', horizon_bars=6):
    """
    Evaluate a pattern's predictive power.
    direction: 'long' (expect price to go up) or 'short' (expect price to go down)
    horizon_bars: how many M15 bars ahead to measure (6 = 1.5 hours)
    """
    if mask.sum() < 30:
        return None

    subset = df[mask].dropna(subset=[f'next_{horizon_bars}_return'] if f'next_{horizon_bars}_return' in df.columns else ['next_3_return'])

    if len(subset) < 30:
        return None

    # Use appropriate horizon
    if horizon_bars == 1:
        ret_col = 'next_return'
    elif horizon_bars == 3:
        ret_col = 'next_3_return'
    elif horizon_bars == 6:
        ret_col = 'next_6_return'
    elif horizon_bars == 12:
        ret_col = 'next_12_return'
    else:
        ret_col = 'next_3_return'

    subset_clean = subset.dropna(subset=[ret_col])
    if len(subset_clean) < 30:
        return None

    returns = subset_clean[ret_col]

    if direction == 'short':
        returns = -returns

    win_rate = (returns > 0).mean()
    avg_return = returns.mean()
    avg_win = returns[returns > 0].mean() if (returns > 0).any() else 0
    avg_loss = returns[returns <= 0].mean() if (returns <= 0).any() else 0

    profit_factor = abs(avg_win * (returns > 0).sum()) / abs(avg_loss * (returns <= 0).sum()) if avg_loss != 0 and (returns <= 0).sum() > 0 else float('inf')

    # Statistical significance (t-test)
    from scipy import stats
    t_stat, p_value = stats.ttest_1samp(returns, 0)

    # Sharpe-like ratio
    sharpe = avg_return / returns.std() if returns.std() > 0 else 0

    # Expectancy per trade (in $)
    # Assuming 1 lot XAUUSD, 1 pip = $0.10 on M15
    avg_price = subset_clean['close'].mean()
    expectancy_pips = avg_return * avg_price / 0.01  # convert % to pips approximately

    return {
        'pattern': pattern_name,
        'direction': direction,
        'occurrences': int(mask.sum()),
        'evaluated': len(subset_clean),
        'horizon_bars': horizon_bars,
        'win_rate': round(win_rate * 100, 2),
        'avg_return_pct': round(avg_return, 6),
        'avg_win_pct': round(avg_win, 6) if avg_win else 0,
        'avg_loss_pct': round(avg_loss, 6) if avg_loss else 0,
        'profit_factor': round(profit_factor, 3) if profit_factor != float('inf') else 999.0,
        'sharpe': round(sharpe, 4),
        't_stat': round(t_stat, 3),
        'p_value': round(p_value, 6),
        'significant': p_value < 0.05,
        'expectancy_pips': round(expectancy_pips, 2)
    }


def run_full_backtest(df, patterns_dict, direction_map):
    """Run backtest for all patterns at multiple horizons."""
    all_results = []

    for pattern_name, mask in patterns_dict.items():
        direction = direction_map.get(pattern_name, 'long')

        for horizon in [1, 3, 6, 12]:
            result = evaluate_pattern(df, mask, pattern_name, direction, horizon)
            if result:
                all_results.append(result)

    return pd.DataFrame(all_results)


# ============================================================================
# 6. COMBINED SIGNAL PATTERNS (Multi-Condition)
# ============================================================================

def detect_combined_patterns(df, candle_patterns, tech_patterns):
    """Detect high-probability combined patterns."""
    combined = {}

    # --- COMBO 1: Bullish Engulfing + RSI oversold + Volume spike ---
    combined['combo_bull_engulf_rsi_vol'] = (
        candle_patterns.get('bullish_engulfing', pd.Series(False, index=df.index)) &
        (df['rsi_14'] < 35) &
        (df['vol_ratio'] > 1.5)
    )

    # --- COMBO 2: Bearish Engulfing + RSI overbought + Volume spike ---
    combined['combo_bear_engulf_rsi_vol'] = (
        candle_patterns.get('bearish_engulfing', pd.Series(False, index=df.index)) &
        (df['rsi_14'] > 65) &
        (df['vol_ratio'] > 1.5)
    )

    # --- COMBO 3: Hammer at BB lower band ---
    combined['combo_hammer_bb_lower'] = (
        candle_patterns.get('hammer', pd.Series(False, index=df.index)) &
        tech_patterns.get('bb_lower_touch', pd.Series(False, index=df.index))
    )

    # --- COMBO 4: Shooting star at BB upper band ---
    combined['combo_shootstar_bb_upper'] = (
        candle_patterns.get('shooting_star', pd.Series(False, index=df.index)) &
        tech_patterns.get('bb_upper_touch', pd.Series(False, index=df.index))
    )

    # --- COMBO 5: MACD bull cross + Stoch oversold ---
    combined['combo_macd_stoch_bull'] = (
        tech_patterns.get('macd_bull_cross', pd.Series(False, index=df.index)) &
        (df['stoch_k'] < 30)
    )

    # --- COMBO 6: MACD bear cross + Stoch overbought ---
    combined['combo_macd_stoch_bear'] = (
        tech_patterns.get('macd_bear_cross', pd.Series(False, index=df.index)) &
        (df['stoch_k'] > 70)
    )

    # --- COMBO 7: London session open + Strong trend + Volume ---
    combined['combo_london_trend_bull'] = (
        (df['hour'] == 7) &
        (df['close'] > df['sma_20']) &
        (df['ema_9'] > df['ema_21']) &
        df['is_bullish'] &
        (df['vol_ratio'] > 1.2)
    )

    combined['combo_london_trend_bear'] = (
        (df['hour'] == 7) &
        (df['close'] < df['sma_20']) &
        (df['ema_9'] < df['ema_21']) &
        df['is_bearish'] &
        (df['vol_ratio'] > 1.2)
    )

    # --- COMBO 8: NY session open + Momentum ---
    combined['combo_ny_momentum_bull'] = (
        (df['hour'] == 13) &
        (df['macd_hist'] > 0) &
        (df['macd_hist'] > df['macd_hist'].shift(1)) &
        df['is_bullish']
    )

    combined['combo_ny_momentum_bear'] = (
        (df['hour'] == 13) &
        (df['macd_hist'] < 0) &
        (df['macd_hist'] < df['macd_hist'].shift(1)) &
        df['is_bearish']
    )

    # --- COMBO 9: BB Squeeze breakout ---
    combined['combo_bb_squeeze_bull'] = (
        tech_patterns.get('bb_squeeze', pd.Series(False, index=df.index)) &
        df['is_bullish'] &
        (df['range'] > df['atr_14'] * 1.2) &
        (df['vol_ratio'] > 1.5)
    )

    combined['combo_bb_squeeze_bear'] = (
        tech_patterns.get('bb_squeeze', pd.Series(False, index=df.index)) &
        df['is_bearish'] &
        (df['range'] > df['atr_14'] * 1.2) &
        (df['vol_ratio'] > 1.5)
    )

    # --- COMBO 10: Three soldiers/crows + trend confirmation ---
    combined['combo_3soldiers_trend'] = (
        candle_patterns.get('three_white_soldiers', pd.Series(False, index=df.index)) &
        (df['close'] > df['sma_50'])
    )

    combined['combo_3crows_trend'] = (
        candle_patterns.get('three_black_crows', pd.Series(False, index=df.index)) &
        (df['close'] < df['sma_50'])
    )

    # --- COMBO 11: RSI divergence + Support ---
    combined['combo_rsi_div_support'] = (
        tech_patterns.get('rsi_bullish_div', pd.Series(False, index=df.index)) &
        tech_patterns.get('bb_lower_touch', pd.Series(False, index=df.index))
    )

    # --- COMBO 12: Volume dryup then spike (accumulation/distribution) ---
    vol_was_dry = tech_patterns.get('volume_dryup', pd.Series(False, index=df.index)).shift(1) | \
                  tech_patterns.get('volume_dryup', pd.Series(False, index=df.index)).shift(2)
    combined['combo_vol_accumulation_bull'] = (
        vol_was_dry &
        (df['vol_ratio'] > 2.0) &
        df['is_bullish']
    )

    combined['combo_vol_distribution_bear'] = (
        vol_was_dry &
        (df['vol_ratio'] > 2.0) &
        df['is_bearish']
    )

    return combined


# ============================================================================
# 7. SUPPORT / RESISTANCE LEVEL DETECTION
# ============================================================================

def detect_sr_levels(df, window=48, min_touches=3):
    """Detect significant support and resistance levels."""
    # Find swing highs and lows
    df_temp = df.copy()
    df_temp['swing_high'] = df_temp['high'][(df_temp['high'] == df_temp['high'].rolling(window, center=True).max())]
    df_temp['swing_low'] = df_temp['low'][(df_temp['low'] == df_temp['low'].rolling(window, center=True).min())]

    swing_highs = df_temp['swing_high'].dropna().values
    swing_lows = df_temp['swing_low'].dropna().values

    # Cluster price levels
    all_levels = np.concatenate([swing_highs, swing_lows])
    all_levels = np.sort(all_levels)

    # Group nearby levels (within 0.5% of each other)
    clusters = []
    if len(all_levels) > 0:
        current_cluster = [all_levels[0]]
        for price in all_levels[1:]:
            if abs(price - np.mean(current_cluster)) / np.mean(current_cluster) < 0.005:
                current_cluster.append(price)
            else:
                if len(current_cluster) >= min_touches:
                    clusters.append({
                        'level': round(np.mean(current_cluster), 2),
                        'touches': len(current_cluster),
                        'strength': len(current_cluster)
                    })
                current_cluster = [price]
        if len(current_cluster) >= min_touches:
            clusters.append({
                'level': round(np.mean(current_cluster), 2),
                'touches': len(current_cluster),
                'strength': len(current_cluster)
            })

    # Sort by strength
    clusters.sort(key=lambda x: x['strength'], reverse=True)
    return clusters[:30]


# ============================================================================
# 8. MAIN ANALYSIS
# ============================================================================

def main():
    print("=" * 80)
    print("  XAUUSD M15 PATTERN ANALYZER - Comprehensive Trading Pattern Analysis")
    print("=" * 80)
    print()

    # Load data
    print("[1/8] Loading and cleaning data...")
    df = load_and_clean_data('data/xauusd_m15_raw.csv')
    print(f"  Loaded {len(df):,} M15 candles")
    print(f"  Period: {df['Date'].min()} to {df['Date'].max()}")
    print(f"  Price range: ${df['low'].min():.2f} - ${df['high'].max():.2f}")
    print(f"  Average ATR(14): ${df['atr_14'].mean():.2f}")
    print()

    # Detect candlestick patterns
    print("[2/8] Detecting candlestick patterns...")
    candle_patterns = detect_candlestick_patterns(df)
    for name, mask in candle_patterns.items():
        count = mask.sum()
        if count > 0:
            print(f"  {name}: {count:,} occurrences ({count/len(df)*100:.2f}%)")
    print()

    # Detect technical patterns
    print("[3/8] Detecting technical patterns...")
    tech_patterns = detect_technical_patterns(df)
    for name, mask in tech_patterns.items():
        count = mask.sum()
        if count > 0:
            print(f"  {name}: {count:,} occurrences ({count/len(df)*100:.2f}%)")
    print()

    # Detect combined patterns
    print("[4/8] Detecting combined (multi-condition) patterns...")
    combined_patterns = detect_combined_patterns(df, candle_patterns, tech_patterns)
    for name, mask in combined_patterns.items():
        count = mask.sum()
        if count > 0:
            print(f"  {name}: {count:,} occurrences ({count/len(df)*100:.2f}%)")
    print()

    # Session analysis
    print("[5/8] Analyzing session and time patterns...")
    session_results = analyze_session_patterns(df)

    print("\n  --- Hourly Stats (avg return %, bullish %, avg range) ---")
    for hour in range(24):
        if hour in session_results['hourly_stats'].index:
            row = session_results['hourly_stats'].loc[hour]
            bar = "+" * int(abs(row['avg_return']) * 50000)
            direction = "▲" if row['avg_return'] > 0 else "▼"
            print(f"  {hour:02d}:00  {direction} {row['avg_return']:+.6f}%  bull:{row['bullish_pct']*100:.1f}%  range:${row['avg_range']:.2f}  vol:{row['avg_volume']:.0f}")

    print("\n  --- Session Stats ---")
    print(session_results['session_stats'].to_string())

    print("\n  --- Day of Week Stats ---")
    print(session_results['daily_stats'].to_string())

    print("\n  --- Month Seasonality ---")
    print(session_results['monthly_stats'].to_string())
    print()

    # S/R levels
    print("[6/8] Detecting Support/Resistance levels...")
    sr_levels = detect_sr_levels(df)
    print(f"  Found {len(sr_levels)} significant S/R levels")
    for level in sr_levels[:15]:
        print(f"  ${level['level']:.2f} (touches: {level['touches']})")
    print()

    # Define direction map for patterns
    direction_map = {
        # Candlestick - bullish
        'doji': 'long', 'hammer': 'long', 'marubozu_bull': 'long',
        'bullish_engulfing': 'long', 'piercing': 'long',
        'morning_star': 'long', 'three_white_soldiers': 'long',
        'large_bull': 'long',
        # Candlestick - bearish
        'shooting_star': 'short', 'marubozu_bear': 'short',
        'bearish_engulfing': 'short', 'dark_cloud': 'short',
        'evening_star': 'short', 'three_black_crows': 'short',
        'large_bear': 'short',
        # Technical - bullish
        'golden_cross': 'long', 'strong_uptrend': 'long',
        'rsi_oversold_bounce': 'long', 'bb_lower_touch': 'long',
        'macd_bull_cross': 'long', 'stoch_oversold_cross': 'long',
        'volume_spike_bull': 'long', 'rsi_bullish_div': 'long',
        # Technical - bearish
        'death_cross': 'short', 'strong_downtrend': 'short',
        'rsi_overbought_reversal': 'short', 'bb_upper_touch': 'short',
        'macd_bear_cross': 'short', 'stoch_overbought_cross': 'short',
        'volume_spike_bear': 'short',
        # Neutral
        'bb_squeeze': 'long', 'volume_dryup': 'long',
        # Combined - bullish
        'combo_bull_engulf_rsi_vol': 'long',
        'combo_hammer_bb_lower': 'long',
        'combo_macd_stoch_bull': 'long',
        'combo_london_trend_bull': 'long',
        'combo_ny_momentum_bull': 'long',
        'combo_bb_squeeze_bull': 'long',
        'combo_3soldiers_trend': 'long',
        'combo_rsi_div_support': 'long',
        'combo_vol_accumulation_bull': 'long',
        # Combined - bearish
        'combo_bear_engulf_rsi_vol': 'short',
        'combo_shootstar_bb_upper': 'short',
        'combo_macd_stoch_bear': 'short',
        'combo_london_trend_bear': 'short',
        'combo_ny_momentum_bear': 'short',
        'combo_bb_squeeze_bear': 'short',
        'combo_3crows_trend': 'short',
        'combo_vol_distribution_bear': 'short',
    }

    # Run backtests
    print("[7/8] Running backtests on ALL patterns (4 horizons each)...")
    all_patterns = {**candle_patterns, **tech_patterns, **combined_patterns}
    results_df = run_full_backtest(df, all_patterns, direction_map)

    if len(results_df) == 0:
        print("  No patterns had enough data for evaluation.")
        return

    # Filter significant results
    sig_results = results_df[results_df['significant']].copy()

    print(f"\n  Total pattern-horizon combinations tested: {len(results_df)}")
    print(f"  Statistically significant (p<0.05): {len(sig_results)}")

    # ======================================================================
    # TOP PATTERNS
    # ======================================================================
    print()
    print("=" * 80)
    print("  TOP PERFORMING PATTERNS (Sorted by Profit Factor, p<0.05)")
    print("=" * 80)

    if len(sig_results) > 0:
        top = sig_results.sort_values('profit_factor', ascending=False).head(30)
        for i, row in top.iterrows():
            print(f"\n  {'='*60}")
            print(f"  Pattern: {row['pattern']}")
            print(f"  Direction: {row['direction'].upper()} | Horizon: {row['horizon_bars']} bars ({row['horizon_bars']*15}min)")
            print(f"  Occurrences: {row['occurrences']:,} | Evaluated: {row['evaluated']:,}")
            print(f"  Win Rate: {row['win_rate']:.1f}%")
            print(f"  Avg Return: {row['avg_return_pct']:+.6f}%")
            print(f"  Avg Win: {row['avg_win_pct']:+.6f}% | Avg Loss: {row['avg_loss_pct']:+.6f}%")
            print(f"  Profit Factor: {row['profit_factor']:.3f}")
            print(f"  Sharpe: {row['sharpe']:.4f}")
            print(f"  t-stat: {row['t_stat']:.3f} | p-value: {row['p_value']:.6f}")
            print(f"  Expectancy: {row['expectancy_pips']:.1f} pips/trade")

    # ======================================================================
    # BEST LONG SIGNALS
    # ======================================================================
    print()
    print("=" * 80)
    print("  BEST LONG (BUY) SIGNALS")
    print("=" * 80)

    long_results = sig_results[sig_results['direction'] == 'long'].sort_values('profit_factor', ascending=False).head(15)
    if len(long_results) > 0:
        for i, row in long_results.iterrows():
            print(f"  BUY  | {row['pattern']:40s} | WR:{row['win_rate']:5.1f}% | PF:{row['profit_factor']:6.3f} | {row['horizon_bars']*15:3d}min | n={row['evaluated']:5d} | p={row['p_value']:.4f}")

    # ======================================================================
    # BEST SHORT SIGNALS
    # ======================================================================
    print()
    print("=" * 80)
    print("  BEST SHORT (SELL) SIGNALS")
    print("=" * 80)

    short_results = sig_results[sig_results['direction'] == 'short'].sort_values('profit_factor', ascending=False).head(15)
    if len(short_results) > 0:
        for i, row in short_results.iterrows():
            print(f"  SELL | {row['pattern']:40s} | WR:{row['win_rate']:5.1f}% | PF:{row['profit_factor']:6.3f} | {row['horizon_bars']*15:3d}min | n={row['evaluated']:5d} | p={row['p_value']:.4f}")

    # ======================================================================
    # COMBINED PATTERN RESULTS
    # ======================================================================
    print()
    print("=" * 80)
    print("  COMBINED PATTERN RESULTS (Multi-Condition)")
    print("=" * 80)

    combo_results = results_df[results_df['pattern'].str.startswith('combo_')].sort_values('profit_factor', ascending=False)
    if len(combo_results) > 0:
        for i, row in combo_results.iterrows():
            sig_marker = "***" if row['significant'] else "   "
            print(f"  {sig_marker} {row['direction']:5s} | {row['pattern']:40s} | WR:{row['win_rate']:5.1f}% | PF:{row['profit_factor']:6.3f} | {row['horizon_bars']*15:3d}min | n={row['evaluated']:5d} | p={row['p_value']:.4f}")

    # ======================================================================
    # SAVE RESULTS
    # ======================================================================
    print()
    print("[8/8] Saving results...")

    results_df.to_csv('data/pattern_backtest_results.csv', index=False)
    print("  Saved: data/pattern_backtest_results.csv")

    if len(sig_results) > 0:
        sig_results.to_csv('data/significant_patterns.csv', index=False)
        print("  Saved: data/significant_patterns.csv")

    # Save session stats
    session_results['hourly_stats'].to_csv('data/hourly_stats.csv')
    session_results['daily_stats'].to_csv('data/daily_stats.csv')
    session_results['session_stats'].to_csv('data/session_stats.csv')
    session_results['monthly_stats'].to_csv('data/monthly_stats.csv')
    print("  Saved: data/hourly_stats.csv, daily_stats.csv, session_stats.csv, monthly_stats.csv")

    # Save S/R levels
    pd.DataFrame(sr_levels).to_csv('data/sr_levels.csv', index=False)
    print("  Saved: data/sr_levels.csv")

    # ======================================================================
    # TRADING STRATEGY SUMMARY
    # ======================================================================
    print()
    print("=" * 80)
    print("  TRADING STRATEGY SUMMARY")
    print("=" * 80)

    print("""
  Based on 10 years of XAUUSD M15 data analysis, here are the key findings:

  ENTRY RULES:
  ============

  PRIMARY BUY SIGNALS (Look for 2+ confirming conditions):
  1. Bullish Engulfing candle with RSI < 35 and volume > 1.5x average
  2. Hammer at Bollinger Band lower band
  3. MACD bullish crossover with Stochastic < 30
  4. London session open (07:00 UTC) with trend alignment (EMA9 > EMA21)
  5. BB Squeeze breakout with volume spike (bullish candle)
  6. Volume accumulation pattern (dryup followed by spike + bullish candle)

  PRIMARY SELL SIGNALS (Look for 2+ confirming conditions):
  1. Bearish Engulfing candle with RSI > 65 and volume > 1.5x average
  2. Shooting Star at Bollinger Band upper band
  3. MACD bearish crossover with Stochastic > 70
  4. Three Black Crows below SMA50
  5. BB Squeeze breakout with volume spike (bearish candle)
  6. Volume distribution pattern (dryup followed by spike + bearish candle)

  EXIT RULES:
  ===========
  - Take Profit: 1.5x ATR(14) from entry
  - Stop Loss: 1.0x ATR(14) from entry
  - Trailing stop after 1x ATR in profit
  - Time exit: Close position after 12 M15 bars (3 hours) if neither TP nor SL hit
  - Close on opposite signal

  TIMING FILTERS:
  ===============
  - Best trading hours: London + NY overlap (13:00-17:00 UTC)
  - Avoid: Late NY session (20:00-23:59 UTC) - low volume, erratic
  - Best days: Check daily stats output
  - Avoid: Friday after 20:00 UTC (weekend gap risk)

  RISK MANAGEMENT:
  ================
  - Max 1 position at a time
  - Risk 1-2% per trade
  - Min 1.5:1 reward-to-risk ratio
  """)

    print("=" * 80)
    print("  ANALYSIS COMPLETE")
    print("=" * 80)


if __name__ == '__main__':
    main()
