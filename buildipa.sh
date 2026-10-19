#!/bin/bash

# Inspired by https://github.com/cranci1/Sora/blob/dev/ipabuild.sh

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=TwitchUnblock
SCHEME_NAME="TwitchUnblock"

if [ ! -d "build" ]; then
  mkdir build
fi

cd build

echo "--- Resolving Swift Package Dependencies ---"

xcodebuild -resolvePackageDependencies \
  -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME"

echo "--- Building $APPLICATION_NAME for iOS ---"

xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
  -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation \
  clean build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/Release-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
  echo "Error: Build failed, .app not found at $DD_APP_PATH"
  exit 1
fi

# Restes d'un essai précédent (raté) : l'app était copiée dans l'ancienne,
# et le zip mettait à jour l'ancienne IPA au lieu d'en faire une neuve.
rm -rf "$TARGET_APP" Payload "$APPLICATION_NAME.ipa"
cp -r "$DD_APP_PATH" "$TARGET_APP"

# Icônes au choix (assets/icons/loose, faites par make_icons.py) : fichiers
# PNG séparés déclarés par CFBundleIconFiles, comme Feather pour les siennes.
# Déclarées seulement par le catalogue (CFBundleIconName), iOS refusait de
# les poser sur une app installée par Feather (OSStatus -54).
LOOSE_ICONS="$WORKING_LOCATION/assets/icons/loose"
if [ -d "$LOOSE_ICONS" ]; then
  echo "--- Adding alternate app icons ---"
  PLIST="$TARGET_APP/Info.plist"
  PB=/usr/libexec/PlistBuddy
  cp "$LOOSE_ICONS"/*.png "$TARGET_APP/"
  for key in CFBundleIcons CFBundleIcons~ipad; do
    $PB -c "Add :$key dict" "$PLIST" 2>/dev/null || true
    $PB -c "Delete :$key:CFBundleAlternateIcons" "$PLIST" 2>/dev/null || true
    $PB -c "Add :$key:CFBundleAlternateIcons dict" "$PLIST"
    for icon in "$LOOSE_ICONS"/*@3x.png; do
      name=$(basename "$icon" @3x.png)
      $PB -c "Add :$key:CFBundleAlternateIcons:$name dict" "$PLIST"
      $PB -c "Add :$key:CFBundleAlternateIcons:$name:CFBundleIconFiles array" "$PLIST"
      $PB -c "Add :$key:CFBundleAlternateIcons:$name:CFBundleIconFiles:0 string $name" "$PLIST"
      $PB -c "Add :$key:CFBundleAlternateIcons:$name:UIPrerenderedIcon bool false" "$PLIST"
    done
  done
fi

echo "--- Removing code signature ---"
codesign --remove "$TARGET_APP"
if [ -e "$TARGET_APP/_CodeSignature" ]; then
  rm -rf "$TARGET_APP/_CodeSignature"
fi
if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
  rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

echo "--- Packaging IPA ---"
mkdir -p Payload
cp -r "$APPLICATION_NAME.app" "Payload/$APPLICATION_NAME.app"
strip "Payload/$APPLICATION_NAME.app/$APPLICATION_NAME"
zip -qry "$APPLICATION_NAME.ipa" Payload

rm -rf "$APPLICATION_NAME.app"
rm -rf Payload

echo "--- Success: build/$APPLICATION_NAME.ipa created ---"
