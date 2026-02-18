"""
Clawder VPS Setup Script
Kompletna instalacija za Windows VPS sa Service + Task Scheduler podrskom.

Opcije deployementa:
1. Windows Service (NSSM) - radi u pozadini, automatski restart
2. Task Scheduler - pokrece se pri loginu/startupu
3. Batch file - rucno pokretanje

Autor: Clawder Team
"""

import os
import sys
import subprocess
import shutil
import ctypes
import urllib.request
import zipfile
import winreg
from pathlib import Path
from datetime import datetime

# ============================================================
# KONFIGURACIJA
# ============================================================

NSSM_URL = "https://nssm.cc/release/nssm-2.24.zip"
NSSM_DIR = "nssm-2.24"
SERVICE_NAME = "ClawderBrain"
SERVICE_DISPLAY = "Clawder Trading Brain"
SERVICE_DESC = "AI-powered trading brain for MT5 - Claude AI integration"

# ============================================================
# POMOCNE FUNKCIJE
# ============================================================

def is_admin():
    """Provjeri da li skripta ima admin prava."""
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False

def run_as_admin():
    """Pokreni skriptu kao administrator."""
    if sys.platform == 'win32':
        ctypes.windll.shell32.ShellExecuteW(
            None, "runas", sys.executable, " ".join(sys.argv), None, 1
        )
        sys.exit()

def print_header():
    print()
    print("=" * 60)
    print("  CLAWDER v2.0 - VPS DEPLOYMENT")
    print("=" * 60)
    print()

def print_section(title):
    print()
    print(f"--- {title} ---")
    print()

def get_script_dir():
    """Dobij direktorij gdje se skripta nalazi."""
    return Path(__file__).parent.resolve()

def load_env_file():
    """Ucitaj .env fajl ako postoji."""
    env_file = get_script_dir() / ".env"
    env_vars = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env_vars[key.strip()] = value.strip()
    return env_vars

def save_env_file(env_vars):
    """Spremi .env fajl."""
    env_file = get_script_dir() / ".env"
    lines = [f"{k}={v}" for k, v in env_vars.items()]
    env_file.write_text("\n".join(lines) + "\n")

# ============================================================
# PROVJERE SISTEMA
# ============================================================

def check_python():
    """Provjeri Python verziju."""
    print("[*] Provjera Python verzije...")
    version = sys.version_info
    if version.major >= 3 and version.minor >= 8:
        print(f"    [OK] Python {version.major}.{version.minor}.{version.micro}")
        return True
    else:
        print(f"    [!] Python {version.major}.{version.minor} - potrebno 3.8+")
        return False

def check_anthropic():
    """Provjeri i instaliraj anthropic library."""
    print("[*] Provjera anthropic library...")
    try:
        import anthropic
        print(f"    [OK] anthropic instaliran")
        return True
    except ImportError:
        print("    [*] Instaliram anthropic...")
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "anthropic"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            print("    [OK] anthropic instaliran")
            return True
        else:
            print(f"    [!] Greska: {result.stderr}")
            return False

def check_api_key():
    """Provjeri ili postavi API kljuc."""
    print("[*] Provjera API kljuca...")

    # Ucitaj iz .env ako postoji
    env_vars = load_env_file()
    api_key = env_vars.get("ANTHROPIC_API_KEY") or os.getenv("ANTHROPIC_API_KEY")

    if api_key and api_key.startswith("sk-ant-"):
        print(f"    [OK] API kljuc pronadjen: {api_key[:20]}...")
        return api_key

    print("    [?] Unesi Anthropic API kljuc (sk-ant-...):")
    api_key = input("        > ").strip()

    if not api_key.startswith("sk-ant-"):
        print("    [!] Nevazeci format kljuca!")
        return None

    # Spremi u .env
    env_vars["ANTHROPIC_API_KEY"] = api_key
    save_env_file(env_vars)
    print(f"    [OK] API kljuc spremljen u .env")

    return api_key

def find_mt5_common_files():
    """Pronadi MT5 Common/Files direktorij."""
    print("[*] Trazim MT5 Common/Files direktorij...")

    appdata = os.environ.get("APPDATA", "")
    common_files = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"

    if common_files.exists():
        print(f"    [OK] {common_files}")
        return common_files
    else:
        print(f"    [!] Ne postoji: {common_files}")
        return None

