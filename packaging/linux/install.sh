#!/bin/bash
set -euo pipefail

app="balatui"
sizes=(16 32 48 64 128 256)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# release layout: bin/balatui next to this script
# repo layout:    target/release/balatui two dirs up
if [[ -x "$script_dir/bin/$app" ]]; then
    bin="$script_dir/bin/$app"
elif [[ -x "$script_dir/../../target/release/$app" ]]; then
    bin="$script_dir/../../target/release/$app"
else
    echo "error: $app binary not found (looked in $script_dir/bin and target/release)" >&2
    exit 1
fi

dest_bin="$HOME/.local/bin"
dest_desktop="$HOME/.local/share/applications"
dest_icons="$HOME/.local/share/icons/hicolor"

install -Dm755 "$bin" "$dest_bin/$app"
install -Dm644 "$script_dir/$app.desktop" "$dest_desktop/$app.desktop"

for size in "${sizes[@]}"; do
    install -Dm644 "$script_dir/icons/${size}x${size}/apps/$app.png" \
        "$dest_icons/${size}x${size}/apps/$app.png"
done

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$dest_desktop" || true
[[ -f "$dest_icons/index.theme" ]] && gtk-update-icon-cache -q "$dest_icons" || true

echo "Installed $app to $dest_bin/$app"
echo "Installed desktop file to $dest_desktop/$app.desktop"
if [[ ":$PATH:" != *":$dest_bin:"* ]]; then
    echo "note: $dest_bin is not in your PATH"
fi
