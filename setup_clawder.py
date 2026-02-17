"""
Clawder Setup Script
Automatski postavlja Clawder sustav na Windows.
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path

def print_header():
    print("=" * 60)
    print("  CLAWDER v2.0 - SETUP")
    print("=" * 60)
    print()

def check_python():
    """Provjeri Python verziju."""
    print("[1/6] Provjera Python verzije...")
    version = sys.version_info
    if version.major < 3 or (version.major == 3 and version.minor < 8):
        print(f"  [!] Python {version.major}.{version.minor} - preporuceno 3.8+")
    else:
        print(f"  [OK] Python {version.major}.{version.minor}")
    return True

def install_anthropic():
    """Instaliraj anthropic library."""
    print("\n[2/6] Instalacija anthropic library...")
    try:
        import anthropic
        print("  [OK] anthropic vec instaliran")
        return True
    except ImportError:
        print("  [*] Instaliram anthropic...")
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "anthropic"],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            print("  [OK] anthropic instaliran")
            return True
        else:
            print(f"  [!] Greska: {result.stderr}")
            return False

def setup_api_key():
    """Postavi API kljuc."""
    print("\n[3/6] Postavljanje API kljuca...")

    # Provjeri da li vec postoji
    existing = os.getenv("ANTHROPIC_API_KEY")
    if existing and existing.startswith("sk-ant-"):
        print(f"  [OK] API kljuc vec postavljen: {existing[:20]}...")
        return True

    print("  Unesi svoj Anthropic API kljuc (sk-ant-...):")
    print("  (mozes ga naci na console.anthropic.com)")
    api_key = input("  > ").strip()

    if not api_key.startswith("sk-ant-"):
        print("  [!] Nevazeci format kljuca")
        return False

    # Kreiraj .env file
    env_file = Path(__file__).parent / ".env"
    with open(env_file, "w") as f:
        f.write(f"ANTHROPIC_API_KEY={api_key}\n")

    print(f"  [OK] API kljuc spremljen u .env")

    # Kreiraj run.bat koji ucitava .env
    create_run_script(api_key)

    return True

def find_mt5_folder():
    """Pronadi MT5 instalaciju."""
    print("\n[4/6] Trazim MT5 instalaciju...")

    # Moguce lokacije
    appdata = os.environ.get("APPDATA", "")
    base_path = Path(appdata) / "MetaQuotes" / "Terminal"

    if not base_path.exists():
        print(f"  [!] Ne mogu pronaci MT5: {base_path}")
        return None

    # Pronadi sve terminale
    terminals = [d for d in base_path.iterdir() if d.is_dir() and len(d.name) == 32]

    if not terminals:
        print("  [!] Nema instaliranih MT5 terminala")
        return None

    if len(terminals) == 1:
        terminal = terminals[0]
        print(f"  [OK] Pronaden terminal: {terminal.name[:16]}...")
        return terminal

    # Vise terminala - pitaj korisnika
    print(f"  [*] Pronadeno {len(terminals)} terminala:")
    for i, t in enumerate(terminals):
        # Pokusaj pronaci ime brokera
        origin_file = t / "origin.txt"
        broker = "Unknown"
        if origin_file.exists():
            broker = origin_file.read_text().strip()[:30]
        print(f"      {i+1}. {broker}")

    choice = input("  Odaberi terminal (1-{}): ".format(len(terminals))).strip()
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(terminals):
            return terminals[idx]
    except ValueError:
        pass

    print("  [!] Nevazeci odabir")
    return None

def copy_mq5_file(terminal_path):
    """Kopiraj MQ5 fajl u MT5."""
    print("\n[5/6] Kopiram Clawder_Bridge.mq5...")

    if terminal_path is None:
        print("  [!] Preskačem - MT5 nije pronađen")
        print("  [*] Rucno kopiraj Clawder_Bridge.mq5 u MQL5/Experts/")
        return False

    source = Path(__file__).parent / "Clawder_Bridge.mq5"
    dest_folder = terminal_path / "MQL5" / "Experts"
    dest = dest_folder / "Clawder_Bridge.mq5"

    if not source.exists():
        print(f"  [!] Ne mogu pronaci: {source}")
        return False

    if not dest_folder.exists():
        print(f"  [!] Ne postoji: {dest_folder}")
        return False

    shutil.copy2(source, dest)
    print(f"  [OK] Kopirano u: {dest}")

    return True

def create_run_script(api_key=None):
    """Kreiraj run.bat za lako pokretanje."""
    print("\n[6/6] Kreiram run.bat...")

    script_dir = Path(__file__).parent
    bat_file = script_dir / "run_clawder.bat"

    # Ucitaj API key iz .env ako nije proslijeden
    if api_key is None:
        env_file = script_dir / ".env"
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                if line.startswith("ANTHROPIC_API_KEY="):
                    api_key = line.split("=", 1)[1]
                    break

    content = f'''@echo off
echo ============================================================
echo   CLAWDER BRAIN v2.0
echo ============================================================
echo.

cd /d "{script_dir}"

set ANTHROPIC_API_KEY={api_key or "POSTAVI_OVDJE"}

python clawder_brain.py

pause
'''

    with open(bat_file, "w") as f:
        f.write(content)

    print(f"  [OK] Kreirano: {bat_file}")
    return True

def print_next_steps(mt5_found):
    """Ispisi sljedece korake."""
    print()
    print("=" * 60)
    print("  SETUP ZAVRSEN!")
    print("=" * 60)
    print()
    print("Sljedeci koraci:")
    print()

    step = 1

    if not mt5_found:
        print(f"  {step}. Rucno kopiraj Clawder_Bridge.mq5 u MT5:")
        print("     MQL5/Experts/Clawder_Bridge.mq5")
        step += 1

    print(f"  {step}. Otvori MetaEditor (F4 u MT5)")
    print(f"     - Otvori Clawder_Bridge.mq5")
    print(f"     - Klikni Compile (F7)")
    step += 1

    print(f"  {step}. U MT5:")
    print(f"     - Otvori XAUUSD M5 chart")
    print(f"     - Drag & drop Clawder_Bridge EA na chart")
    print(f"     - Ukljuci AutoTrading")
    step += 1

    print(f"  {step}. Pokreni Clawder Brain:")
    print(f"     - Dvostruki klik na run_clawder.bat")
    print()
    print("=" * 60)

def main():
    print_header()

    # 1. Python
    check_python()

    # 2. Anthropic
    if not install_anthropic():
        print("\n[!] Setup prekinut - ne mogu instalirati anthropic")
        return

    # 3. API Key
    if not setup_api_key():
        print("\n[!] Setup prekinut - API kljuc nije postavljen")
        return

    # 4. Find MT5
    terminal = find_mt5_folder()

    # 5. Copy MQ5
    mt5_ok = copy_mq5_file(terminal)

    # 6. Create run script (already done in setup_api_key)
    if not (Path(__file__).parent / "run_clawder.bat").exists():
        create_run_script()

    # Done
    print_next_steps(mt5_ok)

if __name__ == "__main__":
    main()