def find_mt5_terminals():
    """Pronadi MT5 terminale."""
    print("[*] Trazim MT5 terminale...")

    appdata = os.environ.get("APPDATA", "")
    base_path = Path(appdata) / "MetaQuotes" / "Terminal"

    if not base_path.exists():
        print(f"    [!] Ne mogu pronaci MT5: {base_path}")
        return []

    terminals = []
    for d in base_path.iterdir():
        if d.is_dir() and len(d.name) == 32:
            # Pronadi broker iz origin.txt
            origin_file = d / "origin.txt"
            broker = "Unknown"
            if origin_file.exists():
                try:
                    broker = origin_file.read_text().strip()[:40]
                except:
                    pass
            terminals.append({"path": d, "broker": broker, "hash": d.name})

    if terminals:
        print(f"    [OK] Pronadeno {len(terminals)} terminal(a)")
        for t in terminals:
            print(f"        - {t['broker']}")
    else:
        print("    [!] Nema instaliranih MT5 terminala")

    return terminals

# ============================================================
# NSSM DOWNLOAD & INSTALL
# ============================================================

def download_nssm():
    """Preuzmi NSSM (Non-Sucking Service Manager)."""
    print("[*] Preuzimam NSSM...")

    script_dir = get_script_dir()
    nssm_exe = script_dir / "nssm.exe"

    if nssm_exe.exists():
        print(f"    [OK] NSSM vec postoji: {nssm_exe}")
        return nssm_exe

    # Preuzmi ZIP
    zip_path = script_dir / "nssm.zip"
    print(f"    [*] Preuzimam sa {NSSM_URL}...")

    try:
        urllib.request.urlretrieve(NSSM_URL, zip_path)
        print("    [OK] Download zavrsen")
    except Exception as e:
        print(f"    [!] Greska pri preuzimanju: {e}")
        return None

    # Raspakiraj
    print("    [*] Raspakiravam...")
    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(script_dir)

        # Kopiraj 64-bit verziju
        nssm_src = script_dir / NSSM_DIR / "win64" / "nssm.exe"
        if not nssm_src.exists():
            nssm_src = script_dir / NSSM_DIR / "win32" / "nssm.exe"

        shutil.copy2(nssm_src, nssm_exe)
        print(f"    [OK] NSSM instaliran: {nssm_exe}")

        # Ocisti
        zip_path.unlink()
        shutil.rmtree(script_dir / NSSM_DIR)

        return nssm_exe

    except Exception as e:
        print(f"    [!] Greska pri raspakiravanju: {e}")
        return None

# ============================================================
# WINDOWS SERVICE
# ============================================================

