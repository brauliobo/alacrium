#!/bin/bash

# Copyright (c) 2026 Alex313031 and midzer.

YEL='\033[1;33m' # Yellow
CYA='\033[1;96m' # Cyan
RED='\033[1;31m' # Red
GRE='\033[1;32m' # Green
c0='\033[0m' # Reset Text
bold='\033[1m' # Bold Text
underline='\033[4m' # Underline Text

# Error handling
yell() { echo "$0: $*" >&2; }
die() { yell "$*"; exit 111; }
try() { "$@" || die "${RED}Failed $*"; }

# chromium/src dir env variable
ALACRIUM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR_SRC_DIR="${ALACRIUM_ROOT}/chromium/src"

printf "\n" &&
printf "${YEL}Building .dmg of Alacrium...\n" &&
printf "${CYA}\n" &&

cd ${CR_SRC_DIR} &&

# Stage on the local disk: pkg-dmg's rsync adds FinderInfo xattrs that invalidate the signature
STAGE="$(mktemp -d)" &&
ditto --noextattr --norsrc out/alacrium/Alacrium.app "${STAGE}/Alacrium.app" &&
xattr -csr "${STAGE}/Alacrium.app" &&

# Sign binary
codesign --force --deep --sign - "${STAGE}/Alacrium.app" &&
codesign --verify --deep --strict "${STAGE}/Alacrium.app" &&
ln -s /Applications "${STAGE}/Applications" &&

# Build dmg package
hdiutil create -volname Alacrium -srcfolder "${STAGE}" -fs HFS+ -format UDBZ -ov out/alacrium/Alacrium_MacOS.dmg &&
rm -rf "${STAGE}" &&

cd "${ALACRIUM_ROOT}" &&
cat logos/apple_ascii_art.txt &&

printf "${GRE}.DMG Build Completed. ${YEL}Installer at \'//chromium/src/out/alacrium/Alacrium_MacOS.dmg\'\n" &&
tput sgr0
