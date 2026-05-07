#!/bin/env bash

rm $PREFIX/bin/ins-bin 2>/dev/null || true

echo "Fixing bad install"
P="${PREFIX:-$HOME/.local}"

mkdir -p "$HOME/.ins/src/ins"
mkdir -p "$P/share/ins"
mkdir -p "$P/bin"

cat <<EOF > "$HOME/.ins/state.json"
[
  {
    "name": "ins",
    "url": "https://github.com/turbomaster95/ins",
    "installedAt": "$(date --iso-8601=seconds)",
    "sourceDir": "$HOME/.ins/src/ins",
    "symlinks": ["$P/bin/ins", "$P/share/ins"]
  }
]
EOF

install -Dm755 ins-bin "$P/share/ins/ins-bin"

cat <<EOF > "$P/bin/ins"
#!/usr/bin/env bash
REAL_BIN="$P/share/ins/ins-bin"
"\$REAL_BIN" "\$@"
exit_code=\$?
if [ \$exit_code -eq 0 ]; then
    case "\$1" in rm|remove|uninstall) hash -r 2>/dev/null; [ -n "\$ZSH_VERSION" ] && rehash ;; esac
fi
exit \$exit_code
EOF

chmod +x "$P/bin/ins"

git clone -q https://github.com/turbomaster95/ins "$HOME/.ins/src/ins/" 2>/dev/null || true
