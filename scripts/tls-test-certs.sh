#!/bin/bash
# Test certificates for the TLS live tests and UI checks. Regenerates everything on each run.
# Output goes to a `.dbtest/tls` folder next to the repository (override with FOXLUME_TLS_DIR); nothing here is
# committed. Uses /usr/bin/openssl (LibreSSL on macOS).
#
#   scripts/tls-test-certs.sh
#
# ca.crt / ca.key                  "Foxlume Test CA", signs everything below unless noted
# other-ca.crt / other-ca.key      "Foxlume Other CA", for wrong-CA tests
# server.crt / server.key          CN localhost, SAN DNS:localhost only (so 127.0.0.1 is a host name mismatch)
# client.crt / client.key          CN certuser, clientAuth (RSA 2048, unencrypted PKCS#8)
# client-chain.crt                 client.crt followed by ca.crt
# client-pkcs8-enc.key             client.key as encrypted PKCS#8 (PBES2, PBKDF2, AES-256-CBC), passphrase "secret"
# client-legacy-enc.key            client.key as traditional "RSA PRIVATE KEY" with AES-256-CBC, passphrase "secret"
# client-rsa.key                   client.key as traditional unencrypted "RSA PRIVATE KEY"
# client.p12                       client.crt + client.key + ca.crt, password "secret"
# client-ec.crt / client-ec.key    CN certuser, EC P-256 (SEC1 "EC PRIVATE KEY")
# other-client.crt / .key          CN certuser, signed by the other CA (the servers reject it)
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
OUT="${FOXLUME_TLS_DIR:-$(cd "$SCRIPTS/../.." && pwd)/.dbtest/tls}"
OPENSSL=/usr/bin/openssl
mkdir -p "$OUT"
cd "$OUT"
rm -f ./*.crt ./*.key ./*.p12 ./*.csr ./*.srl ./*.ext

ca() { # name subject
  "$OPENSSL" genrsa -out "$1.key" 2048 2>/dev/null
  cat > "$1.ext" <<EOF
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -new -key "$1.key" -subj "$2" -out "$1.csr" 2>/dev/null
  "$OPENSSL" x509 -req -in "$1.csr" -signkey "$1.key" -days 3650 -sha256 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}

leaf() { # name subject issuer extensions [keyfile]
  if [ -z "${5:-}" ]; then "$OPENSSL" genrsa -out "$1.key" 2048 2>/dev/null; fi
  printf '%b\n' "$4" > "$1.ext"
  "$OPENSSL" req -new -key "$1.key" -subj "$2" -out "$1.csr" 2>/dev/null
  "$OPENSSL" x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial -days 3650 -sha256 \
    -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}

ca ca "/O=Foxlume Query Tests/CN=Foxlume Test CA"
ca other-ca "/O=Foxlume Query Tests/CN=Foxlume Other CA"

SERVER_EXT='basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:localhost'
CLIENT_EXT='basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = clientAuth'

leaf server "/O=Foxlume Query Tests/CN=localhost" ca "$SERVER_EXT"
leaf client "/O=Foxlume Query Tests/CN=certuser" ca "$CLIENT_EXT"
leaf other-client "/O=Foxlume Query Tests/CN=certuser" other-ca "$CLIENT_EXT"

"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out client-ec.key 2>/dev/null
leaf client-ec "/O=Foxlume Query Tests/CN=certuser" ca "$CLIENT_EXT" existing

# Key encodings: genrsa may write either format depending on the OpenSSL flavor, so normalize.
"$OPENSSL" pkcs8 -topk8 -nocrypt -in client.key -out client-pkcs8.key
mv client-pkcs8.key client.key
"$OPENSSL" rsa -in client.key -out client-rsa.key 2>/dev/null
"$OPENSSL" pkcs8 -topk8 -in client.key -v2 aes-256-cbc -passout pass:secret -out client-pkcs8-enc.key
"$OPENSSL" rsa -in client.key -aes256 -passout pass:secret -out client-legacy-enc.key 2>/dev/null
cat client.crt ca.crt > client-chain.crt
"$OPENSSL" pkcs12 -export -in client.crt -inkey client.key -certfile ca.crt -name "Foxlume test client" \
  -passout pass:secret -out client.p12

rm -f ./*.csr ./*.srl ./*.ext
chmod 600 ./*.key
echo "Test certificates written to $OUT"
