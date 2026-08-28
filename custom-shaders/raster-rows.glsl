// The SNES raster effect on the terminal itself: every row of text shifted
// sideways by its own amount, so the screen ripples like a flag.
//
// Ghostty custom-shader only. It reads iChannel0, which is the terminal's
// rendered output under Ghostty and a 1x1 black texture in the screensaver,
// so it lives under custom-shaders/ and never enters the catalogue.
//
// On a terminal a horizontal band of pixels is a row of text, so the offset
// is quantised to whole cells: a row moves as one, rather than shearing
// through the middle of its glyphs. The offset is two sines in row and time
// at different rates - one sine is a wobble, two at different rates is a
// flag. Cost: one texture fetch per pixel.
//
// Ghostty's prefix carries no cell size, so the row height is a constant.
// Set it to the cell height of the font in use (pixels, at the display's
// scale) or the rows will shear in a period that does not match the text.

const float CELL_HEIGHT_PX = 32.0;   // your font's cell height in pixels
const float AMPLITUDE = 0.035;       // how far a row moves, in screen widths
const float ROWS_PER_WAVE = 9.0;     // rows from one crest to the next
const float SPEED = 1.3;             // waves per second along the rows

// The terminal's pixels at a texture coordinate. Everything below goes through
// this so the source of the picture is stated once.
vec3 terminal(vec2 uv) {
    return texture(iChannel0, uv).rgb;
}

// Horizontal offset of a row, in texture coordinates.
float offset(float row, float t) {
    float phase = row / ROWS_PER_WAVE * 6.2831853;
    return AMPLITUDE * (sin(phase - t * SPEED * 6.2831853) * 0.7
                      + sin(phase * 0.37 + t * SPEED * 2.1 + 1.3) * 0.3);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    // Whole rows: the offset depends on which cell row the pixel is in, not
    // on the pixel itself.
    float row = floor(fragCoord.y / CELL_HEIGHT_PX);
    float x = uv.x + offset(row, iTime);

    // Past either edge there is nothing to show, so show nothing rather than
    // a smear of the last column.
    if (x < 0.0 || x > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    fragColor = vec4(terminal(vec2(x, uv.y)), 1.0);
}
