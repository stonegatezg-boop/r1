"""
Clawder Brain v2.0 - Python <-> Claude AI Bridge
Cita podatke iz MT5 (clawder_data.csv), salje Claudeu, pise odluku natrag.

v2.0 NOVO:
- Timeout s HOLD fallbackom
- Decision caching (izbjegava ponavljanja)
- Logging sustav za review
- Podrska za H1/H4 kontekst
- Environment varijable za API key
"""

import anthropic
import csv
import time
import os
import json
import logging
from datetime import datetime
from pathlib import Path

# ============================================================
# POSTAVKE
# ============================================================
API_KEY = os.getenv("ANTHROPIC_API_KEY")

# Windows putanja (promijeni ako treba)
COMMON_FILES = os.getenv(
    "CLAWDER_FILES_PATH",
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
)

DATA_FILE = os.path.join(COMMON_FILES, "clawder_data.csv")
DECISION_FILE = os.path.join(COMMON_FILES, "clawder_decision.csv")

# Logging
LOG_DIR = os.getenv("CLAWDER_LOG_DIR", os.path.join(os.path.dirname(__file__), "logs"))
LOG_FILE = os.path.join(LOG_DIR, f"clawder_{datetime.now().strftime('%Y%m%d')}.log")

CHECK_INTERVAL = 30  # sekundi
API_TIMEOUT = 30     # sekundi za Claude API poziv
MAX_RETRIES = 2      # broj pokusaja ako API fail

# Decision cache - izbjegava ponavljanje istih odluka
DECISION_CACHE_SIZE = 10
# ============================================================


