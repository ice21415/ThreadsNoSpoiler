#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
package="${1:?Usage: update-repository.sh packages/package.deb}"
test -f "$package"
test "$(dpkg-deb -f "$package" Architecture)" = iphoneos-arm64
cp -- "$package" docs/
cd docs
dpkg-scanpackages --multiversion . /dev/null > Packages
gzip -n -9 -c Packages > Packages.gz
release_file=$(mktemp)
apt-ftparchive \
  -o APT::FTPArchive::Release::Architectures=iphoneos-arm64 \
  -o APT::FTPArchive::Release::Codename=ios \
  -o APT::FTPArchive::Release::Components=main \
  -o APT::FTPArchive::Release::Description='Threads No Spoiler Sileo Repository' \
  -o APT::FTPArchive::Release::Label='Threads No Spoiler' \
  -o APT::FTPArchive::Release::Origin='Threads No Spoiler' \
  -o APT::FTPArchive::Release::Suite=stable \
  release . | sed '/ Release$/d' > "$release_file"
mv -- "$release_file" Release
