# Transfer spike: measurements

Before writing any Metal, the transfer path was isolated and measured to answer
one question: can the kitty graphics protocol's shared memory transfer (`a=T`,
`t=s`) clear 30fps?

## Setup

- Ghostty 1.3.1 on macOS (Apple Silicon)
- 3832 x 2152 px (319 cols x 82 rows, 12 x 26 px per cell)
- 31.46 MiB per frame (RGBA8)
- Driven through tmux's `lock-command`, which is the same client-tty-direct path
  the real screensaver uses
- 2026-08-26, `spike --seconds 5`

## Results

| | q=0 (one reply per frame) | q=2 (replies ignored) |
| --- | ---: | ---: |
| effective fps | 158.39 | 261.54 |
| throughput | 4982.6 MiB/s | 8227.4 MiB/s |

Per-frame breakdown (q=0, mean, ms):

| step | ms |
| --- | ---: |
| shm create (shm_open + ftruncate + mmap) | 0.012 |
| CPU gradient | 3.592 |
| unmap + close | 0.091 |
| write(2) | 0.006 |
| terminal ack | 2.600 |

## Verdict

**Clears the gate.** Neither dropping the resolution nor switching to `t=t` is
necessary.

- Recreating the shared memory segment every frame costs 0.012 ms, which is
  noise.
- The 3.592 ms CPU gradient disappears once Metal draws the frame instead.
- The transfer path alone is about 2.71 ms/frame (shm create + unmap + write +
  terminal ack). At 60fps that leaves roughly 14 ms of the 16.7 ms budget for
  rendering.
- q=2's 261 fps sits right on the send side's 263 fps ceiling, so with replies
  off the CPU gradient is the only limit and the transfer path has room to
  spare.

### How to read the numbers

A `q=0` reply means "Ghostty parsed the command and stored the image", not
"the frame is on screen". What is actually displayed is capped by Ghostty's
renderer, so the real renderer should pace itself to the display rather than
firing as fast as it can. The point of this measurement is only that the
transfer path is not the bottleneck.

With `t=s` the payload is just a shared memory name, a few dozen bytes, so
`write(2)` provides almost no backpressure under `q=2`. That number is the send
side's ceiling, not the terminal's throughput, which is why the gate uses the
`q=0` figure.

## What the Ghostty source says

Confirmed against `src/terminal/kitty` in Ghostty 1.3.1.

- `t=s` passes the base64-decoded payload straight to `shm_open`, so the name
  must include the leading `/` (macOS caps `PSHMNAMLEN` at 31 bytes).
- The terminal calls `shm_unlink` after reading, so every frame needs a new
  name.
- Omitting `p` makes `addPlacement` mint a fresh internal placement id each
  time, and placements accumulate one per frame (`graphics_storage.zig`).
  Pinning `p=1` makes the (image id, placement id) pair overwrite the existing
  placement, so no periodic `a=d` sweep is needed.
- Re-transmitting under the same image id makes `addImage` free the old image
  and replace it. The image storage limit defaults to 320MB, which a single
  31.46 MiB image is nowhere near.
- When `kitty_images` is disabled, nothing is sent back regardless of `q`
  (`graphics_exec.zig`).

## tmux

Running inside a normal tmux pane, tmux swallows the APC and renders it as a
pane title; the command never reaches Ghostty, so no image appears and no reply
comes back. The real path, `lock-command`, talks to the client tty directly and
is unaffected.

That also settles the question of whether tmux interprets KGP: **it does not**,
so no placement needs to be re-sent after a resize.
