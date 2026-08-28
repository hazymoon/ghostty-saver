# Raymarch budget: does a sphere-traced shader fit the p95 at 4K?

**Status: scaffolding measured by nobody yet.** The shaders, the script and
the protocol are here; the tables are empty until a run in a visible Ghostty
window fills them. The session that wrote this could not open one.

Nothing in the catalogue marches, so there is no measured point to
extrapolate from, and the headroom is not large: the terminal's
acknowledgement takes 2.5-2.7 ms whatever the shader (`docs/frame-times.md`),
leaving 13-14 ms of a 60fps frame, and the heaviest shader today, `toasters`,
is already 11.127 ms at p95 on 3832 x 1936.

## The throwaway shader

`docs/raymarch-budget/march.glsl.in` is one scene - a sphere, a torus, a box
and a floor - sphere-traced with four knobs, and
`Scripts/raymarch-budget.sh gen` writes one catalogue shader per setting:

| shader | steps | dithered start | far cap | bounding sphere |
| --- | ---: | :-: | :-: | :-: |
| `march-s16` | 16 | | | |
| `march-s32` | 32 | | | |
| `march-s64` | 64 | | | |
| `march-s128` | 128 | | | |
| `march-s32-dither` | 32 | yes | | |
| `march-s32-cap` | 32 | | yes | |
| `march-s32-bound` | 32 | | | yes |
| `march-s32-all` | 32 | yes | yes | yes |

The scene is plain on purpose: the cost under measurement is the march, and
the naive version's cost is proportional to the step count. The three tricks
are the standard ones the issue names - a hash-chosen start offset so few
steps look like many, stopping once the ray is past `FAR`, and skipping the
march entirely when the ray misses a sphere around the scene.

## Protocol

Same conditions as `docs/frame-times.md`, enforced by the same script:
visible, frontmost, on its own display, nothing else drawing, run from a
Ghostty window rather than a tmux pane.

```sh
git switch claude/raymarch-budget
swift build -c release
Scripts/raymarch-budget.sh measure --seconds 60 --out .build/raymarch
```

That runs `measure-frame-times.sh --only` over the eight variants and prints
the table below in this format. Sixty seconds per variant is eight minutes;
the doc's own figures used 300 s per shader, and a longer run is better if
the machine can be left alone for it.

The resolution series is the binary by hand, because `measure-frame-times.sh`
measures the window it is in. With the window at the full 4K size:

```sh
for size in 1280x720 1920x1080 2560x1440 3832x1936; do
  .build/release/ghostty-saver --stats --seconds 30 --size $size --shader march-s32 2> .build/raymarch/res-$size.txt
done
grep 'GPU render' .build/raymarch/res-*.txt
```

`--size` states the render size instead of asking the terminal, so the frame
is drawn smaller and placed in the window; the GPU render figure is then the
shader at that resolution.

## Results

### Step count, at 3832 x 1936

| shader | mean | p50 | p95 | max | terminal ack (mean) | effective fps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| march-s16 | | | | | | |
| march-s32 | | | | | | |
| march-s64 | | | | | | |
| march-s128 | | | | | | |

### Cheapening, at 32 steps

| shader | mean | p50 | p95 | max |
| --- | ---: | ---: | ---: | ---: |
| march-s32 | | | | |
| march-s32-dither | | | | |
| march-s32-cap | | | | |
| march-s32-bound | | | | |
| march-s32-all | | | | |

### Resolution, at 32 steps

| size | megapixels | mean | p95 |
| --- | ---: | ---: | ---: |
| 1280x720 | 0.92 | | |
| 1920x1080 | 2.07 | | |
| 2560x1440 | 3.69 | | |
| 3832x1936 | 7.42 | | |

## Conditions

- Machine, macOS and Ghostty versions:
- glslang / spirv-cross versions (`glslang --version`, `spirv-cross --help | head -1`):
- Date:

## Verdict

To be written from the tables: the largest step count whose p95 fits under
about 13 ms at 3832 x 1936, with and without the tricks, or a statement that
none does. That number is what decides whether the heavy ideas in
`docs/shader-ideas.md` section D are filed, and at what step budget; it also
bears on the parallax-occlusion carving shader (#32), which marches over the
terminal's image.