def install_windows_service(api_key):
    """Instaliraj Clawder kao Windows Service."""
    print_section("WINDOWS SERVICE INSTALACIJA")

    if not is_admin():
        print("[!] Potrebna su administratorska prava!")
        print("    Pokreni cmd kao Administrator i ponovi.")
        return False

    script_dir = get_script_dir()
    nssm_exe = download_nssm()

    if not nssm_exe:
        print("[!] Ne mogu instalirati bez NSSM")
        return False

    # Kreiraj wrapper batch koji postavlja environment
    wrapper_bat = script_dir / "clawder_service.bat"
    wrapper_content = f'''@echo off
cd /d "{script_dir}"
set ANTHROPIC_API_KEY={api_key}
"{sys.executable}" clawder_brain.py
'''
    wrapper_bat.write_text(wrapper_content)
    print(f"[*] Kreiran service wrapper: {wrapper_bat}")

    # Zaustavi i ukloni postojeci servis ako postoji
    print(f"[*] Uklanjam postojeci servis '{SERVICE_NAME}' ako postoji...")
    subprocess.run([str(nssm_exe), "stop", SERVICE_NAME],
                   capture_output=True)
    subprocess.run([str(nssm_exe), "remove", SERVICE_NAME, "confirm"],
                   capture_output=True)

    # Instaliraj servis
    print(f"[*] Instaliram servis '{SERVICE_NAME}'...")

    result = subprocess.run([
        str(nssm_exe), "install", SERVICE_NAME, str(wrapper_bat)
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[!] Greska pri instalaciji: {result.stderr}")
        return False

    # Konfiguriraj servis
    print("[*] Konfiguriram servis...")

    # Display name
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "DisplayName", SERVICE_DISPLAY],
                   capture_output=True)

    # Description
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "Description", SERVICE_DESC],
                   capture_output=True)

    # Startup type: Automatic
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "Start", "SERVICE_AUTO_START"],
                   capture_output=True)

    # Restart on failure
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "AppRestartDelay", "5000"],
                   capture_output=True)

    # Log files
    log_dir = script_dir / "logs"
    log_dir.mkdir(exist_ok=True)
    stdout_log = log_dir / "service_stdout.log"
    stderr_log = log_dir / "service_stderr.log"

    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "AppStdout", str(stdout_log)],
                   capture_output=True)
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "AppStderr", str(stderr_log)],
                   capture_output=True)

    # Rotate logs
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "AppStdoutCreationDisposition", "4"],
                   capture_output=True)
    subprocess.run([str(nssm_exe), "set", SERVICE_NAME, "AppStderrCreationDisposition", "4"],
                   capture_output=True)

    print(f"[OK] Servis '{SERVICE_NAME}' instaliran!")
    print()
    print("    Kontrola servisa:")
    print(f"      Start:   nssm start {SERVICE_NAME}")
    print(f"      Stop:    nssm stop {SERVICE_NAME}")
    print(f"      Status:  nssm status {SERVICE_NAME}")
    print(f"      Ukloni:  nssm remove {SERVICE_NAME} confirm")
    print()
    print(f"    Logovi: {log_dir}")

    # Pokreni servis
    print()
    choice = input("Zelite li pokrenuti servis sada? (d/n): ").strip().lower()
    if choice == 'd':
        result = subprocess.run([str(nssm_exe), "start", SERVICE_NAME],
                               capture_output=True, text=True)
        if "started" in result.stdout.lower() or result.returncode == 0:
            print(f"[OK] Servis pokrenut!")
        else:
            print(f"[!] Greska: {result.stderr or result.stdout}")

    return True

def uninstall_windows_service():
    """Ukloni Windows Service."""
    print_section("UKLANJANJE WINDOWS SERVISA")

    if not is_admin():
        print("[!] Potrebna su administratorska prava!")
        return False

    script_dir = get_script_dir()
    nssm_exe = script_dir / "nssm.exe"

    if not nssm_exe.exists():
        print("[!] NSSM nije instaliran")
        return False

    print(f"[*] Zaustavljam servis '{SERVICE_NAME}'...")
    subprocess.run([str(nssm_exe), "stop", SERVICE_NAME], capture_output=True)

    print(f"[*] Uklanjam servis '{SERVICE_NAME}'...")
    result = subprocess.run([str(nssm_exe), "remove", SERVICE_NAME, "confirm"],
                           capture_output=True, text=True)

    if result.returncode == 0:
        print(f"[OK] Servis uklonjen")
        return True
    else:
        print(f"[!] Greska: {result.stderr or result.stdout}")
        return False

# ============================================================
# TASK SCHEDULER
# ============================================================

