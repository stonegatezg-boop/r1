@echo off
cd /d "%~dp0"
echo.
echo ============================================================
echo   CLAWDER v2.0 - VPS DEPLOYMENT
echo ============================================================
echo.
echo Ova skripta postavlja Clawder za rad na Windows VPS-u.
echo.
echo VAZNO: Za Windows Service i Task Scheduler,
echo        pokreni ovaj fajl kao Administrator!
echo.
echo        (Desni klik -> Run as administrator)
echo.
echo ============================================================
echo.

python vps_setup.py

echo.
pause
