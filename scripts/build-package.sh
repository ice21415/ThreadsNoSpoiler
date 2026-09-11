#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_dir="$PWD"
build_dir=$(mktemp -d /tmp/threadsnospoiler-build.XXXXXX)
cp Tweak.xm TSBFooterLayout.h TSBFooterLayout.mm TSBFooterGeometry.h Makefile control ThreadsNoSpoiler.plist "$build_dir/"
cd "$build_dir"
sed -i 's/\r$//' control Makefile
export THEOS=/home/theos/theos
make package FINALPACKAGE=1
mkdir -p "$source_dir/packages"
cp packages/*.deb "$source_dir/packages/"
printf 'Build retained at: %s\n' "$build_dir"
