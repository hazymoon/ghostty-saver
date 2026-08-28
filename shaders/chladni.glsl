// Chladni figures: the nodal lines of a vibrating square plate, where the sand
// settles, swept from one mode to the next.
//
// Stateless by construction, like every shader here. A mode (n, m) of a square
// plate has the closed form
//
//     f(x, y) = cos(n pi x) cos(m pi y) - cos(m pi x) cos(n pi y)
//
// and the sand gathers where f is zero, so the figure is a pure function of
// position and of the pair (n, m). The pair is a function of floor(iTime /
// HOLD): each mode is held for HOLD seconds and then hard-cut to the next.
// A plate does the same - the pattern jumps when the frequency crosses a
// resonance - and a blend between two modes would draw a figure no plate
// makes.
//
// Nothing accumulates. The grains are a hash of the pixel's cell, and how
// many of them show is set by how close the cell is to a nodal line, which is
// abs(f) against its own gradient. fwidth(f) is what keeps the lines the same
// thickness on screen whether the mode is (1, 2) or (7, 4): abs(f) alone would
// draw thick lines where the field is flat and hairlines where it is steep.

const float HOLD = 3.5;           // seconds a mode is held before the next
const float LINE_PX = 2.2;        // half-width of the settled sand, in pixels
const float HALO_PX = 7.0;        // how far the sparse grains reach from a line
const float GRAIN_PX = 2.6;       // grain cell size, in pixels
const float PLATE = 0.86;         // plate side as a fraction of the screen height

const vec3 SAND = vec3(0.93, 0.87, 0.72);
const vec3 PLATE_COLOR = vec3(0.045, 0.040, 0.050);
const vec3 EDGE_COLOR = vec3(0.30, 0.28, 0.26);
const vec3 BACKGROUND = vec3(0.012, 0.012, 0.016);

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Which (n, m) the plate is ringing at during a given hold. Modes with n == m
// have f == 0 everywhere and are skipped by construction; the hash keeps the
// sweep from being a ladder that anyone can predict.
vec2 modeAt(float hold) {
    float n = 1.0 + floor(hash11(hold * 1.37 + 0.21) * 7.0);      // 1..7
    float m = 1.0 + floor(hash11(hold * 2.91 + 5.73) * 6.0);      // 1..6
    if (m >= n) { m += 1.0; }                                    // never n == m
    return vec2(n, m);
}

float plateField(vec2 p, vec2 mode) {
    vec2 a = cos(mode.x * 3.14159265 * p);
    vec2 b = cos(mode.y * 3.14159265 * p);
    return a.x * b.y - b.x * a.y;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle. The plate is square and sits in
    // the middle of the screen whatever its shape.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float pixel = 1.0 / iResolution.y;

    // Plate coordinates in -1..1.
    vec2 p = uv / (0.5 * PLATE);
    float edge = max(abs(p.x), abs(p.y));

    vec3 color = BACKGROUND;

    // The rim of the plate, a thin line so the figure reads as being on
    // something.
    float rimWidth = 1.5 * pixel / (0.5 * PLATE);
    float onPlate = 1.0 - smoothstep(1.0 - rimWidth, 1.0, edge);
    float rim = smoothstep(1.0 - 3.0 * rimWidth, 1.0 - rimWidth, edge) * onPlate;
    color = mix(color, PLATE_COLOR, onPlate);
    color = mix(color, EDGE_COLOR, rim);

    if (edge < 1.0) {
        vec2 mode = modeAt(floor(iTime / HOLD));
        float f = plateField(p, mode);

        // Distance to the nearest nodal line, in pixels. fwidth is the change
        // of f across one pixel, so f divided by it is that distance.
        float grad = max(fwidth(f), 1e-5);
        float dist = abs(f) / grad;

        // The settled ridge: dense sand right on the line.
        float ridge = 1.0 - smoothstep(LINE_PX * 0.5, LINE_PX, dist);

        // Loose grains scattered near the line, thinning with distance. The
        // hash decides whether this cell holds a grain; the distance decides
        // how likely one is to be there.
        vec2 cell = floor(fragCoord / GRAIN_PX);
        float grain = hash21(cell + 0.37);
        float density = 1.0 - smoothstep(LINE_PX, HALO_PX, dist);
        float loose = step(1.0 - 0.55 * density * density, grain);

        // Grains that were never near a line: a faint dusting over the plate.
        float dust = step(0.985, hash21(cell + 9.1)) * 0.35;

        float sand = max(ridge, max(loose, dust));
        // Individual grains catch the light differently.
        vec3 tint = SAND * (0.75 + 0.35 * hash21(cell + 4.2));
        color = mix(color, tint, sand);
    }

    fragColor = vec4(color, 1.0);
}
