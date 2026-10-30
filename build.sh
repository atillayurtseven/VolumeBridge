#!/bin/zsh
# Derler, /Applications/SesKopru.app olarak kurar ve başlatır.
set -e
cd "${0:a:h}"
APP=build/SesKopru.app
rm -rf build && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -target arm64-apple-macos14.4 Sources/main.swift -o $APP/Contents/MacOS/SesKopru
cp Info.plist $APP/Contents/
codesign --force --sign "SesKopru Dev" --identifier com.atilla.seskopru $APP
if [[ "$1" == "install" ]]; then
  pkill -x SesKopru || true
  rm -rf /Applications/SesKopru.app && cp -R $APP /Applications/
  open /Applications/SesKopru.app
fi
