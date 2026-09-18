#!/bin/bash
set -euo pipefail

app="balatui"
version="$(cargo pkgid)"
version="${version##*#}"
name="${app}-${version}-linux-x64"
tmp="$(mktemp -d)"
stage="${tmp}/${name}"

cargo build --release

mkdir -p "$stage/bin"
cp "target/release/$app" "$stage/bin/"
cp packaging/linux/install.sh packaging/linux/balatui.desktop "$stage/"
cp -r packaging/linux/icons "$stage/"

tar -C "$tmp" -czf "${name}.tar.gz" "$name"
rm -rf "$tmp"
sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256"

echo "Created ${name}.tar.gz (+ .sha256) in repo root"
