# ghostty-saver

A GPU-rendered screensaver for [Ghostty](https://ghostty.org), driven by tmux's
`lock-command`.

Frames are rendered by a Metal fragment shader straight into POSIX shared
memory and handed to the terminal through the kitty graphics protocol's shared
memory transfer, so nothing is ever copied back from the GPU.

Shaders are written in Shadertoy form against Ghostty's own uniform
declarations, which means the same `.glsl` file also works as a Ghostty
`custom-shader`.

## Requirements

- macOS on Apple Silicon
- Ghostty (developed against 1.3.1)
- Xcode command line tools, for Swift

Only needed to change a shader:

- `brew install glslang spirv-cross`

## Install

```sh
Scripts/install.sh
```

That builds in release configuration, installs to `~/.local/bin/ghostty-saver`,
and prints the tmux settings to add:

```tmux
set -g lock-after-time 300
set -g lock-command '~/.local/bin/ghostty-saver'
```

Try it without waiting for the timeout with `tmux lock-client`.

**Running it inside a tmux pane will not work.** tmux swallows the graphics
protocol's APC sequence and renders it as a pane title, so the command never
reaches Ghostty. `lock-command` talks to the client tty directly, which is why
that is the supported path.

### Releases

Pushing a `v*` tag builds on an Apple Silicon runner and attaches
`ghostty-saver-<tag>-macos-arm64.tar.gz` and a `SHA256SUMS` to the release.
The archive holds `bin/ghostty-saver` and the license, so installing it is an
unpack, and a package manager can pin the tarball by hash without needing a
Swift toolchain on the machine it installs to.

`.github/workflows/release.yml` also runs from the Actions tab without a tag:
it builds, checks the signature, renders a frame and runs the tests, then
stops before publishing.

**Do not strip the binary.** arm64 macOS will not run an executable whose
signature does not match its contents, and stripping invalidates the ad-hoc
signature the linker writes. The workflow asks `codesign` on every release so
a consumer can rely on that rather than assume it.

## Usage

```
ghostty-saver [options]

  --shader NAME     which shader to use (default: matrix), or random
  --list-shaders    list the shaders and what they draw, then exit
  --size WxH        state the resolution instead of asking the terminal
  --seconds N       stop after N seconds (default: run until a key is pressed)
  --frames N        stop after N frames; with --dump, how many to write
  --fps N           target frame rate (default 60, 0 for uncapped)
  --quiet-level N   0=replies on (default), 1=errors only, 2=no replies
  --verify          render one frame without a terminal and check shared memory
  --dump PATH       with --verify, also write the frame to PATH as a PNG.
                    with --frames, PATH is a directory and the frames are
                    written to it as a numbered sequence, 1/--fps apart
  --at SECONDS      with --dump, the iTime of the first frame (default 0)
  --date VALUE      pin iDate: an ISO 8601 instant (2026-08-28T21:30:00Z) or
                    seconds since local midnight. Default: the wall clock
  --stats           print a per-frame breakdown on exit
```

Any keypress exits. The terminal is restored on exit, on SIGINT, SIGTERM and
SIGHUP: images are deleted, the cursor comes back, the alternate screen is left
and termios is put back the way it was.

## Shaders

| name         | what it draws                                                     |
| ------------ | ----------------------------------------------------------------- |
| `matrix`     | Digital rain. The default.                                        |
| `starwars`   | An opening crawl, receding to a vanishing point over a starfield. |
| `hyperspace` | Stars stretching into streaks, a white-out, and back to a cruise. |
| `mystify`    | Windows' Mystify: bouncing polygons trailing coloured ribbons.    |
| `tunnel`     | The demoscene tunnel, flown down with the camera swaying.         |
| `synthwave`  | A banded sun on the horizon over a neon grid running away.        |
| `toasters`   | After Dark's flying toasters, with the toast.                     |
| `aurora`     | Northern lights over a black ridge line.                          |
| `moon`       | Tonight's Moon: its phase, its libration, and earthshine.         |
| `gradient`   | Not a screensaver: the fixture that proves the conversion works.  |

`--list-shaders` prints the same list, taken from the shaders themselves.

`--shader random` picks one for you at each lock, which is the point of having
more than one. It never picks `gradient`.

```tmux
set -g lock-command '~/.local/bin/ghostty-saver --shader random'
```

### Recording the demo

```sh
brew install ffmpeg gifsicle
swift build -c release
Scripts/record-demo.sh
```

That renders two seconds of each shader and writes `demo.gif`. The frames come
out of the screensaver's own binary, through Metal, by way of `--dump` with
`--frames` - rendering the shaders a second time somewhere else would produce a
picture of something that is not quite what ships.

Each clip gets its own palette. Eight shaders share nothing: a matrix green, a
sunset, an aurora. One colour table across the lot bands every gradient in the
set, and a GIF is allowed a palette per frame, so there is no reason to make
them share one.

The GIF is not committed. It is a couple of megabytes that would change every
time a shader is touched, so it goes on a release or an issue and this file
points at the URL.

`--width`, `--fps`, `--seconds`, `--colors` and `--lossy` trade size against
smoothness; `--keep` leaves the PNG frames behind to look at.

## Writing a shader

Drop a Shadertoy-style file into `shaders/` containing only `mainImage`, with a
comment at the top saying what it draws:

```glsl
// A wash of colour that goes nowhere.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

That leading comment is what `--list-shaders` shows: it is read up to the first
blank `//`, so the notes below the summary stay out of it.

Then regenerate:

```sh
Scripts/build-shaders.sh
```

That fetches Ghostty's `shadertoy_prefix.glsl` from a pinned tag, prepends it,
compiles to SPIR-V with `glslangValidator`, converts to MSL with `spirv-cross`,
and writes `Generated/Shaders.swift`. The generated file is committed, so a
build that does not touch a shader needs neither the script, the tools, nor a
network connection.

Using Ghostty's own declarations rather than a transcription is what makes a
shader here work unchanged as a `custom-shader` over there, and it also means
the uniform offsets are generated from reflection rather than written by hand.
The prefix is never stored in this repository: it goes to a temporary
directory and is deleted with it.

Set `GHOSTTY_SAVER_PREFIX_FILE` to a local copy to work offline, or
`GHOSTTY_SAVER_PREFIX_REF` to move the pin.

Shaders must be stateless. Ghostty's custom-shader has no frame-to-frame
storage, so everything is derived from `iTime` and a hash. `shaders/matrix.glsl`
is written that way: trail positions, glyphs and depth all come out of the
clock. So does everything else here - a corner bouncing off the edges in
`mystify` is a triangle wave, a toaster's place in the flock in `toasters` is a
hash of which tile it is in, and the crawl in `starwars` inverts the projection
to turn a pixel into a line and a column. Nothing is integrated forward.

Two things follow from being on a screen rather than on Shadertoy. Anything
drawn far away needs to fade out before one pixel covers more than it can
resolve, or it shimmers - `synthwave` fades each family of grid lines when its
own spacing gets too tight, and `starwars` stops the text at the same point.
And anything counted out in pixels wants to be counted out in screen heights
instead, so the look survives a retina display and a small window alike.

### Staying inside the frame

Full screen on a 4K display is 3832 x 2152 px, and the terminal wants about
3 ms of the 16.7 ms a 60fps frame has. What is left for the shader is roughly
13 ms, and it is the p95 that has to fit in it rather than the mean: a shader
whose average is comfortable still drops frames if its slow ones are not.
`docs/frame-times.md` has what each shader here measures.

A fragment shader runs its whole body once per pixel, so anything in it that
does not depend on the pixel is computed eight million times to arrive at one
answer. `mystify` hashed eight corner constants and stepped a colour cycle
inside its loops - 32 sines and 72 cosines per pixel, for values that were the
same everywhere on the screen. That was a third of its frame. Constants belong
in the source, and a value that advances by a fixed angle belongs in a
recurrence: take the first cosine and turn it.

What is left after that is the part that genuinely varies per pixel, and it is
worth bounding cheaply before computing it exactly. A box around the shape only
excludes pixels outside the box, which leaves the inside of anything large
paying in full - `mystify` measured all four sides of twelve copies of a quad
from pixels deep inside it. Distance is what bounds distance: a copy's outline
cannot have moved further than its fastest corner did, so the distance found
for one copy, less that, still bounds the next. Skipping on that bound halved
the shader. And check what the fades actually multiply, because the last of
those twelve copies was drawn at zero.

To see where the time goes, run it in a Ghostty window with `--stats`. Read
`frames` before the timings: a keypress ends the run, and a short one averages
the shader's first compile into its numbers.

To look at a shader without a terminal:

```sh
swift build -c release
.build/release/ghostty-saver --shader matrix --dump /tmp/frame.png --at 7.5 --size 1600x900
```

`--at` matters for anything on a long cycle: `hyperspace` only jumps near the
end of its 22 seconds, and `starwars` takes a couple of minutes to run the
crawl through. `--date` is the same thing for the calendar: `iDate` carries
the real wall clock, so a shader that reads it needs `--date 2026-08-28T21:30:00Z`
(or `--date 77400`, seconds since midnight) before two dumps can be compared.
The test suite pins it the same way.

## Tests

```sh
swift test
```

The suite covers the exact bytes of the graphics protocol escape sequence, APC
reply framing, the shared memory lifecycle, linear texture alignment, a real
GPU render read back through the shared memory mapping, the generated uniform
offsets, resize handling, shader selection, and what each shader has to look
like. None of it needs a terminal.

Every shader is checked for the things that hold whatever it draws - it
compiles, the same `iTime` gives the same frame, a different one does not, and
it draws something at more than one resolution - and then once more for the
thing that makes it itself: that the crawl is yellow and stays inside a narrow
window, that hyperspace flashes when it jumps, that the aurora is green where
it is lit. Those are deliberately loose. They are there to catch a shader that
has stopped drawing what its name says, not to pin down a look.

`.github/workflows/ci.yml` runs the same suite on every pull request, on the
Apple Silicon image the release is built on. It builds, renders one frame to
prove Metal and shared memory work on the runner, and tests - and stops there.
Signing and packaging belong to a release, which is `release.yml`, and that
fires on a `v*` tag rather than on a branch.

## Checking for leaks

Re-transmitting a whole frame every 16ms is exactly the workload that leaks if
an image or a placement is added rather than replaced, so that check is a
script rather than something to reconstruct by hand:

```sh
Scripts/check-memory.sh
```

It points tmux's `lock-command` at the release binary, locks the client,
samples resident memory for three minutes, stops the screensaver and puts
`lock-command` back. It refuses to run against a binary older than the sources.

**It locks a whole tmux client.** tmux has no per-pane lock: `lock-command`
takes over the client's tty, which is the production path and the reason this
is a faithful test. The locked client is unusable until the run finishes, and a
keypress ends the screensaver early - which the script detects and reports
rather than passing off a truncated run.

To keep working, give a second Ghostty window over to the run. `--client` needs
a client that already exists, so make one first:

```sh
# in a new Ghostty window, on a session of its own
tmux new -s saver-test

# back in the window you are working in
tmux list-clients -F '#{client_name}'   # now lists two
Scripts/check-memory.sh --client <the new one>
```

That is still a valid test of the screensaver, but a worse measurement: every
Ghostty window belongs to one process, so working in another window adds
allocation churn to the number being sampled. For a leak check, stepping away
for three minutes gives a cleaner answer.

`--no-drive` samples without touching tmux, for when the screensaver is being
started some other way.

The verdict reports the slope with its own standard error and states how small
a leak the run could have detected, so a `PASS` can be read for what it is: it
catches anything carrying real weight per frame, and cannot resolve a few
hundred bytes against a terminal's own allocation churn. Exit status is 0 for
flat, 1 for climbing, 2 for not enough samples.

`Scripts/analyze-memory.py --self-test` checks the verdicts against synthetic
series, so the detector cannot quietly stop detecting.

## Design notes

`docs/stage1-transport.md` records the measurements that decided the transfer
approach, along with the Ghostty implementation details the design depends on:
why every frame needs a fresh shared memory name, why a placement id must be
pinned, and how tmux behaves.

`docs/frame-times.md` is what every shader measures on a 4K screen, and the
conditions a measurement has to meet to mean anything.

## License

MIT. See `LICENSE`.

The build fetches `src/renderer/shaders/shadertoy_prefix.glsl` from
[Ghostty](https://github.com/ghostty-org/ghostty) (MIT License) to compile
shaders against the same uniform interface. No Ghostty source is stored in this
repository or included in the build output.
