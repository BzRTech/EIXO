@echo off
title WebGIS - Parando...
color 0C

cd /d "%~dp0"

echo.
echo  [>>] Parando containers WebGIS...
echo.

docker compose -f docker-compose.dev.yml down

echo.
echo  [OK] Stack parado. Dados do PostgreSQL preservados.
echo.
pause
