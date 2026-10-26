#!/bin/sh
# Registers LUCY+OSKO into your desktop application menu (GNOME, KDE, XFCE, etc.)
set -e
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

mkdir -p "$APPS_DIR" "$ICONS_DIR"

if [ -f "$DIR/lucy-osko.png" ]; then
    cp "$DIR/lucy-osko.png" "$ICONS_DIR/lucy-osko.png"
fi

cat > "$APPS_DIR/lucy-osko.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=LUCY+OSKO
GenericName=Synthesizer & Audio Workstation
Comment=Single-source Gleam & Lustre audio synthesizer with Skred engine
Exec="$DIR/lucy-osko"
Icon=$ICONS_DIR/lucy-osko.png
Terminal=false
Categories=AudioVideo;Audio;Music;
StartupWMClass=lucy-osko
EOF

chmod +x "$APPS_DIR/lucy-osko.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi

echo "=========================================================="
echo " LUCY+OSKO has been installed to your application menu!"
echo " You can now launch it directly from GNOME / KDE / Apps."
echo "=========================================================="
