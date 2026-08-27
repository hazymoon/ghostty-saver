#!/usr/bin/env bash
# @file check-repaint.sh
# @brief Run the screensaver in its own Ghostty window and check what the window shows afterwards
# @description
#   After a run ends, the window has sometimes been found still showing the
#   last frame with the shell already back at its prompt underneath. Which
#   half of that is this program's is the question: the image was never
#   deleted (ours), or it was deleted and nothing repainted (the terminal's).
#   Told apart by eye, on a window that has to be left alone for the whole
#   run, the answer tends to be a guess. This does the looking instead.
#
#   It opens a fresh Ghostty instance running a small script, captures that
#   window before the screensaver starts, while it runs, and after it exits,
#   and reads each capture for brightness and colour. `gradient` is the
#   shader because it fills the screen with saturated colour, so a capture of
#   it and a capture of a prompt on a dark background cannot be confused.
#
#   If the window is stale after the exit, it prods it twice more, in the
#   order that separates the causes: first a newline written through the pty
#   by the shell inside the window, which is what the screensaver's own exit
#   sequence is, then a keypress delivered from outside with --keystroke,
#   which is what has always brought the window back by hand. Which prod
#   repaints the window is the finding, and the exit status carries it.
#
#   The screensaver itself now asks the terminal to confirm the exit sequence
#   and says so on standard error if it does not; the run's stderr is kept
#   and quoted, so that observation lands next to the capture it explains.
#
#   REQUIRES SCREEN RECORDING PERMISSION for the terminal this is run from
#   (System Settings > Privacy & Security > Screen Recording). Without it
#   screencapture cannot read any window and this stops before the run.
#   --keystroke additionally needs Accessibility permission for osascript to
#   type into the window, and steals focus for a moment to do it. Ghostty
#   itself asks, in a dialog, whether it may execute the script the new
#   window is given; answer Allow.
#
#   A stale window has only been reported after runs of several minutes, so
#   a short --seconds is a check of the harness, not of the bug.
#
# @section Usage
#   Scripts/check-repaint.sh [--seconds N] [--shader NAME] [--keystroke] [--keep]
#
# @arg --seconds N   how long the screensaver runs (default 20)
# @arg --shader NAME which shader (default gradient; anything darker weakens the reading)
# @arg --keystroke   if still stale after the newline, type a key into the window
# @arg --keep        leave the captures and logs behind and print where
#
# @exitcode 0 the window showed the prompt again straight after the exit
# @exitcode 1 the check could not be set up (permission, no window, no binary)
# @exitcode 2 the screensaver never appeared in the captures, so nothing can be said
# @exitcode 3 stale after the exit, repainted by the newline through the pty
# @exitcode 4 stale after the newline too, repainted by a keypress
# @exitcode 5 stale after the keypress as well: the image was still there

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/release/ghostty-saver"
probe_source="$repo_root/Scripts/window-probe.swift"
probe="$repo_root/.build/tools/window-probe"

seconds=20
shader=gradient
keystroke=0
keep=0

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) seconds="$2"; shift 2 ;;
        --shader) shader="$2"; shift 2 ;;
        --keystroke) keystroke=1; shift ;;
        --keep) keep=1; shift ;;
        -h | --help) sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ ! -x "$binary" ]; then
    echo "$binary is missing; run: swift build -c release" >&2
    exit 1
fi

# @description Compile the probe if the source is newer than the binary.
build_probe() {
    if [ ! -x "$probe" ] || [ "$probe_source" -nt "$probe" ]; then
        mkdir -p "$(dirname "$probe")"
        swiftc -O -o "$probe" "$probe_source"
    fi
}
build_probe

work="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-saver-repaint.XXXXXXXX")"
spawned_pid=
cleanup() {
    if [ -n "$spawned_pid" ]; then kill "$spawned_pid" 2> /dev/null || true; fi
    if [ "$keep" -eq 1 ]; then
        echo "kept: $work"
    else
        rm -r -- "$work" 2> /dev/null || true
    fi
}
trap cleanup EXIT