def install_task_scheduler(api_key):
    """Postavi Task Scheduler za automatsko pokretanje."""
    print_section("TASK SCHEDULER KONFIGURACIJA")

    if not is_admin():
        print("[!] Potrebna su administratorska prava!")
        return False

    script_dir = get_script_dir()
    task_name = "ClawderBrainStartup"

    # Kreiraj VBS wrapper za tiho pokretanje (bez CMD prozora)
    vbs_file = script_dir / "run_clawder_hidden.vbs"
    vbs_content = f'''Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "{script_dir}"
WshShell.Environment("Process")("ANTHROPIC_API_KEY") = "{api_key}"
WshShell.Run """{sys.executable}"" clawder_brain.py", 0, False
'''
    vbs_file.write_text(vbs_content)
    print(f"[*] Kreiran VBS launcher: {vbs_file}")

    # Ukloni postojeci task
    print(f"[*] Uklanjam postojeci task '{task_name}' ako postoji...")
    subprocess.run(
        ["schtasks", "/delete", "/tn", task_name, "/f"],
        capture_output=True
    )

    # Kreiraj novi task
    print(f"[*] Kreiram Task Scheduler task '{task_name}'...")

    # Task ce se pokrenuti:
    # - Pri loginu bilo kojeg korisnika
    # - Sa highest privileges
    # - Neograniceno trajanje

    result = subprocess.run([
        "schtasks", "/create",
        "/tn", task_name,
        "/tr", f'wscript.exe "{vbs_file}"',
        "/sc", "onlogon",
        "/rl", "highest",
        "/f"
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[!] Greska: {result.stderr}")
        return False

    print(f"[OK] Task '{task_name}' kreiran!")
    print()
    print("    Task se pokrece automatski pri loginu.")
    print()
    print("    Kontrola:")
    print(f"      Pokreni:  schtasks /run /tn {task_name}")
    print(f"      Zaustavi: taskkill /im python.exe /f")
    print(f"      Ukloni:   schtasks /delete /tn {task_name} /f")

    # Opcija da se pokrene odmah
    print()
    choice = input("Zelite li pokrenuti task sada? (d/n): ").strip().lower()
    if choice == 'd':
        subprocess.run(["schtasks", "/run", "/tn", task_name], capture_output=True)
        print("[OK] Task pokrenut!")

    return True

def uninstall_task_scheduler():
    """Ukloni Task Scheduler task."""
    print_section("UKLANJANJE TASK SCHEDULER TASK-A")

    task_name = "ClawderBrainStartup"

    print(f"[*] Uklanjam task '{task_name}'...")
    result = subprocess.run(
        ["schtasks", "/delete", "/tn", task_name, "/f"],
        capture_output=True, text=True
    )

    if result.returncode == 0:
        print(f"[OK] Task uklonjen")
        return True
    else:
        print(f"[!] Greska ili task ne postoji")
        return False

# ============================================================
# MQ5 COPY
# ============================================================

def copy_mq5_to_terminals(terminals):
    """Kopiraj MQ5 fajl u sve MT5 terminale."""
    print_section("KOPIRANJE MQ5 FAJLA")

    source = get_script_dir() / "Clawder_Bridge.mq5"

    if not source.exists():
        print(f"[!] Ne mogu pronaci: {source}")
        return False

    if not terminals:
        print("[!] Nema MT5 terminala za kopiranje")
        print(f"    Rucno kopiraj {source.name} u MQL5/Experts/")
        return False

    for terminal in terminals:
        dest_folder = terminal["path"] / "MQL5" / "Experts"
        if dest_folder.exists():
            dest = dest_folder / "Clawder_Bridge.mq5"
            shutil.copy2(source, dest)
            print(f"[OK] Kopirano u: {terminal['broker']}")
        else:
            print(f"[!] Ne postoji: {dest_folder}")

    return True

# ============================================================
# BATCH FILE (RUCNO POKRETANJE)
# ============================================================

def create_batch_file(api_key):
    """Kreiraj batch file za rucno pokretanje."""
    print_section("KREIRANJE BATCH FAJLA")

    script_dir = get_script_dir()
    bat_file = script_dir / "run_clawder.bat"

    content = f'''@echo off
echo ============================================================
echo   CLAWDER BRAIN v2.0
echo ============================================================
echo.
echo Pokrecem Clawder Brain...
echo Za izlaz pritisnite Ctrl+C
echo.

cd /d "{script_dir}"
set ANTHROPIC_API_KEY={api_key}

:loop
python clawder_brain.py
echo.
echo [!] Clawder se restartuje za 10 sekundi...
timeout /t 10 /nobreak >nul
goto loop
'''

    bat_file.write_text(content)
    print(f"[OK] Kreiran: {bat_file}")

    return True

# ============================================================
# GLAVNI MENI
# ============================================================

def main_menu():
    """Glavni izbornik."""
    while True:
        print_header()
        print("Odaberi opciju:")
        print()
        print("  1. KOMPLETNA INSTALACIJA (preporuceno)")
        print("     - Sve provjere + Windows Service + Task Scheduler")
        print()
        print("  2. Samo Windows Service")
        print("     - Radi u pozadini, automatski restart")
        print()
        print("  3. Samo Task Scheduler")
        print("     - Pokrece se pri loginu")
        print()
        print("  4. Samo Batch File")
        print("     - Za rucno pokretanje")
        print()
        print("  5. Ukloni sve (uninstall)")
        print()
        print("  0. Izlaz")
        print()

        choice = input("Odabir [1-5, 0]: ").strip()

        if choice == "0":
            print("\nDovidenja!")
            break
        elif choice == "1":
            full_installation()
        elif choice == "2":
            service_only_installation()
        elif choice == "3":
            scheduler_only_installation()
        elif choice == "4":
            batch_only_installation()
        elif choice == "5":
            uninstall_all()
        else:
            print("\n[!] Nevazeci odabir")
            input("Pritisnite Enter za nastavak...")

def full_installation():
    """Kompletna instalacija."""
    print_section("KOMPLETNA INSTALACIJA")

    # Provjere
    if not check_python():
        return

    if not check_anthropic():
        return

    api_key = check_api_key()
    if not api_key:
        return

    mt5_files = find_mt5_common_files()
    terminals = find_mt5_terminals()

    # Kopiraj MQ5
    copy_mq5_to_terminals(terminals)

    # Batch file (uvijek)
    create_batch_file(api_key)

    # Service ili Task Scheduler
    print()
    print("Odaberi nacin pokretanja:")
    print("  1. Windows Service (preporuceno za VPS)")
    print("  2. Task Scheduler")
    print("  3. Oba")

    choice = input("Odabir [1-3]: ").strip()

    if choice in ["1", "3"]:
        install_windows_service(api_key)

    if choice in ["2", "3"]:
        install_task_scheduler(api_key)

    print_final_instructions(mt5_files)

def service_only_installation():
    """Samo Windows Service."""
    if not check_anthropic():
        return

    api_key = check_api_key()
    if not api_key:
        return

    install_windows_service(api_key)

def scheduler_only_installation():
    """Samo Task Scheduler."""
    if not check_anthropic():
        return

    api_key = check_api_key()
    if not api_key:
        return

    install_task_scheduler(api_key)

def batch_only_installation():
    """Samo batch file."""
    if not check_anthropic():
        return

    api_key = check_api_key()
    if not api_key:
        return

    create_batch_file(api_key)

    print()
    print("Za pokretanje dvostruko klikni na run_clawder.bat")

def uninstall_all():
    """Ukloni sve."""
    print_section("UKLANJANJE")

    print("Ovo ce ukloniti:")
    print("  - Windows Service (ClawderBrain)")
    print("  - Task Scheduler task (ClawderBrainStartup)")
    print()

    confirm = input("Sigurni ste? (da/ne): ").strip().lower()
    if confirm != "da":
        print("Prekinuto.")
        return

    uninstall_windows_service()
    uninstall_task_scheduler()

    print()
    print("[OK] Sve uklonjeno!")
    print("     Batch fajlovi i .env ostaju za rucno pokretanje.")

def print_final_instructions(mt5_files):
    """Ispisi finalne instrukcije."""
    print()
    print("=" * 60)
    print("  INSTALACIJA ZAVRSENA!")
    print("=" * 60)
    print()
    print("PREOSTALI KORACI U MT5:")
    print()
    print("  1. Otvori MetaEditor (F4 u MT5)")
    print("  2. Otvori Clawder_Bridge.mq5")
    print("  3. Klikni Compile (F7)")
    print()
    print("  4. U MT5:")
    print("     - Otvori XAUUSD M5 chart")
    print("     - Drag & drop Clawder_Bridge EA na chart")
    print("     - Ukljuci AutoTrading (gornji toolbar)")
    print()
    print("PROVJERA RADA:")
    print()
    if mt5_files:
        print(f"  CSV lokacija: {mt5_files}")
    print("  Logovi: ./logs/clawder_YYYYMMDD.log")
    print("  Service logovi: ./logs/service_stdout.log")
    print()
    print("=" * 60)
    print()
    input("Pritisnite Enter za izlaz...")

# ============================================================
# MAIN
# ============================================================

if __name__ == "__main__":
    # Provjeri OS
    if sys.platform != 'win32':
        print("[!] Ova skripta je samo za Windows!")
        print("    Za Linux koristite systemd ili screen/tmux.")
        sys.exit(1)

    # Provjeri admin prava za neke operacije
    if not is_admin():
        print()
        print("[!] NAPOMENA: Za Service/Task Scheduler potrebna su admin prava.")
        print("    Pokreni CMD kao Administrator ako zelis te opcije.")
        print()

    main_menu()
