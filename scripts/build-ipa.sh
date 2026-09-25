#!/usr/bin/env bash
# 在 macOS 上把 DSHRemote 打成未签名 IPA（给 Sideloadly / AltStore / SideStore 侧载用）。
# 用法: ./scripts/build-ipa.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="DSHRemote.xcodeproj"
SCHEME="DSHRemote"
APP_NAME="DSHRemote"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="build"
IPA_NAME="DSHRemote.ipa"

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR" Payload "$IPA_NAME"

echo "==> xcodebuild（$CONFIGURATION，关闭签名）"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION-iphoneos/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "找不到构建产物: $APP_PATH" >&2
  exit 1
fi

echo "==> 打包 IPA"
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry "$IPA_NAME" Payload
rm -rf Payload

echo "==> 完成: $IPA_NAME（$(du -h "$IPA_NAME" | cut -f1)）"
