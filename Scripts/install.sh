#!/usr/bin/env bash
# @file install.sh
# @brief Build ghostty-saver and place the binary on PATH
# @description
#   Builds in release configuration and installs to ~/.local/bin, then prints
#   the tmux settings that turn it into a lock command.
#
#   The tmux configuration is printed, never written. Editing someone's
#   .tmux.conf without being asked is not this script's job.
#
# @section Environment
#   GHOSTTY_SAVER_PREFIX  install directory (default: $HOME/.local/bin)
#
# @section Usage
#   Scripts/install.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${GHOSTTY_SAVER_PREFIX:-$HOME/.local/bin}"
binary="$repo_root/.build/release/ghostty-saver"

if ! command -v swift > /dev/null 2>&1; then
    echo "swift not found. Install the Xcode command line tools." >&2
    exit 1
fi

echo "building..."
swift build -c release --package-path "$repo_root"

if [ ! -x "$binary" ]; then
    echo "the build did not produce $binary" >&2
    exit 1
fi

mkdir -p "$prefix"
install -m 755 "$binary" "$prefix/ghostty-saver"
echo "installed: $prefix/ghostty-saver"

if ! command -v ghostty-saver > /dev/null 2>&1; then
    echo
    echo "note: $prefix is not on PATH."
fi

cat <<CONFIG

Add this to ~/.tmux.conf to use it as the lock screen:

  set -g lock-after-time 300
  set -g lock-command '$prefix/ghostty-saver'

Then reload with: tmux source-file ~/.tmux.conf
To try it straight away without waiting: tmux lock-client

Running it inside a tmux pane will not work: tmux swallows the graphics
protocol escape sequence. lock-command talks to the client tty directly, which
is why that is the supported way to run it.
CONFIG
