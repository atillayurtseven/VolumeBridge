#!/bin/zsh
# Derler ve imzalar. "./build.sh install" ayrıca /Applications'a kurup başlatır.
set -e
cd "${0:a:h}"
APP=build/SesKopru.app
CERT="SesKopru Dev"

# Sabit imza, Erişilebilirlik izninin yeniden derlemede korunmasını sağlar.
if ! security find-identity -p codesigning | grep -q "\"$CERT\""; then
  echo "\"$CERT\" sertifikası oluşturuluyor..."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false" 2>/dev/null
  # OpenSSL 3 -legacy ister, macOS'un LibreSSL'i bu seçeneği tanımaz
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/c.p12" -passout pass:x 2>/dev/null ||
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/c.p12" -passout pass:x
  security import "$TMP/c.p12" -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
fi

rm -rf build && mkdir -p $APP/Contents/MacOS
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.4 Sources/main.swift -o build/SesKopru-$arch
done
lipo -create build/SesKopru-arm64 build/SesKopru-x86_64 -output $APP/Contents/MacOS/SesKopru
cp Info.plist $APP/Contents/
codesign --force --sign "$CERT" --identifier com.atilla.seskopru $APP
if [[ "$1" == "install" ]]; then
  pkill -x SesKopru || true
  rm -rf /Applications/SesKopru.app && cp -R $APP /Applications/
  open /Applications/SesKopru.app
fi
