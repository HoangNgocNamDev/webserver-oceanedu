@echo off
REM Generate wildcard SSL certificate for *.oceanedu.local using mkcert
REM mkcert automatically creates a trusted certificate (no manual install needed)

if not exist "%ProgramFiles%\mkcert\mkcert.exe" if not exist mkcert.exe (
    echo [ERROR] mkcert not found!
    echo.
    echo Install mkcert:
    echo   1. Download from: https://github.com/FiloSottile/mkcert/releases
    echo   2. Or use: winget install FiloSottile.mkcert
    echo   3. Or use: choco install mkcert
    echo   4. Then run: mkcert -install
    echo.
    echo Alternative: Use generate-ssl-openssl.bat for OpenSSL-based generation
    goto :eof
)

REM Check which mkcert to use
set MK=mkcert.exe
where mkcert >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set MK=mkcert
) else if exist mkcert.exe (
    set MK=mkcert.exe
)

REM Generate wildcard certificate for *.oceanedu.local
%MK% "*.oceanedu.local" "oceanedu.local"

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ============================================
    echo Wildcard SSL certificate generated successfully!
    echo Cover: *.oceanedu.local, oceanedu.local
    echo.
    echo Files created in ssl/ directory:
    echo   _wildcard.oceanedu.local+1.pem     (certificate^)
    echo   _wildcard.oceanedu.local+1-key.pem (private key^)
    echo.
    echo Update nginx.conf to use:
    echo   ssl_certificate     /etc/nginx/ssl/_wildcard.oceanedu.local+1.pem;
    echo   ssl_certificate_key /etc/nginx/ssl/_wildcard.oceanedu.local+1-key.pem;
    echo ============================================
) else (
    echo [ERROR] mkcert failed to generate certificate.
    echo Make sure mkcert -install has been run first.
)
