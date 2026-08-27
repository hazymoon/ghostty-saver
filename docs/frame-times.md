# Frame times: what each shader costs

`docs/stage1-transport.md` settled that the transfer path is not the
bottleneck. This answers the question after it: with Metal drawing the frames,
does every shader hold 60fps on the largest screen it is likely to meet?

## Setup

- Apple M4 Pro, macOS 26.6.2
- Ghostty 1.3.1 in a window covering a 4K display below the menu bar:
  3832 x 1936 px, 28.30 MiB per frame
- Window visible on its own display and frontmost for the whole run, nothing
  else drawing on the machine (checked from the window server by
  `Scripts/measure-frame-times.sh`, which produced this section)
- One reply per frame (`q=0`), 60fps target
- `ghostty-saver --stats --seconds 300 --shader <name>`, run in a Ghostty
  window rather than a tmux pane
- 2026-08-27

## Results

GPU render, in ms:

| shader | mean | p50 | p95 | max | terminal ack (mean) | effective fps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| synthwave | 2.208 | 1.663 | 4.656 | 13.590 | 2.591 | 60.00 |
| gradient | 2.455 | 1.764 | 6.022 | 13.795 | 2.655 | 60.00 |
| starwars | 2.686 | 2.282 | 4.749 | 12.581 | 2.639 | 60.00 |
| hyperspace | 3.955 | 3.599 | 6.649 | 12.614 | 2.658 | 60.00 |
| tunnel | 4.693 | 4.134 | 9.311 | 15.549 | 2.566 | 60.00 |
| matrix | 5.027 | 4.844 | 7.791 | 16.788 | 2.465 | 60.00 |
| aurora | 6.167 | 5.789 | 9.497 | 18.155 | 2.553 | 60.00 |
| mystify | 6.425 | 6.143 | 8.949 | 20.567 | 2.527 | 60.00 |
| toasters | 6.818 | 6.266 | 11.127 | 18.298 | 2.530 | 60.00 |

## Verdict

**All nine hold 60fps, over five minutes each.**

- The transfer path is not what limits any of them. The acknowledgement sits
  between 2.5 and 2.7 ms whatever the shader, so a shader has around 14 ms of
  the 16.7 ms to work in and nothing else is in the way.
- The heaviest, `toasters`, spends 6.8 ms on average and 11.1 ms at its p95;
  its worst frame in eighteen thousand, 18.3 ms, is the only one over budget.
- `mystify` is not the outlier the occluded figures made it. It costs about
  the same as `aurora`, and the six changes to it described in `README.md`
  under "Staying inside the frame" are what brought it there from the 15.4 ms
  it started at.

## The window has to be visible

macOS throttles drawing for a window nobody can see, and Ghostty's renderer
stops with it: its display link is stopped whenever the window is occluded or
unfocused, and drawing goes with the link. The first version of this document
was measured with the window occluded - on another Space, or behind the
window being worked in - and every figure in it was too slow. The same
shader at the same resolution over the same five minutes:

| | occluded | visible on its own display |
| --- | ---: | ---: |
| effective fps | 41.58 | 59.99 |
| GPU render mean | 14.130 ms | 6.369 ms |
| terminal ack mean | 8.685 ms | 2.634 ms |
| terminal ack max | 64.632 ms | 5.279 ms |

The acknowledgement is what moves first, and the render time follows it,
because both sides are drawing on the same GPU. The shader was `mystify`,
which the occluded table had failing 60fps at 57.89: that verdict was the
measurement, not the shader.

Anything else drawing on the same GPU does the same in a smaller way. A run
that overlapped a second Ghostty window at 60fps had its acknowledgement p95
at 6 to 8 ms against the 2.7 to 2.9 ms above, and `aurora` at 58.96 fps.

So visibility is a condition of the measurement, and it is written down as
one. `Scripts/measure-frame-times.sh` holds the conditions rather than a
person remembering to: it runs every shader in turn from the window it is
started in, refuses a tmux pane and a window that is not frontmost, and flags
a run whose resolution moved, that was cut short by a keypress, or whose
acknowledgement p95 is above 5 ms. It prints this document's setup block and
table, so re-measuring is a paste. A second display makes the run practical:
keep the terminal on one and leave the machine alone.

## How to read the numbers

**Check `frames` before the timings.** A keypress ends the screensaver, so a
run that was interrupted still prints a full-looking report. Twenty seconds at
60fps is around 1200 frames; a run of 37 is 0.6 seconds of screensaver with
the shader's first compile averaged into it, which is how `aurora` first
measured at 11.581 ms - three times what it actually costs.

**The window was visible, or the numbers are not comparable.** See "The
window has to be visible" above; the acknowledgement p95 is the quickest
tell, at two to three times its undisturbed value when anything else was
drawing.

**`GPU render` is not the shader alone.** It is the wall clock across a
command buffer that waits for completion, on a GPU that is also compositing
Ghostty's window and putting a 28.30 MiB image into it every frame. Rendering
the same shader with nothing else running measures `mystify` at 4.803 ms
against the 6.425 ms here. The number to design against is this one; the
quiet one says how much of it is the shader.

**The ack is the terminal's parse, not its paint.** As in the transport
measurements, a `q=0` reply means Ghostty stored the image. It also moves with
how hard the terminal is working: the same shader was measured with acks
between 1.752 ms and 4.414 ms.
