"""
Clawder Brain v1.0 - Python <-> Claude AI Bridge
Čita podatke iz MT5 (clawder_data.csv), šalje Claudeu, piše odluku natrag.
"""

import anthropic
import csv
import time
import os
from datetime import datetime

# ============================================================
# POSTAVKE - PROMIJENI OVO
# ============================================================
API_KEY = "OVDJE_STAVI_SVOJ_KLJUC"  # sk-ant-...

COMMON_FILES = r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files"

DATA_FILE = os.path.join(COMMON_FILES, "clawder_data.csv")
DECISION_FILE = os.path.join(COMMON_FILES, "clawder_decision.csv")

CHECK_INTERVAL = 30  # sekundi - koliko često provjerava novi bar
# ============================================================

SYSTEM_PROMPT = """Ti si AI trading asistent za XAUUSD (zlato) na M5 timeframeu.

Dobivaš tržišne podatke s indikatorima i moraš donijeti odluku.

PRAVILA:
- Odgovori SAMO u zadanom formatu, ništa drugo
- confidence mora biti između 0.0 i 1.0
- SL i TP su apsolutne cijene (ne pipsi)
- Ako nisi siguran, stavi HOLD s niskim confidenceom
- Budi konzervativan - bolje HOLD nego loš trade

FORMAT ODGOVORA (točno ovako, odvojeno zarezima):
action,confidence,sl,tp,reasoning

MOGUĆE AKCIJE:
- BUY - otvori long poziciju
- SELL - otvori short poziciju
- HOLD - ne radi ništa
- CLOSE - zatvori otvorenu poziciju

PRIMJER:
BUY,0.82,2920.50,2945.00,RSI oversold uz bullish MACD cross i cijena blizu BB lower banda

PRIMJER HOLD:
HOLD,0.3,0,0,Miješani signali - RSI neutralan a MACD bearish"""


def read_data():
    """Čita clawder_data.csv i vraća podatke kao string."""
    if not os.path.exists(DATA_FILE):
        return None

    with open(DATA_FILE, "r") as f:
        content = f.read().strip()

    if not content:
        return None

    return content


def parse_decision(response_text):
    """Parsira Claude odgovor u komponente."""
    text = response_text.strip()
    parts = text.split(",", 4)

    if len(parts) < 5:
        print(f"[!] Neispravan format odgovora: {text}")
        return None

    action = parts[0].strip().upper()
    if action not in ("BUY", "SELL", "HOLD", "CLOSE"):
        print(f"[!] Nepoznata akcija: {action}")
        return None

    try:
        confidence = float(parts[1].strip())
        sl = float(parts[2].strip())
        tp = float(parts[3].strip())
    except ValueError:
        print(f"[!] Greška u parsiranju brojeva: {text}")
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
    """Piše clawder_decision.csv za MT5 EA."""
    timestamp = datetime.now().strftime("%Y.%m.%d %H:%M:%S")

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

    print(f"[>] Decision written: {decision['action']} (confidence: {decision['confidence']})")


def ask_claude(data_content):
    """Šalje podatke Claudeu i vraća odluku."""
    client = anthropic.Anthropic(api_key=API_KEY)

    user_msg = f"""Evo trenutnih tržišnih podataka za XAUUSD M5:

{data_content}

Analiziraj podatke i donesi odluku. Odgovori SAMO u zadanom formatu:
action,confidence,sl,tp,reasoning"""

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=200,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_msg}],
    )

    return response.content[0].text


def main():
    print("=" * 50)
    print("  Clawder Brain v1.0")
    print("  MT5 <-> Python <-> Claude AI")
    print("=" * 50)
    print(f"Data file:     {DATA_FILE}")
    print(f"Decision file: {DECISION_FILE}")
    print(f"Check interval: {CHECK_INTERVAL}s")
    print()

    if API_KEY == "OVDJE_STAVI_SVOJ_KLJUC":
        print("[!] GREŠKA: Stavi svoj Anthropic API ključ u API_KEY varijablu!")
        return

    last_timestamp = None

    print("[*] Čekam podatke od MT5...")
    print()

    while True:
        try:
            data = read_data()

            if data is None:
                time.sleep(CHECK_INTERVAL)
                continue

            # Izvuci timestamp iz podataka
            lines = data.strip().split("\n")
            if len(lines) < 2:
                time.sleep(CHECK_INTERVAL)
                continue

            current_timestamp = lines[1].split(",")[0]

            # Provjeri da li je novi bar
            if current_timestamp == last_timestamp:
                time.sleep(CHECK_INTERVAL)
                continue

            last_timestamp = current_timestamp
            print(f"[*] Novi bar: {current_timestamp}")

            # Pitaj Claudea
            print("[*] Šaljem Claudeu...")
            response = ask_claude(data)
            print(f"[<] Claude: {response}")

            # Parsiraj odluku
            decision = parse_decision(response)
            if decision is None:
                time.sleep(CHECK_INTERVAL)
                continue

            # Ako je HOLD, ne piši decision file
            if decision["action"] == "HOLD":
                print("[*] HOLD - ne radim ništa")
            else:
                write_decision(decision)

            print()

        except KeyboardInterrupt:
            print("\n[*] Zaustavljam Clawder Brain...")
            break
        except Exception as e:
            print(f"[!] Greška: {e}")
            time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
