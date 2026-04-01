@echo off
:: ============================================================
:: START.bat — Inicia o WebGIS localmente no Windows
:: Duplo-clique neste arquivo para subir o stack
:: ============================================================

title WebGIS - Iniciando...
color 0A

echo.
echo  ██╗    ██╗███████╗██████╗  ██████╗ ██╗███████╗
echo  ██║    ██║██╔════╝██╔══██╗██╔════╝ ██║██╔════╝
echo  ██║ █╗ ██║█████╗  ██████╔╝██║  ███╗██║███████╗
echo  ██║███╗██║██╔══╝  ██╔══██╗██║   ██║██║╚════██║
echo  ╚███╔███╔╝███████╗██████╔╝╚██████╔╝██║███████║
echo   ╚══╝╚══╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝╚══════╝
echo.
echo  Stack: PostGIS + Martin + Varnish + PgBouncer
echo  Custo em producao: ~R$126/mes (Vultr Sao Paulo)
echo.

:: Verifica se Docker está rodando
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERRO] Docker nao esta rodando!
    echo  Abra o Docker Desktop e tente novamente.
    pause
    exit /b 1
)

echo  [OK] Docker detectado
echo.

:: Vai para o diretório do script
cd /d "%~dp0"

echo  [>>] Baixando imagens e subindo containers...
echo       Primeira vez pode demorar 2-5 minutos.
echo.

docker compose -f docker-compose.dev.yml up -d --build

if %errorlevel% neq 0 (
    echo.
    echo  [ERRO] Falha ao iniciar. Verifique os logs:
    echo  docker compose -f docker-compose.dev.yml logs
    pause
    exit /b 1
)

echo.
echo  [>>] Aguardando PostGIS ficar pronto...
timeout /t 15 /nobreak >nul

echo.
echo  ============================================
echo   WebGIS rodando! Acesse:
echo  ============================================
echo.
echo   Mapa principal:  http://localhost
echo   Martin (tiles):  http://localhost:3000/catalog
echo   Varnish cache:   http://localhost:6081
echo   Uptime Kuma:     http://localhost:3001
echo   Netdata:         http://localhost:19999
echo   PostGIS (porta): localhost:5433
echo.
echo  ============================================

:: Abre o browser automaticamente
echo  [>>] Abrindo o mapa no browser...
timeout /t 3 /nobreak >nul
start http://localhost

echo.
echo  Para parar: execute STOP.bat
echo  Para ver logs: docker compose -f docker-compose.dev.yml logs -f
echo.
pause
