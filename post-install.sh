#!/bin/env bash

rm $PREFIX/bin/ins-bin 2>/dev/null || true

echo "Fixing bad install"
P="${PREFIX:-$HOME/.local}"

mkdir -p "$HOME/.ins/src/ins"
mkdir -p "$P/share/ins"
mkdir -p "$P/bin"

# Define paths
INS_SRC="$HOME/.ins/src/ins"
MK_SRC="$HOME/.ins/src/sane.tools/mk"

# Function to get hash safely
get_hash() {
    if [ -d "$1/.git" ]; then
        # Run git inside the directory using -C
        git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "not-cloned"
    fi
}

# Fetch the hashes
INS_HASH=$(get_hash "$INS_SRC")
MK_HASH=$(get_hash "$MK_SRC")

cat <<EOF > "$HOME/.ins/state.json"
[
  {
    "name": "ins",
    "url": "https://github.com/turbomaster95/ins",
    "hash": "$INS_HASH",
    "installedAt": "$(date --iso-8601=seconds)",
    "sourceDir": "$INS_SRC",
    "symlinks": ["$P/bin/ins", "$P/share/ins"]
  },
  {
    "name": "sane.tools/mk",
    "url": "https://github.com/turbomaster95/sane.tools",
    "hash": "$MK_HASH",
    "installedAt": "$(date --iso-8601=seconds)",
    "sourceDir": "$MK_SRC",
    "symlinks": ["$P/bin/mk"]
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
