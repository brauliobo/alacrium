#!/bin/bash

set -euo pipefail

# Copyright (c) 2026 Alex313031.

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

# --help
displayHelp () {
	printf "\n" &&
	printf "${bold}${YEL}Script to check out Chromium tag of current Alacrium version.${c0}\n" &&
	printf "\n"
	printf "${RED}NOTE: You may need to run ${c0}${bold}./trunk.sh ${RED}before using this script!${c0}\n" &&
	printf "\n"
}
case ${1:-} in
	--help) displayHelp; exit 0;;
esac

# chromium/src dir env variable
ALACRIUM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR_SRC_DIR="${ALACRIUM_ROOT}/chromium/src"

if [ -d "$HOME/depot_tools" ]; then
  export PATH="$HOME/depot_tools:$PATH"
fi

ALACRIUM_VER="153.0.8010.36"

export ALACRIUM_VER &&

printf "\n"
printf "${GRE}Current Alacrium version is:${c0} ${underline}$ALACRIUM_VER${c0}\n"
printf "\n"
printf "${RED}NOTE: ${YEL}Checking out${CYA} tags/$ALACRIUM_VER ${YEL}in ${CR_SRC_DIR}...${c0}\n"
printf "\n"

cd "${CR_SRC_DIR}"

if ! git rev-parse -q --verify "refs/tags/${ALACRIUM_VER}" >/dev/null; then
  git fetch --depth=1 origin \
    "refs/tags/${ALACRIUM_VER}:refs/tags/${ALACRIUM_VER}"
fi

git checkout -f "tags/${ALACRIUM_VER}"

# M147+ ships JPEG XL natively; no separate JPEG XL DEPS overlay is required.

cd "${CR_SRC_DIR}"

git clean -ffd
git clean -ffd

printf "${GRE}gclient sync${c0}\n"  &&
gclient sync --with_branch_heads --with_tags --force --reset --nohooks --delete_unversioned_trees &&

git clean -ffd &&

printf "${GRE}gclient runhooks${c0}\n" &&
gclient runhooks &&

# Install sysroots (i.e. for ARM64)
if [ -n "${MSYSTEM:-}" ]; then
  printf "${GRE}Not Downloading Linux sysroot on Windows\n"
else
  build/linux/sysroot_scripts/install-sysroot.py --arch=amd64 &&
  build/linux/sysroot_scripts/install-sysroot.py --arch=arm64
fi

printf "\n"
printf "${GRE}Chromium tree is checked out at tag: ${c0}$ALACRIUM_VER\n"
printf "\n"
	
printf "${YEL}Downloading PGO Profiles for Linux & Windows...\n" &&
printf "\n" &&
{ tput sgr0 || true; } &&

python3 tools/update_pgo_profiles.py --target=linux update --gs-url-base=chromium-optimization-profiles/pgo_profiles &&

python3 tools/update_pgo_profiles.py --target=win64 update --gs-url-base=chromium-optimization-profiles/pgo_profiles &&

printf "\n" &&

printf "${YEL}Downloading PGO Profile for V8 (for when v8_enable_builtins_optimization = true)\n" &&
printf "\n" &&
{ tput sgr0 || true; } &&

if [ -n "${MSYSTEM:-}" ]; then
  python3 v8/tools/builtins-pgo/download_profiles.py --depot-tools=/c/src/depot_tools --force download
else
  python3 v8/tools/builtins-pgo/download_profiles.py --depot-tools=$HOME/depot_tools --force download
fi
printf "\n" &&

cd "${ALACRIUM_ROOT}" &&

printf "${GRE}Done! ${YEL}You can now run \'./setup.sh\'\n"
tput sgr0 || true
