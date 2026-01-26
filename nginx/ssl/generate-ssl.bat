@echo off
REM Generate self-signed SSL certificate for *.oceanedu.local

REM Create OpenSSL config file
(
echo [req]
echo default_bits = 2048
echo prompt = no
echo default_md = sha256
echo distinguished_name = dn
echo x509_extensions = v3_req
echo.
echo [dn]
echo CN = *.oceanedu.local
echo.
echo [v3_req]
echo subjectAltName = @alt_names
echo.
echo [alt_names]
echo DNS.1 = *.oceanedu.local
echo DNS.2 = oceanedu.local
) > openssl.cnf

REM Generate certificate using Git Bash's OpenSSL (common on Windows)
where openssl >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -config openssl.cnf
) else (
    echo OpenSSL not found in PATH.
    echo.
    echo Option 1: Use Git Bash
    echo   Run this in Git Bash: ./generate-ssl.sh
    echo.
    echo Option 2: Install OpenSSL
    echo   Download from: https://slproweb.com/products/Win32OpenSSL.html
    echo.
    echo Option 3: Use WSL
    echo   wsl openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=*.oceanedu.local" -addext "subjectAltName=DNS:*.oceanedu.local,DNS:oceanedu.local"
    goto :cleanup
)

echo.
echo SSL certificate generated successfully!
echo Files created: key.pem, cert.pem
echo.
echo To trust this certificate on Windows:
echo 1. Double-click cert.pem
echo 2. Click 'Install Certificate'
echo 3. Choose 'Local Machine' then 'Next'
echo 4. Select 'Place all certificates in the following store'
echo 5. Browse and select 'Trusted Root Certification Authorities'
echo 6. Click 'Next' then 'Finish'

:cleanup
del openssl.cnf 2>nul