# ============================================================
# LOGGING SETUP
# ============================================================
def setup_logging():
    """Postavi logging sustav."""
    Path(LOG_DIR).mkdir(parents=True, exist_ok=True)

    # File handler
    file_handler = logging.FileHandler(LOG_FILE, encoding='utf-8')
    file_handler.setLevel(logging.DEBUG)
    file_formatter = logging.Formatter(
        '%(asctime)s | %(levelname)-8s | %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    file_handler.setFormatter(file_formatter)

    # Console handler
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    console_formatter = logging.Formatter('[%(levelname)s] %(message)s')
    console_handler.setFormatter(console_formatter)

    # Root logger
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger

logger = setup_logging()


# ============================================================
# SYSTEM PROMPT - v2.0
# ============================================================
SYSTEM_PROMPT = """Ti si AI trading asistent za XAUUSD (zlato) na M5 timeframeu.

Dobivas trzisne podatke s indikatorima i moras donijeti odluku.

PRAVILA:
- Odgovori SAMO u zadanom formatu, nista drugo
- confidence mora biti izmedu 0.0 i 1.0
- SL i TP su apsolutne cijene (ne pipsi)
- Ako nisi siguran, stavi HOLD s niskim confidenceom
- Budi konzervativan - bolje HOLD nego los trade

KRITICNI FILTERI (NIKAD ne ignoriraj):
- impulse_candle=true -> OBAVEZNO HOLD (prekasno za entry)
- momentum_exhaustion=true -> smanji confidence za 0.2
- kill_switch_active=true -> OBAVEZNO HOLD (daily limit)
- spread_atr_pct > 30 -> HOLD (spread presirok)

HTF KONTEKST (jako vazno):
- h1_trend i h4_trend moraju biti u skladu s tvojom odlukom
- Ako je h1_trend=strong_bearish, ne idi LONG osim za scalp
- Ako je h4_trend suprotan od M5, smanji confidence

KVALITETA SIGNALA:
- ema_cross_event=golden/death -> svjez cross, vazan signal
- ema_alignment -> trenutni trend odnos (state, ne event)
- RSI extreme + MACD cross + BB touch = jak signal
- Samo RSI extreme = slab signal, treba potvrda

FORMAT ODGOVORA (tocno ovako, odvojeno zarezima):
action,confidence,sl,tp,reasoning

MOGUCE AKCIJE:
- BUY - otvori long poziciju
- SELL - otvori short poziciju
- HOLD - ne radi nista
- CLOSE - zatvori otvorenu poziciju

PRIMJER DOBROG TRADEA:
BUY,0.82,2920.50,2945.00,RSI oversold + golden cross + h1_trend bullish + cijena na BB lower

PRIMJER HOLD:
HOLD,0.3,0,0,Mijesani signali - RSI neutralan a h1_trend suprotan od M5

PRIMJER IMPULSE CANDLE:
HOLD,0.1,0,0,Impulse candle - preopasno za entry nakon velikog pokreta

PRIMJER HTF KONFLIKT:
HOLD,0.4,0,0,M5 bullish ali h4_trend strong_bearish - cekam bolji setup"""


# ============================================================
# DECISION CACHE
# ============================================================
class DecisionCache:
    """Cache za izbjegavanje ponavljanja istih odluka."""

    def __init__(self, max_size=DECISION_CACHE_SIZE):
        self.cache = []
        self.max_size = max_size

    def add(self, data_hash, decision):
        """Dodaj odluku u cache."""
        self.cache.append({
            'hash': data_hash,
            'decision': decision,
            'time': datetime.now()
        })
        # Odrzi max velicinu
        if len(self.cache) > self.max_size:
            self.cache.pop(0)

    def get_similar(self, data_hash):
        """Provjeri ima li slicna odluka u cacheu."""
        for entry in self.cache:
            if entry['hash'] == data_hash:
                return entry['decision']
        return None

    def compute_hash(self, data_dict):
        """Izracunaj hash podataka (ignoriraj timestamp)."""
        # Ignoriraj timestamp i neke varijable koje se cesto mijenjaju
        ignore_keys = ['timestamp', 'spread_atr_pct', 'daily_drawdown_pct', 'trades_today']
        relevant = {k: v for k, v in data_dict.items() if k not in ignore_keys}
        return hash(json.dumps(relevant, sort_keys=True))


decision_cache = DecisionCache()


# ============================================================
# CORE FUNCTIONS
# ============================================================
def read_data():
    """Cita clawder_data.csv i vraca podatke kao dict i string."""
    if not os.path.exists(DATA_FILE):
        return None, None

    try:
        with open(DATA_FILE, "r") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            if not rows:
                return None, None

            data_dict = rows[0]  # Samo jedan red

            # Formatiraj kao string za Claudea
            content = f.read().strip() if False else None  # placeholder

        # Citaj opet kao raw string
        with open(DATA_FILE, "r") as f:
            content = f.read().strip()

        return data_dict, content

    except Exception as e:
        logger.error(f"Greska pri citanju data filea: {e}")
        return None, None


def parse_decision(response_text):
    """Parsira Claude odgovor u komponente."""
    text = response_text.strip()

    # Ukloni moguce markdown formatiranje
    if text.startswith("```"):
        lines = text.split("\n")
        text = "\n".join(lines[1:-1]) if len(lines) > 2 else text

    parts = text.split(",", 4)

    if len(parts) < 5:
        logger.warning(f"Neispravan format odgovora: {text}")
        return None

    action = parts[0].strip().upper()
    if action not in ("BUY", "SELL", "HOLD", "CLOSE"):
        logger.warning(f"Nepoznata akcija: {action}")
        return None

    try:
        confidence = float(parts[1].strip())
        sl = float(parts[2].strip())
        tp = float(parts[3].strip())
    except ValueError:
        logger.warning(f"Greska u parsiranju brojeva: {text}")
        return None

    reasoning = parts[4].strip()

    return {
        "action": action,
        "confidence": confidence,
        "sl": sl,
        "tp": tp,
        "reasoning": reasoning,
    }


def write_decision(decision):
    """Pise clawder_decision.csv za MT5 EA."""
    timestamp = datetime.now().strftime("%Y.%m.%d %H:%M:%S")

    try:
        with open(DECISION_FILE, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(
                ["timestamp", "action", "confidence", "sl", "tp", "reasoning"]
            )
            writer.writerow(
                [
                    timestamp,
                    decision["action"],
                    decision["confidence"],
                    decision["sl"],
                    decision["tp"],
                    decision["reasoning"],
                ]
            )

        logger.info(f"Decision written: {decision['action']} (confidence: {decision['confidence']:.2f})")
        logger.debug(f"Reasoning: {decision['reasoning']}")

    except Exception as e:
        logger.error(f"Greska pri pisanju decision filea: {e}")


def ask_claude(data_content, timeout=API_TIMEOUT):
    """Salje podatke Claudeu i vraca odluku."""
    client = anthropic.Anthropic(api_key=API_KEY, timeout=timeout)

    user_msg = f"""Evo trenutnih trzisnih podataka za XAUUSD M5:

{data_content}

Analiziraj podatke i donesi odluku. Odgovori SAMO u zadanom formatu:
action,confidence,sl,tp,reasoning"""

    try:
        response = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=200,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_msg}],
        )
        return response.content[0].text

    except anthropic.APITimeoutError:
        logger.warning("Claude API timeout - vracam HOLD")
        return None
    except anthropic.APIError as e:
        logger.error(f"Claude API error: {e}")
        return None


def get_fallback_hold(reason="API timeout"):
    """Vraca HOLD odluku kao fallback."""
    return {
        "action": "HOLD",
        "confidence": 0.0,
        "sl": 0,
        "tp": 0,
        "reasoning": f"FALLBACK: {reason}"
    }


