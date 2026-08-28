# Specialization constants: do they survive the conversion?

A shader's look and pace are `const` values at the top of its `.glsl`, so
changing one means editing GLSL and regenerating `Generated/Shaders.swift`,
which a tarball install cannot do. The question is whether those values can be
declared as specialization constants and set from the host at pipeline
creation, without breaking the rule that the same `.glsl` still works as a
Ghostty `custom-shader`.

## Verdict

**Yes on our side, no on Ghostty's - and one `#ifdef` gets both.**

The constants survive glslang and spirv-cross intact, `MTLFunctionConstantValues`
sets them, and reflection hands over a table of name, id, type and default.
Ghostty 1.3.1 is where it breaks: it builds the custom shader's fragment
function with `newFunctionWithName:` and no constant values, and Metal refuses
to build a pipeline from a function that has unset function constants - it
aborts the process rather than returning an error.

Declaring them behind a macro that only `Scripts/build-shaders.sh` defines
avoids that entirely: Ghostty compiles the same file with plain `const`
declarations and never sees a function constant.

```glsl
#ifdef SAVER_SPECIALIZE
#define SPEC(id) layout(constant_id = id)
#else
#define SPEC(id)
#endif

SPEC(0) const float FLY_SPEED = 0.85;
```

`glslang -DSAVER_SPECIALIZE` produces the function constant; without it the
same line is an ordinary `const` and the default is compiled in. The default is
written once either way.

## What was checked

Against `shaders/gradient.glsl` with four constants added - a float used
directly, two ints combined into `const int PERIOD = CRAWL_LINES + GAP_LINES;`
at file scope, and a float used as a tint - compiled with the same flags
`Scripts/build-shaders.sh` uses and rendered through a throwaway Metal harness
at 64 x 64.

**1. The constant survives the conversion, and derived expressions are not
folded.** Verified. spirv-cross emits

```metal
constant float PULSE_SPEED_tmp [[function_constant(0)]];
constant float PULSE_SPEED = is_function_constant_defined(PULSE_SPEED_tmp) ? PULSE_SPEED_tmp : 2.0;
constant int CRAWL_LINES_tmp [[function_constant(1)]];
constant int CRAWL_LINES = is_function_constant_defined(CRAWL_LINES_tmp) ? CRAWL_LINES_tmp : 119;
constant int GAP_LINES_tmp [[function_constant(2)]];
constant int GAP_LINES = is_function_constant_defined(GAP_LINES_tmp) ? GAP_LINES_tmp : 9;
constant int PERIOD = (CRAWL_LINES + GAP_LINES);
```

`PERIOD` stays an expression, so a `CRAWL_LINES + GAP_LINES` loop period follows
whatever the host sets. glslang keeps the GLSL names, which is what makes the
generated table readable rather than a list of ids. An id that nothing reads is
kept as well, and ids do not have to be contiguous.

**2. `MTLFunctionConstantValues` changes the rendered output.** Verified. One
pixel, with defaults and then with all four constants set:

| what was set | pixel at (48, 20) |
| --- | --- |
| nothing (declared defaults) | (193, 82, 189, 255) |
| all four | (48, 64, 243, 255) |
| `CRAWL_LINES` and `GAP_LINES` only | (193, 64, 189, 255) |
| `TINT_R` only | (48, 82, 189, 255) |

The third row is the one that matters: only the derived `PERIOD` changed, which
it could not do if the addition had been folded. The fourth shows that a
constant left unset keeps its declared default, so the host only has to set
what the config actually names.

One thing to build in from the start: **a shader that declares function
constants can no longer be built unspecialized.** `makeFunction(name:)` returns
a function Metal will not accept, so `MetalRenderer` has to go through
`makeFunction(name:constantValues:)` even when there is nothing to set, passing
an empty `MTLFunctionConstantValues`.

**3. Ghostty renders such a shader with the declared default.** Verified as
**false**, from Ghostty 1.3.1's source and reproduced locally.
`src/renderer/shadertoy.zig` converts a `custom-shader` with the same glslang
(Vulkan 1.2 / SPIR-V 1.5) and the same single spirv-cross option we use
(`MSL_ENABLE_DECORATION_BINDING`), so Ghostty's MSL carries the same function
constants. `src/renderer/metal/Pipeline.zig` then asks for the function with
`newFunctionWithName:`, with no constant values. Driving that exact sequence
against the generated MSL:

```text
plain gradient.glsl      -> pipeline built
with constant_id present -> validateWithDevice:5044: failed assertion
                            `Render Pipeline Descriptor Validation
                            fragmentFunction main0 cannot be used to build a
                            pipeline state. Use
                            newFunctionWithName:constantValues:... to get the
                            specialized function'
                            (SIGABRT)
```

So this is not a shader that quietly renders its defaults over there. It is a
shader Ghostty cannot build, and the failure is an abort rather than something
Ghostty could log and carry on from. The `SPEC(id)` guard above is what keeps
the file usable as a `custom-shader`, and it is not optional.

An end-to-end run - a real Ghostty window with `custom-shader` pointed at an
unguarded shader - was **not** performed: neither `open -na Ghostty.app` nor
running the binary directly produced a surface from here (`error initializing
surface err=error.OutOfMemory`, `CVDisplayLinkCreateWithCGDisplays error -6661
due to invalid display count (0)`), so the control run had nothing to compare
against either. To do it by hand:

```sh
Scripts/build-shaders.sh   # with the guard's #define removed
open -na Ghostty.app --args --fullscreen=false --custom-shader=/path/to/shader.glsl
log show --last 1m --style compact --info --predicate 'subsystem == "com.mitchellh.ghostty"'
```

**4. `spirv-cross --reflect` exposes the constants.** Verified. It emits a
`specialization_constants` array of name, id, type and default value:

```json
[
  { "name": "PULSE_SPEED", "id": 0, "type": "float", "variable_id": 52, "default_value": 2.0 },
  { "name": "CRAWL_LINES", "id": 1, "type": "int",   "variable_id": 61, "default_value": 119 }
]
```

`build-shaders.sh` already runs `--reflect` for the uniform offsets, so the
table can be emitted into `Generated/Shaders.swift` from the same JSON rather
than by parsing GLSL on the host. Derived values like `PERIOD` are not listed,
which is correct - they are not settable.

## What this means for the issues that depend on it

- Per-shader tunables from the config file (#7) can go ahead. The keys are the
  reflected names, the host validates them against the generated table, and
  `MetalRenderer` applies them through `MTLFunctionConstantValues`.
- Picking one of several baked crawls at startup (#8) can use an `int`
  constant for the index. A shader run under Ghostty gets the declared default,
  which is the crawl we have today - the outcome that issue wanted.
- Supplying crawl text from outside the binary (#9) is untouched by this.
  Specialization constants cannot carry arrays, which was already that issue's
  starting point.

## Versions

- glslang 16.5.0, spirv-cross 1.4.357.0 (Homebrew)
- Ghostty 1.3.1 (`ReleaseFast`), source read at tag `v1.3.1`
- Apple M4 Pro, macOS 26.6
- 2026-08-28
