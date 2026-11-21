#!/bin/bash
# EWI5000 Bank Manager をビルドして dist/EWI5000 Bank Manager.app を作る
# （~/Developer/Apps への配置と起動は _autobuild が行う）
set -euo pipefail
cd "$(dirname "$0")"
NAME="EWI5000 Bank Manager"
TMP="build/tmp/$NAME.app"
rm -rf build/tmp
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources"
# Apple Silicon と Intel の両方で動くユニバーサル版
mkdir -p build/obj
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -target $ARCH-apple-macos14.0 \
        -framework CoreMIDI \
        Sources/*.swift -o "build/obj/EWI5000BankManager-$ARCH"
done
lipo -create build/obj/EWI5000BankManager-arm64 build/obj/EWI5000BankManager-x86_64 \
    -output "$TMP/Contents/MacOS/EWI5000BankManager"
cp Info.plist "$TMP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$TMP/Contents/Resources/"; fi
codesign --force --sign - "$TMP"
# 自己テスト（実機の記録・SDカードのファイル・模擬本体で確認。結果は build/selftest/report.txt）
#   tests/in に SDカードのファイル（patchlib.ewi など）があれば実データ、なければ作り物のデータで試験する
"$TMP/Contents/MacOS/EWI5000BankManager" --selftest "$PWD/tests"
if [ -f tests/in/patchlib.ewi ]; then   # 公開リポジトリと同じ条件（ファイルなし）でも試す
    rm -rf build/publictest && mkdir -p build/publictest/tests/in
    "$TMP/Contents/MacOS/EWI5000BankManager" --selftest "$PWD/build/publictest/tests" > build/publictest/report.txt
    tail -1 build/publictest/report.txt | sed 's/^/public selftest: /'
fi
rm -rf dist
mkdir -p dist
mv "$TMP" dist/
# 配布用 zip（Finder の「圧縮」と同じ形式。署名や属性を壊さないよう ditto で作る）
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
rm -f "dist/EWI5000_Bank_Manager_Mac_v$VER.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "dist/$NAME.app" "dist/EWI5000_Bank_Manager_Mac_v$VER.zip"
echo "OK: dist/$NAME.app / dist/EWI5000_Bank_Manager_Mac_v$VER.zip"
