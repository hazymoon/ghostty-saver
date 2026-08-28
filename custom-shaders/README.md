# custom-shaders

Shaders that draw over the terminal's own text. They are **not screensavers**
and are kept out of `shaders/` on purpose.

Every file here reads `iChannel0`. Under Ghostty that is the terminal's
rendered output, which is the whole point of them. In the screensaver it is a
1x1 texture of opaque black - there is no terminal image to bind - so the same
file draws black there, would fail the suite's "draws something" check, and
would be a wrong entry in the `random` pool. So they never go through
`Scripts/build-shaders.sh`, never enter `Generated/Shaders.swift`, and are not
listed by `--list-shaders`.

Use one from Ghostty's config:

```
custom-shader = /path/to/ghostty-saver/custom-shaders/lens.glsl
```

They use nothing from `shaders/lib/`, so the file under this directory is the
one to point at directly.

What can be checked without a terminal is that Ghostty's toolchain accepts
them - the same prefix, glslang and spirv-cross options Ghostty uses:

```sh
brew install glslang spirv-cross
Scripts/check-custom-shaders.sh
```

That runs locally only; CI installs neither tool. Whether the picture is right
has to be judged in a Ghostty window.

| file | what it does to the text |
| --- | --- |
| `lens.glsl` | Bends it around a gravitational lens in the middle of the screen; text past the horizon reddens and goes out. |
| `raster-rows.glsl` | Shifts each text row sideways by its own amount, a wave running down the screen. Set `CELL_HEIGHT_PX` to your font's cell height. |
