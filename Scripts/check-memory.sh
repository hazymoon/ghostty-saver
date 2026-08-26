#!/usr/bin/env bash
# @file check-memory.sh
# @brief Run the screensaver and check that Ghostty's memory stays flat
# @description
#   Re-transmitting a frame every 16ms is exactly the shape of workload that
#   leaks if an image or a placement is added rather than replaced, so this is
#   worth being able to re-run rather than reconstructing it by hand each time.
#
#   By default it drives the whole thing: points tmux's lock-command at the
#   release binary, locks the client, samples resident memory while the
#   screensaver runs, stops it, and puts lock-command back the way it was. The
#   screen is covered for the duration; that is the test.
#
#   Sampling starts before the lock, so the warmup period is visible in the log
#   rather than being guessed at.
#
# @section Usage
#   Scripts/check-memory.sh [--duration N] [--interval N] [--warmup N] [--no-drive]
#
# @arg --duration N  seconds to sample (default 180)
# @arg --interval N  seconds between samples (default 5)
# @arg --warmup N    seconds to ignore at the start when judging (default 20)
# @arg --no-drive    do not touch tmux; sample whatever is already running
#
# @exitcode 0 memory is flat
# @exitcode 1 memory climbed, or the run could not be set up

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"

duration=180
interval=5
warmup=20
drive=1

while [ $# -gt 0 ]; do
    case "$1" in
        --duration) duration="$2"; shift 2 ;;
        --interval) interval="$2"; shift 2 ;;
        --warmup) warmup="$2"; shift 2 ;;
        --no-drive) drive=0; shift ;;
        -h | --help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

terminal_pid="$(pgrep -n -x ghostty || true)"
if [ -z "$terminal_pid" ]; then
    echo "Ghostty is not running." >&2
    exit 1
fi

if [ "$drive" -eq 1 ]; then
    if [ -z "${TMUX:-}" ]; then
        echo "not inside tmux; run this from a tmux pane, or pass --no-drive." >&2
        exit 1
    fi
    if [ ! -x "$binary" ]; then
        echo "$binary is missing. Run: swift build -c release" >&2
        exit 1
    fi
    # Guard against measuring a binary older than the code.
    if [ -n "$(find "$repo_root/core" "$repo_root/saver" -name '*.swift' -newer "$binary" -print -quit)" ]; then
        echo "$binary is older than the sources. Run: swift build -c release" >&2
        exit 1
    fi
fi

samples="$(mktemp "${TMPDIR:-/tmp}/ghostty-saver-memory.XXXXXXXX")"
saver_log="$(mktemp "${TMPDIR:-/tmp}/ghostty-saver-stats.XXXXXXXX")"

previous_lock_command=""
restored=0

# @description Puts tmux back and stops the screensaver. Safe to call twice.
cleanup() {
    [ "$restored" -eq 1 ] && return 0
    restored=1

    if [ "$drive" -eq 1 ]; then
        pkill -f "$binary" 2> /dev/null || true
        if [ -n "$previous_lock_command" ]; then
            tmux set -g lock-command "$previous_lock_command"
        else
            tmux set -gu lock-command
        fi
    fi
}
trap cleanup EXIT INT TERM

if [ "$drive" -eq 1 ]; then
    previous_lock_command="$(tmux show -gv lock-command 2> /dev/null || true)"
    tmux set -g lock-command "$binary --stats 2> $saver_log"
fi

echo "sampling every ${interval}s for ${duration}s (Ghostty pid $terminal_pid)"
echo "# elapsed_seconds	ghostty_rss_kb	saver_rss_kb" > "$samples"

if [ "$drive" -eq 1 ]; then
    # One sample before the lock, so the log shows the idle baseline.
    echo -e "0\t$(ps -o rss= -p "$terminal_pid" | tr -d ' ')\t" >> "$samples"
    tmux lock-client
fi

started_at="$(date +%s)"
while true; do
    elapsed=$(( $(date +%s) - started_at ))
    [ "$elapsed" -ge "$duration" ] && break

    terminal_rss="$(ps -o rss= -p "$terminal_pid" 2> /dev/null | tr -d ' ' || true)"
    if [ -z "$terminal_rss" ]; then
        echo "Ghostty exited during the run." >&2
        exit 1
    fi

    saver_pid="$(pgrep -n -f "$binary" || true)"
    saver_rss=""
    if [ -n "$saver_pid" ]; then
        saver_rss="$(ps -o rss= -p "$saver_pid" 2> /dev/null | tr -d ' ' || true)"
    fi

    printf '%s\t%s\t%s\n' "$elapsed" "$terminal_rss" "$saver_rss" >> "$samples"
    sleep "$interval"
done

cleanup

echo
echo "samples: $samples"
if [ -s "$saver_log" ]; then
    echo
    cat "$saver_log"
fi
echo

python3 "$repo_root/Scripts/analyze-memory.py" "$samples" "$warmup"
