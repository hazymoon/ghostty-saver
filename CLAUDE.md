# ghostty-saver

Commit messages, comments and docs are in English.

## Build and test

- `swift build` / `swift test` / `swift build -c release` — run outside the
  Claude Code sandbox (`dangerouslyDisableSandbox`): sandboxed swift fails on
  `xcrun_db` cache writes with "Operation not permitted", not on the code.
- Editing `shaders/*.glsl` changes nothing at runtime until
  `Scripts/build-shaders.sh` regenerates the committed `Generated/Shaders.swift`
  (needs `glslang` + `spirv-cross`). Check the diff: tool versions can churn
  every shader; a one-line fix should show one shader.
- Terminal-path tests use a pty (`posix_openpt`) and run under `swift test`
  without a tty; `TerminalSession.devicePath(of:)` is the one that opens
  `/dev/tty` and skips itself when there is none.

## Checking against a real Ghostty window

- `Scripts/check-repaint.sh --out DIR` and `Scripts/measure-frame-times.sh`
  need a visible, frontmost Ghostty window; both refuse tmux / hidden windows
  on purpose. Drive them from a second instance
  (`open -na Ghostty.app --args --fullscreen=false -e <script>`) rather than
  the window Claude Code runs in — it takes >10 s to appear, inherits `$TMUX`
  (unset it in the script), and Ghostty asks "Allow ... to execute?" per
  script path, so keep the script at a fixed path under `.build/tools/`.
- `open` cannot put the instance full screen or on a chosen display; a
  windowed run measures a different resolution (recorded in the report) and
  is comparable only with itself.
- Never run the two scripts at once, or while working on the machine: a
  second window drawing on the same GPU shows up as ack p95 of 6–8 ms
  against ~2.9 ms undisturbed, and the run is flagged.
- `--stats` goes to stderr; with stdout redirected the tty is reopened by
  name, so `> report.txt` is fine.
