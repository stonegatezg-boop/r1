#!/usr/bin/env python3
"""
Gemma Bridge v2.0 - AI Trading Decision Bridge
Connects MetaTrader 5 EA with Claude API for intelligent trade decisions.

Usage:
1. Set ANTHROPIC_API_KEY environment variable
2. Update MT5_FILES path to your terminal's MQL5/Files folder
3. Run: python gemma_bridge.py
"""

import os
import sys
import time
import csv
import logging
from datetime import datetime

try:
    from anthropic import Anthropic
except ImportError:
    print("ERROR: anthropic package not installed. Run: pip install anthropic")
    sys.exit(1)

# ============================================================================
# CONFIGURATION - UPDATE THESE PATHS!
# ============================================================================

# To find your MT5 Files folder:
# 1. Open MetaTrader 5
# 2. Go to File -> Open Data Folder
# 3. Navigate to MQL5/Files
# 4. Copy the full path

MT5_FILES = r"C:\Users\YOUR_USER\AppData\Roaming\MetaQuotes\Terminal\YOUR_TERMINAL_ID\MQL5\Files"

# Alternative: Auto-detect common paths
def find_mt5_files():
    """Try to find MT5 Files folder automatically"""
    import glob

    base_paths = [
        os.path.expandvars(r"%APPDATA%\MetaQuotes\Terminal"),
        r"C:\Users\*\AppData\Roaming\MetaQuotes\Terminal"
    ]

    for base in base_paths:
        pattern = os.path.join(base, "*", "MQL5", "Files")
        matches = glob.glob(pattern)
        if matches:
            # Return first match that exists
            for match in matches:
                if os.path.isdir(match):
                    return match
    return None

# ============================================================================
# LOGGING SETUP
# ============================================================================

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(levelname)-8s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('gemma_bridge.log', encoding='utf-8')
    ]
)
logger = logging.getLogger("GemmaBridge")

# ============================================================================
# API SETUP
# ============================================================================

API_KEY = os.getenv("ANTHROPIC_API_KEY")
if not API_KEY:
    logger.error("ANTHROPIC_API_KEY environment variable not set!")
    logger.info("Set it with: set ANTHROPIC_API_KEY=your_key_here (Windows)")
    logger.info("Or: export ANTHROPIC_API_KEY=your_key_here (Linux/Mac)")
    sys.exit(1)

client = Anthropic(api_key=API_KEY, timeout=30)

# ============================================================================
# FILE PATHS
# ============================================================================

# Try auto-detect if default path doesn't exist
if not os.path.isdir(MT5_FILES):
    detected = find_mt5_files()
    if detected:
        MT5_FILES = detected
        logger.info(f"Auto-detected MT5 Files folder: {MT5_FILES}")
    else:
        logger.error(f"MT5 Files folder not found: {MT5_FILES}")
        logger.info("Please update MT5_FILES variable in this script")
        sys.exit(1)

STATE_FILE = os.path.join(MT5_FILES, "state.csv")
DECISION_FILE = os.path.join(MT5_FILES, "decision.csv")

# ============================================================================
# AI SYSTEM PROMPT
# ============================================================================

SYSTEM_PROMPT = """You are Gemma, a conservative algorithmic trading classifier.

Your job is to analyze market state data and output a single trading decision.

## DECISION RULES (in order of priority):

1. **HOLD if impulse_candle is "true"**
   - Large candles indicate potential reversal or continuation uncertainty
   - Wait for pullback before entering

2. **HOLD if momentum_exhaustion is "true"**
   - Small body with large wicks = indecision
   - Trend may be weakening

3. **HOLD if volatility_extreme is "true"**
   - Market too volatile for safe entry
   - Risk of whipsaw

4. **BUY conditions (ALL must be true):**
   - ema_alignment is "bullish" (fast EMA > slow EMA)
   - No warning flags (impulse, exhaustion, extreme volatility)
   - hull_trend is "up" or "neutral"

5. **SELL conditions (ALL must be true):**
   - ema_alignment is "bearish" (fast EMA < slow EMA)
   - No warning flags
   - hull_trend is "down" or "neutral"

6. **When in doubt, always HOLD**
   - Missing data = HOLD
   - Conflicting signals = HOLD
   - Uncertainty = HOLD

## OUTPUT FORMAT:
Output EXACTLY one word: BUY, SELL, or HOLD
No explanations, no punctuation, just the decision word.
"""

# ============================================================================
# FUNCTIONS
# ============================================================================