# Permission first, on the window this runs in, before a window is opened
# that would be left behind by a failure here.
if ! screencapture -x -l "$("$probe" window "$(pgrep -n -x ghostty || echo 0)" 2> /dev/null | sed -n 's/^id=\([0-9]*\).*/\1/p')" "$work/permission.png" 2> /dev/null \
    || [ ! -s "$work/permission.png" ]; then
    echo "screencapture cannot read a window. Grant Screen Recording permission to" >&2
    echo "the terminal this runs from: System Settings > Privacy & Security >" >&2
    echo "Screen Recording. A newly granted permission needs the terminal restarted." >&2
    exit 1
fi

# The script the new window runs. It talks to this one through files in
# $work: it says when it is ready, waits to be told to go, runs the
# screensaver, says when that has exited, then does whatever it is told next.
# At a fixed path rather than under $work: Ghostty asks whether a command
# handed to it by `open` may be executed, and the question names the path,
# so a path that changes every run is a question that has to be answered
# every run.
inner="$repo_root/.build/tools/check-repaint-inner.sh"
cat > "$inner" <<EOF
#!/bin/bash
work="$work"
touch "\$work/ready"
until [ -e "\$work/go" ]; do sleep 0.1; done
"$binary" --shader "$shader" --seconds "$seconds" --stats 2> "\$work/stats.txt"
echo "exit status \$?" >> "\$work/stats.txt"
touch "\$work/exited"
until [ -e "\$work/nudge" ] || [ -e "\$work/quit" ]; do sleep 0.1; done
if [ -e "\$work/nudge" ]; then
    printf '\\n'
    touch "\$work/nudged"
fi
until [ -e "\$work/quit" ]; do sleep 0.1; done
EOF
chmod +x "$inner"

# A new instance rather than a new window of the running one, so the
# process is this script's to find and to kill. What the user works in is
# never touched.
# A second instance can take well over ten seconds to show a window.
before_pids="$(pgrep -x ghostty || true)"
# Not fullscreen whatever the user's config says: a fullscreen window lives
# on its own Space, and screencapture cannot read a window on a Space that
# is not the current one.
open -na Ghostty.app --args \
    --confirm-close-surface=false \
    --fullscreen=false \
    -e "$inner"

for _ in $(seq 1 300); do
    sleep 0.2
    for pid in $(pgrep -x ghostty || true); do
        if ! grep -qx "$pid" <<< "$before_pids"; then spawned_pid="$pid"; fi
    done
    [ -n "$spawned_pid" ] && [ -e "$work/ready" ] && break
done
if [ -z "$spawned_pid" ] || [ ! -e "$work/ready" ]; then
    echo "the Ghostty window never came up (pid=${spawned_pid:-none})." >&2
    exit 1
fi

# The window to capture is whichever of the instance's windows can be, and
# still can be a few seconds later: the window server lists a window that
# is settling into place - or being moved by a window manager - at one
# size and position, and a capture that works then can fail once it lands.
capturable() {
    screencapture -x -l "$1" "$work/window.png" 2> /dev/null && [ -s "$work/window.png" ]
}
window_id=
for _ in $(seq 1 20); do
    candidate=
    while read -r line; do
        id="$(sed -n 's/^id=\([0-9]*\).*/\1/p' <<< "$line")"
        [ -n "$id" ] || continue
        # Ghostty also owns a few strips the height of a title bar; a
        # terminal is not one of those.
        height="$(sed -n 's/.* h=\([0-9]*\).*/\1/p' <<< "$line")"
        [ "${height:-0}" -ge 200 ] || continue
        if capturable "$id"; then candidate="$id"; window_line="$line"; break; fi
    done <<< "$("$probe" window "$spawned_pid" 2> /dev/null || true)"
    if [ -n "$candidate" ]; then
        sleep 3
        if capturable "$candidate"; then
            window_id="$candidate"
            echo "window: $window_line"
            break
        fi
    else
        sleep 1
    fi
