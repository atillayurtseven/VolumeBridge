#!/bin/zsh
# Builds and signs. "./build.sh install" also installs to /Applications and launches.
set -e
cd "${0:a:h}"
APP=build/VolumeBridge.app
CERT="${CERT:-VolumeBridge Dev}"

# A stable signature keeps the Accessibility grant across rebuilds.
if ! security find-identity -p codesigning | grep -q "\"$CERT\""; then
  echo "\"$CERT\" certificate not found, creating it..."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false" 2>/dev/null
  # OpenSSL 3 needs -legacy; macOS's LibreSSL does not know the flag
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/c.p12" -passout pass:x 2>/dev/null ||
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/c.p12" -passout pass:x
  security import "$TMP/c.p12" -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
fi

rm -rf build && mkdir -p $APP/Contents/MacOS
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.4 Sources/main.swift -o build/VolumeBridge-$arch
done
lipo -create build/VolumeBridge-arm64 build/VolumeBridge-x86_64 -output $APP/Contents/MacOS/VolumeBridge
cp Info.plist $APP/Contents/
codesign --force --sign "$CERT" --identifier com.atilla.seskopru $APP
if [[ "$1" == "install" ]]; then
  pkill -x VolumeBridge || true
  rm -rf /Applications/VolumeBridge.app && cp -R $APP /Applications/
  open /Applications/VolumeBridge.app
fi
