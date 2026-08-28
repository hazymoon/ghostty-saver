// Matrix-style digital rain.
//
// Stateless by construction. Ghostty's custom-shader has no frame-to-frame
// storage, so this shader is written to the same constraint: every trail
// position and every glyph is derived from iTime and a hash rather than
// carried forward.
//
// Glyphs are approximated procedurally as a bit pattern inside each cell. No
// font atlas and no CoreText.
//
// fragCoord has its origin at the top left on the Metal path, here and in
// Ghostty alike, so increasing y is downward and the rain falls with it.

const int RAIN_LAYERS = 3;
// Cell height in pixels at the nearest depth. Columns further back use a
// fraction of this, which is what sells the depth.
const float NEAR_CELL_HEIGHT = 26.0;
const float CELL_ASPECT = 0.62;   // width / height

const vec3 HEAD_COLOR = vec3(0.78, 1.00, 0.85);
const vec3 BODY_COLOR = vec3(0.00, 0.95, 0.32);

// A 3x5 bit grid inside the cell. Coarse enough that the shapes read as
// characters rather than as noise, and cheap enough to evaluate per pixel.
float glyphMask(vec2 cellUV, float seed) {
    vec2 inner = (cellUV - vec2(0.16, 0.10)) / vec2(0.68, 0.80);
    if (inner.x < 0.0 || inner.x > 1.0 || inner.y < 0.0 || inner.y > 1.0) {
        return 0.0;
    }
    vec2 bit = floor(inner * vec2(3.0, 5.0));
    // Bias slightly towards lit bits so glyphs stay legible instead of
    // dissolving into scattered dots.
    return step(0.50, hash31(vec3(bit, seed)));
}

// One depth layer of falling columns. z is 1.0 at the front and smaller
// further back; it drives cell size, fall speed and brightness together.
vec3 rainLayer(vec2 fragCoord, float z, float layerSeed) {
    float cellHeight = NEAR_CELL_HEIGHT * z;
    float cellWidth = cellHeight * CELL_ASPECT;

    vec2 grid = vec2(fragCoord.x / cellWidth, fragCoord.y / cellHeight);
    vec2 cell = floor(grid);
    vec2 cellUV = fract(grid);

    float columnSeed = hash21(vec2(cell.x, layerSeed));
    // Cells per second. Nearer columns fall faster, which reinforces the depth.
    float speed = (7.0 + 16.0 * hash11(columnSeed * 7.31)) * z;
    float phase = hash11(columnSeed * 13.77) * 900.0;
    float rows = iResolution.y / cellHeight;

    // A column is dark for a while between drops, otherwise every column rains
    // at once and the screen reads as a solid wall rather than as rain. The
    // gap is part of the cycle, so which columns are lit keeps changing.
    float travelled = iTime * speed + phase;
    float roughCycle = rows * 2.4;
    float pass = floor(travelled / roughCycle);
    // Re-hashing per pass keeps a column from repeating the same drop forever.
    float dropSeed = hash21(vec2(columnSeed * 61.0, pass));
    float trailLength = 7.0 + 20.0 * dropSeed;
    float gap = rows * (0.6 + 1.4 * hash11(dropSeed * 17.3));

    float head = mod(travelled, rows + trailLength + gap);
    float behindHead = head - cell.y;
    if (behindHead < 0.0 || behindHead > trailLength) {
        return vec3(0.0);
    }

    // Steep enough that a trail actually tapers instead of reading as a bar.
    float fade = exp(-behindHead / (trailLength * 0.30));

    // The glyph in a cell changes on its own schedule, so the trail flickers
    // the way the original does.
    float flickerRate = 5.0 + 9.0 * hash11(columnSeed * 5.11);
    float glyphSeed = floor(iTime * flickerRate) + cell.y * 17.0 + layerSeed + pass * 7.0;
    float mask = glyphMask(cellUV, hash31(vec3(cell, glyphSeed)) * 128.0);
    if (mask <= 0.0) {
        return vec3(0.0);
    }

    // The leading cell is nearly white and noticeably brighter than the trail.
    float headness = smoothstep(2.2, 0.0, behindHead);
    vec3 color = mix(BODY_COLOR, HEAD_COLOR, headness);
    float glow = 1.0 + 1.6 * headness * headness;

    // Distant layers are dimmer as well as smaller and slower.
    return color * fade * glow * mix(0.22, 1.0, z);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec3 color = vec3(0.0);
    for (int layer = 0; layer < RAIN_LAYERS; layer++) {
        float t = float(layer) / float(RAIN_LAYERS - 1);
        float z = mix(0.40, 1.0, t);
        color += rainLayer(fragCoord, z, float(layer) * 37.0);
    }

    // A faint glow keeps the black between columns from looking flat.
    color += BODY_COLOR * 0.010;

    vec2 uv = fragCoord / iResolution.xy;
    float vignette = smoothstep(1.15, 0.30, length(uv - vec2(0.5)));
    fragColor = vec4(color * vignette, 1.0);
}
