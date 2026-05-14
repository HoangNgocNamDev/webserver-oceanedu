#!/bin/bash
# Generate wildcard SSL certificate for *.oceanedu.local using mkcert
# mkcert automatically creates a trusted certificate (no manual install needed)

if ! command -v mkcert &> /dev/null && [ ! -f ./mkcert ]; then
    echo "[ERROR] mkcert not found!"
    echo ""
    echo "Install mkcert:"
    echo "  macOS:   brew install mkcert"
    echo "  Linux:   sudo apt install mkcert (or use your package manager)"
    echo "  Windows: winget install FiloSottile.mkcert | choco install mkcert"
    echo ""
    echo "  After install, run: mkcert -install"
    echo ""
    echo "Alternative: Use generate-ssl-openssl.sh for OpenSSL-based generation"
    exit 1
fi

# Use local mkcert or system mkcert
MK="mkcert"
if [ -f ./mkcert.exe ]; then
    MK="./mkcert.exe"
elif [ -f ./mkcert ]; then
    MK="./mkcert"
fi

# Generate wildcard certificate for *.oceanedu.local
$MK "*.oceanedu.local" "oceanedu.local"

if [ $? -eq 0 ]; then
    echo ""
    echo "============================================"
    echo "Wildcard SSL certificate generated successfully!"
    echo "Cover: *.oceanedu.local, oceanedu.local"
    echo ""
    echo "Files created in ssl/ directory:"
    echo "  _wildcard.oceanedu.local+1.pem     (certificate)"
    echo "  _wildcard.oceanedu.local+1-key.pem (private key)"
    echo ""
    echo "Update nginx.conf to use:"
    echo "  ssl_certificate     /etc/nginx/ssl/_wildcard.oceanedu.local+1.pem;"
    echo "  ssl_certificate_key /etc/nginx/ssl/_wildcard.oceanedu.local+1-key.pem;"
    echo "============================================"
else
    echo "[ERROR] mkcert failed to generate certificate."
    echo "Make sure 'mkcert -install' has been run first."
    exit 1
fi
