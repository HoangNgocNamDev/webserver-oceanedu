#!/bin/bash
# Generate self-signed SSL certificate for *.oceanedu.local

# Create OpenSSL config file
cat > openssl.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = *.oceanedu.local

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.oceanedu.local
DNS.2 = oceanedu.local
EOF

# Generate certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout key.pem \
    -out cert.pem \
    -config openssl.cnf

# Clean up
rm openssl.cnf

echo "SSL certificate generated successfully!"
echo "Files created: key.pem, cert.pem"
echo ""
echo "To trust this certificate on Windows:"
echo "1. Double-click cert.pem"
echo "2. Click 'Install Certificate'"
echo "3. Choose 'Local Machine' -> 'Next'"
echo "4. Select 'Place all certificates in the following store'"
echo "5. Browse and select 'Trusted Root Certification Authorities'"
echo "6. Click 'Next' -> 'Finish'"