def read_state():
    """
    Read state.csv written by MT5 EA.
    Expected format: CSV with header row and one data row.
    """
    try:
        if not os.path.exists(STATE_FILE):
            return None

        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)

            # First row = headers
            try:
                headers = next(reader)
            except StopIteration:
                logger.warning("state.csv is empty (no headers)")
                return None

            # Second row = values
            try:
                values = next(reader)
            except StopIteration:
                logger.warning("state.csv has headers but no data")
                return None

            # Create dictionary
            state = {}
            for i, header in enumerate(headers):
                header = header.strip().lower()
                value = values[i].strip() if i < len(values) else ""
                state[header] = value

            logger.info(f"State read: {state}")
            return state

    except PermissionError:
        logger.warning("state.csv locked by MT5, will retry...")
        return None
    except Exception as e:
        logger.error(f"Error reading state.csv: {e}")
        return None


def write_decision(decision):
    """
    Write decision to decision.csv for MT5 EA to read.
    """
    try:
        # Write with retry on permission error
        for attempt in range(3):
            try:
                with open(DECISION_FILE, 'w', encoding='utf-8') as f:
                    f.write(decision)
                logger.info(f"Decision written: {decision}")
                return True
            except PermissionError:
                if attempt < 2:
                    time.sleep(0.1)
                    continue
                raise
        return False
    except Exception as e:
        logger.error(f"Error writing decision: {e}")
        return False


def format_state_for_ai(state):
    """
    Format state dictionary into a clear prompt for the AI.
    """
    lines = ["Current market state:"]

    # Core indicators
    lines.append(f"- Close Price: {state.get('close', 'N/A')}")
    lines.append(f"- ATR: {state.get('atr', 'N/A')}")
    lines.append(f"- EMA Alignment: {state.get('ema_alignment', 'unknown')}")

    # Optional indicators
    if 'hull_trend' in state:
        lines.append(f"- Hull MA Trend: {state.get('hull_trend', 'neutral')}")
    if 'rsi' in state:
        lines.append(f"- RSI: {state.get('rsi', 'N/A')}")

    # Warning flags
    lines.append(f"- Impulse Candle: {state.get('impulse_candle', 'false')}")
    lines.append(f"- Momentum Exhaustion: {state.get('momentum_exhaustion', 'false')}")
    lines.append(f"- Volatility Extreme: {state.get('volatility_extreme', 'false')}")

    lines.append("")
    lines.append("Based on the rules, what is your trading decision?")

    return "\n".join(lines)


def get_ai_decision(state):
    """
    Call Claude API to get trading decision.
    """
    try:
        prompt = format_state_for_ai(state)

        logger.debug(f"Sending to AI:\n{prompt}")

        response = client.messages.create(
            model="claude-3-5-sonnet-20241022",
            max_tokens=10,
            temperature=0,  # Deterministic output
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": prompt}]
        )

        raw_response = response.content[0].text.strip().upper()
        logger.info(f"AI raw response: '{raw_response}'")

        # Parse response
        if "BUY" in raw_response:
            return "BUY"
        elif "SELL" in raw_response:
            return "SELL"
        else:
            return "HOLD"

    except Exception as e:
        logger.error(f"API Error: {type(e).__name__}: {e}")
        return "HOLD"  # Safe default on error


def main():
    """
    Main loop - monitors state.csv and writes decisions.
    """
    logger.info("=" * 60)
    logger.info("    GEMMA BRIDGE v2.0 - AI Trading Decision System")
    logger.info("=" * 60)
    logger.info(f"MT5 Files: {MT5_FILES}")
    logger.info(f"State file: {STATE_FILE}")
    logger.info(f"Decision file: {DECISION_FILE}")
    logger.info("=" * 60)
    logger.info("Waiting for state.csv updates from MT5 EA...")
    logger.info("Press Ctrl+C to stop")
    logger.info("")

    last_mod_time = 0
    decisions_made = 0

    while True:
        try:
            # Check if state file exists and was modified
            if os.path.exists(STATE_FILE):
                current_mod_time = os.path.getmtime(STATE_FILE)

                if current_mod_time > last_mod_time:
                    logger.info("-" * 40)
                    logger.info("State file changed - processing...")

                    # Small delay to ensure file is fully written
                    time.sleep(0.1)

                    # Read state
                    state = read_state()

                    if state:
                        # Get AI decision
                        decision = get_ai_decision(state)

                        # Write decision
                        if write_decision(decision):
                            decisions_made += 1
                            logger.info(f"Total decisions made: {decisions_made}")

                    last_mod_time = current_mod_time

            # Polling interval
            time.sleep(0.3)

        except KeyboardInterrupt:
            logger.info("")
            logger.info("=" * 60)
            logger.info("Shutting down Gemma Bridge...")
            logger.info(f"Total decisions made this session: {decisions_made}")
            logger.info("=" * 60)
            break

        except Exception as e:
            logger.error(f"Main loop error: {e}")
            time.sleep(1)


if __name__ == "__main__":
    main()