done
if [ -z "$window_id" ]; then
    echo "Ghostty (pid $spawned_pid) has no window that can be captured." >&2
    exit 1
fi
if ! "$probe" frontmost "$spawned_pid"; then
    echo "note: the new window is not frontmost. Ghostty stops drawing a window it" >&2
    echo "      believes is not visible, so leave it on top for the run." >&2
fi

# @description Capture the window and read it. Prints "brightness=.. saturation=..".
# @arg $1 string a name for the capture
capture() {
    local name="$1" path="$work/$1.png"
    # A moment for whatever was just written to be painted, if it is going
    # to be.
    sleep 0.5
    # A window that has only just appeared can refuse the first capture.
    local attempt
    for attempt in 1 2 3 4 5; do
        if screencapture -x -l "$window_id" "$path" 2> "$work/$name.err" && [ -s "$path" ]; then
            "$probe" look "$path"
            return
        fi
        sleep 1
    done
    echo "could not capture the window for '$name': $(cat "$work/$name.err")" >&2
    exit 1
}

# @description Whether a reading is of the screensaver rather than a prompt.
# @arg $1 string a "brightness=.. saturation=.." line
shows_screensaver() {
    local saturation
    saturation="$(sed -n 's/.*saturation=\([0-9.]*\).*/\1/p' <<< "$1")"
    awk -v s="$saturation" 'BEGIN { exit !(s > 20) }'
}

before="$(capture before)"
echo "before   : $before"

touch "$work/go"
sleep "$(awk -v s="$seconds" 'BEGIN { print (s > 4) ? s / 2 : 2 }')"
during="$(capture during)"
echo "during   : $during"

for _ in $(seq 1 $((seconds * 10 + 100))); do
    [ -e "$work/exited" ] && break
    sleep 0.1
done
if [ ! -e "$work/exited" ]; then
    echo "the screensaver did not exit within its --seconds." >&2
    touch "$work/quit"
    exit 1
fi

after="$(capture after)"
echo "after    : $after"
echo "--- the run's stderr"
sed 's/^/    /' "$work/stats.txt" | grep -E "frames|resolution|exit status|did not confirm" || true

if ! shows_screensaver "$during"; then
    echo "the screensaver never showed in the window (saturation stayed low), so the" >&2
    echo "captures say nothing about the exit. Was the window covered?" >&2
    touch "$work/quit"
    exit 2
fi

verdict=0
if shows_screensaver "$after"; then
    echo "STALE after the exit: the window still shows the last frame."
    touch "$work/nudge"
    for _ in $(seq 1 50); do [ -e "$work/nudged" ] && break; sleep 0.1; done
    nudged="$(capture nudged)"
    echo "newline  : $nudged"
    if ! shows_screensaver "$nudged"; then
        echo "REPAINTED by a newline through the pty. The exit sequence itself did not"
        echo "trigger a repaint, but output through the pty can."
        verdict=3
    elif [ "$keystroke" -eq 1 ]; then
        osascript -e 'tell application "Ghostty" to activate' \
            -e 'tell application "System Events" to keystroke " "' > /dev/null
        typed="$(capture typed)"
        echo "keypress : $typed"
        if ! shows_screensaver "$typed"; then
            echo "REPAINTED by a keypress only. The image had been deleted - the delete was"
            echo "processed - and the terminal did not repaint on anything the pty carried."
            verdict=4
        else
            echo "STILL STALE after a keypress: the image is still placed. The delete was"
            echo "not processed, or not honoured."
            verdict=5
        fi
    else
        echo "STILL STALE after the newline. Re-run with --keystroke to tell whether a"
        echo "keypress repaints it (image deleted) or not (image still placed)."
        verdict=4
    fi
else
    echo "OK: the window shows the prompt again after the exit."
fi

touch "$work/quit"
exit "$verdict"