def log_trade_analysis(data_dict, decision):
    """Logira detaljnu analizu za kasniji review."""
    logger.debug("=" * 60)
    logger.debug("TRADE ANALYSIS")
    logger.debug("=" * 60)

    # Kljucni podaci
    logger.debug(f"Timestamp: {data_dict.get('timestamp', 'N/A')}")
    logger.debug(f"Price: {data_dict.get('price', 'N/A')}")
    logger.debug(f"ATR: {data_dict.get('atr', 'N/A')}")

    # M5 signali
    logger.debug(f"RSI: {data_dict.get('rsi_value', 'N/A')} ({data_dict.get('rsi_zone', 'N/A')})")
    logger.debug(f"MACD: {data_dict.get('macd_state', 'N/A')} / {data_dict.get('macd_histogram', 'N/A')}")
    logger.debug(f"EMA: cross={data_dict.get('ema_cross_event', 'N/A')}, align={data_dict.get('ema_alignment', 'N/A')}")
    logger.debug(f"BB: {data_dict.get('bb_position', 'N/A')}")

    # Kriticni filteri
    logger.debug(f"Impulse: {data_dict.get('impulse_candle', 'N/A')}")
    logger.debug(f"Momentum Exhaustion: {data_dict.get('momentum_exhaustion', 'N/A')}")
    logger.debug(f"Spread ATR%: {data_dict.get('spread_atr_pct', 'N/A')}")

    # HTF kontekst
    logger.debug(f"H1 Trend: {data_dict.get('h1_trend', 'N/A')}")
    logger.debug(f"H4 Trend: {data_dict.get('h4_trend', 'N/A')}")

    # Daily limiti
    logger.debug(f"Trades Today: {data_dict.get('trades_today', 'N/A')}")
    logger.debug(f"Daily Drawdown: {data_dict.get('daily_drawdown_pct', 'N/A')}%")
    logger.debug(f"Kill Switch: {data_dict.get('kill_switch_active', 'N/A')}")

    # Odluka
    logger.debug("-" * 60)
    logger.debug(f"DECISION: {decision['action']} @ {decision['confidence']:.2f}")
    logger.debug(f"SL: {decision['sl']}, TP: {decision['tp']}")
    logger.debug(f"REASONING: {decision['reasoning']}")
    logger.debug("=" * 60)


# ============================================================
# MAIN LOOP
# ============================================================
def main():
    print("=" * 60)
    print("  Clawder Brain v2.0")
    print("  MT5 <-> Python <-> Claude AI")
    print("  With HTF Context, Logging & Safety Features")
    print("=" * 60)
    print(f"Data file:     {DATA_FILE}")
    print(f"Decision file: {DECISION_FILE}")
    print(f"Log file:      {LOG_FILE}")
    print(f"Check interval: {CHECK_INTERVAL}s")
    print(f"API timeout:    {API_TIMEOUT}s")
    print()

    if not API_KEY:
        print("[!] GRESKA: Postavi ANTHROPIC_API_KEY environment varijablu!")
        print("    Windows: set ANTHROPIC_API_KEY=sk-ant-...")
        print("    Linux:   export ANTHROPIC_API_KEY=sk-ant-...")
        return

    logger.info("Clawder Brain v2.0 started")

    last_timestamp = None

    print("[*] Cekam podatke od MT5...")
    print()

    while True:
        try:
            data_dict, data_content = read_data()

            if data_dict is None:
                time.sleep(CHECK_INTERVAL)
                continue

            current_timestamp = data_dict.get('timestamp', '')

            # Provjeri da li je novi bar
            if current_timestamp == last_timestamp:
                time.sleep(CHECK_INTERVAL)
                continue

            last_timestamp = current_timestamp
            logger.info(f"Novi bar: {current_timestamp}")

            # Provjeri kill switch
            if data_dict.get('kill_switch_active', 'false').lower() == 'true':
                logger.warning("Kill switch active - skipping Claude call")
                time.sleep(CHECK_INTERVAL)
                continue

            # Provjeri cache
            data_hash = decision_cache.compute_hash(data_dict)
            cached = decision_cache.get_similar(data_hash)

            if cached:
                logger.info(f"Using cached decision: {cached['action']}")
                decision = cached
            else:
                # Pitaj Claudea
                logger.info("Saljem Claudeu...")

                response = None
                for attempt in range(MAX_RETRIES):
                    response = ask_claude(data_content)
                    if response:
                        break
                    logger.warning(f"Retry {attempt + 1}/{MAX_RETRIES}...")
                    time.sleep(2)

                if response is None:
                    decision = get_fallback_hold("API failed after retries")
                else:
                    logger.debug(f"Claude response: {response}")
                    decision = parse_decision(response)

                    if decision is None:
                        decision = get_fallback_hold("Parse error")

                # Dodaj u cache
                decision_cache.add(data_hash, decision)

            # Logiraj analizu
            log_trade_analysis(data_dict, decision)

            # Pisi decision samo ako nije HOLD
            if decision["action"] == "HOLD":
                logger.info(f"HOLD - ne radim nista ({decision['reasoning']})")
            else:
                write_decision(decision)

            print()

        except KeyboardInterrupt:
            logger.info("Zaustavljam Clawder Brain...")
            print("\n[*] Zaustavljam Clawder Brain...")
            break
        except Exception as e:
            logger.error(f"Neocekivana greska: {e}", exc_info=True)
            time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
