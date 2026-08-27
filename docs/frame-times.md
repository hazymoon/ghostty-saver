# Frame times: what each shader costs

`docs/stage1-transport.md` settled that the transfer path is not the
bottleneck. This answers the question after it: with Metal drawing the frames,
does every shader hold 60fps on the largest screen it is likely to meet?

## Setup

- Apple M4 Pro, macOS 26.6
- Ghostty full screen on a 4K display: 3832 x 2152 px, 31.46 MiB per frame
- One reply per frame (`q=0`), 60fps target
- `ghostty-saver --stats --seconds 20 --shader <name>`, run in a Ghostty window
  rather than a tmux pane
- 2026-08-27

## Results

GPU render, in ms:

| shader | mean | p50 | p95 | max | terminal ack (mean) | effective fps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gradient | 2.513 | 2.422 | 3.391 | 5.545 | 3.995 | 59.99 |
| synthwave | 2.594 | 2.374 | 4.217 | 10.411 | 3.083 | 59.99 |
| hyperspace | 3.438 | 3.325 | 4.749 | 10.455 | 2.155 | 59.99 |
| starwars | 3.850 | 3.744 | 4.941 | 8.483 | 2.823 | 59.99 |
| tunnel | 4.143 | 3.599 | 6.391 | 46.071 | 4.414 | 59.89 |
| matrix | 5.831 | 5.675 | 7.056 | 10.860 | 3.103 | 60.00 |
| aurora | 6.471 | 6.519 | 7.638 | 16.576 | 2.177 | 60.00 |
| toasters | 9.895 | 10.695 | 12.531 | 15.020 | 1.752 | 60.00 |
| mystify | 11.915 | 11.808 | 17.202 | 41.176 | 3.323 | 57.89 |

## Verdict

**Eight of the nine hold 60fps. `mystify` does not, at 57.89.**

- The transfer path is not what limits any of them. `gradient` sits exactly on
  the 60fps target with a 3.995 ms ack, so a shader has around 13 ms of the
  16.7 ms to work in and nothing else is in the way.
- What costs `mystify` its frames is not its mean. Its frame adds up to
  15.27 ms, which fits; its p95 render alone is 17.202 ms, which does not.
  `aurora` and `toasters` cost nearly as much on average and keep 60fps
  because their slow frames stay near their typical ones - `aurora`'s p95 is
  1.2x its mean, `mystify`'s is 1.4x.
- `mystify` started this measurement at 15.401 ms and 54.12 fps. Six changes
  to the shader took it to 11.915 ms without changing what it draws; the
  remaining gap is that its tail moves with whatever else is on the GPU, which
  the shader cannot do anything about. `README.md` has what those changes
  were, under "Staying inside the frame".

## How to read the numbers

**Check `frames` before the timings.** A keypress ends the screensaver, so a
run that was interrupted still prints a full-looking report. Twenty seconds at
60fps is around 1200 frames; a run of 37 is 0.6 seconds of screensaver with
the shader's first compile averaged into it, which is how `aurora` first
measured at 11.581 ms - three times what it actually costs.

**`GPU render` is not the shader alone.** It is the wall clock across a
command buffer that waits for completion, on a GPU that is also compositing
Ghostty's window and putting a 31.46 MiB image into it every frame. Rendering
the same shader with nothing else running measures `mystify` at 4.803 ms
against the 11.915 ms here. The number to design against is this one; the
quiet one says how much of it is the shader.

**The ack is the terminal's parse, not its paint.** As in the transport
measurements, a `q=0` reply means Ghostty stored the image. It also moves with
how hard the terminal is working: the same shader was measured with acks
between 1.752 ms and 4.414 ms.
