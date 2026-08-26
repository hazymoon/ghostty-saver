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
#   screensaver runs, stops it, and puts lock-command back the way it was.
#
#   THIS LOCKS THE TMUX CLIENT IT RUNS IN. That client is unusable for the
#   whole duration, and pressing a key ends the screensaver early. Run it from
#   a tmux session you can leave alone, or use --no-drive and start the
#   screensaver yourself in a separate Ghostty window that is not attached to
#   tmux.
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
# @exitcode 2 not enough samples, or the screensaver exited before the end

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
        pkill -x ghostty-saver 2> /dev/null || true
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
if [ "$drive" -eq 1 ]; then
    echo "this tmux client is locked until the run finishes; pressing a key ends it early"
else
    echo "--no-drive: start the screensaver yourself; this cannot check which build is running"
fi
echo "# elapsed_seconds	ghostty_rss_kb	saver_rss_kb" > "$samples"

if [ "$drive" -eq 1 ]; then
    # One sample before the lock, so the log shows the idle baseline.
    echo -e "0\t$(ps -o rss= -p "$terminal_pid" | tr -d ' ')\t" >> "$samples"
    tmux lock-client
fi

started_at="$(date +%s)"
saver_seen=0
truncated=0

while true; do
    elapsed=$(( $(date +%s) - started_at ))
    [ "$elapsed" -ge "$duration" ] && break

    terminal_rss="$(ps -o rss= -p "$terminal_pid" 2> /dev/null | tr -d ' ' || true)"
    if [ -z "$terminal_rss" ]; then
        echo "Ghostty exited during the run." >&2
        exit 1
    fi

    saver_pid="$(pgrep -n -x ghostty-saver || true)"
    saver_rss=""
    if [ -n "$saver_pid" ]; then
        saver_seen=1
        saver_rss="$(ps -o rss= -p "$saver_pid" 2> /dev/null | tr -d ' ' || true)"
    elif [ "$saver_seen" -eq 1 ]; then
        # A keypress ends the screensaver. Sampling on without it would fill
        # the tail of the log with an idle terminal and read as flat.
        truncated=1
        break
    fi

    printf '%s\t%s\t%s\n' "$elapsed" "$terminal_rss" "$saver_rss" >> "$samples"
    sleep "$interval"
done

cleanup

if [ "$truncated" -eq 1 ]; then
    echo
    echo "the screensaver exited after ${elapsed}s of ${duration}s, so the run is short." >&2
    echo "a keypress ends it; leave the client alone for the whole duration." >&2
    echo "samples so far: $samples" >&2
    exit 2
fi

echo
echo "samples: $samples"
if [ -s "$saver_log" ]; then
    echo
    cat "$saver_log"
fi
echo

python3 "$repo_root/Scripts/analyze-memory.py" "$samples" "$warmup"
