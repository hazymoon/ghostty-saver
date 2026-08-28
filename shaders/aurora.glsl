// Northern lights: curtains of green drifting over a star field, with a black
// ridge line along the bottom to stand them against.
//
// Stateless by construction, like every shader here. A curtain is a sum of
// sines that says where its foot hangs, so the whole sheet is a closed form in
// x and iTime; nothing is advected and nothing is stored.

const int CURTAINS = 5;

const float BASE_Y = -0.16;       // where the lowest curtain hangs, in screen heights
const float STRIPES = 78.0;       // vertical striations across the sheet
const float RIDGE_Y = -0.34;      // the skyline, in screen heights

const vec3 AURORA_LOW = vec3(0.16, 1.00, 0.52);
const vec3 AURORA_HIGH = vec3(0.42, 0.30, 0.95);
const vec3 SKY_TOP = vec3(0.010, 0.014, 0.045);
const vec3 SKY_LOW = vec3(0.030, 0.055, 0.095);

// Three sines at spreading rates: enough to read as folded cloth, few enough
// to stay cheap. Each curtain gets its own seed so they do not move together.
float fold(float x, float seed, float rate) {
    return sin(x * 1.3 + iTime * 0.21 * rate + seed) * 0.100
        + sin(x * 2.7 - iTime * 0.17 * rate + seed * 2.3) * 0.048
        + sin(x * 5.1 + iTime * 0.13 * rate + seed * 3.7) * 0.021;
}

vec3 starfield(vec2 fragCoord) {
    float cellSize = iResolution.y / 44.0;
    vec2 grid = fragCoord / cellSize;
    vec2 cell = floor(grid);
    float seed = hash21(cell);
    if (seed > 0.22) { return vec3(0.0); }

    vec2 at = vec2(hash11(seed * 13.7), hash11(seed * 29.3));
    float away = length((fract(grid) - at) * cellSize);
    float twinkle = 0.75 + 0.25 * sin(iTime * (0.5 + 1.6 * hash11(seed * 3.3)) + seed * 90.0);
    return vec3(0.82, 0.88, 1.00) * exp(-away * away / 0.40)
        * (0.25 + 0.75 * hash11(seed * 7.1)) * twinkle;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle, y upward. fragCoord grows downward
    // here and in Ghostty alike, so it is flipped once, here.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;

    vec3 color = mix(SKY_LOW, SKY_TOP, smoothstep(-0.5, 0.5, uv.y));
    color += starfield(fragCoord);

    for (int i = 0; i < CURTAINS; i++) {
        float seed = float(i) * 13.7 + 1.9;
        float rate = 0.7 + 0.5 * hash11(seed * 1.7);

        float foot = BASE_Y + float(i) * 0.055 + fold(uv.x, seed, rate);
        float above = uv.y - foot;
        float height = 0.30 + 0.22 * hash11(seed * 5.3);

        // A hard lower edge and an exponential fade upward: the bright hem
        // along the bottom is what makes it read as an aurora rather than as
        // fog.
        float body = smoothstep(-0.020, 0.012, above) * exp(-max(above, 0.0) / (height * 0.42));
        if (body <= 0.002) { continue; }

        // Only a stretch of the sky is lit at a time, and the lit stretch
        // wanders. Two envelopes at different rates keep it from pulsing on a
        // beat.
        float span = (0.5 + 0.5 * sin(uv.x * 0.75 + iTime * 0.05 + seed * 2.0))
            * (0.4 + 0.6 * (0.5 + 0.5 * sin(uv.x * 1.9 - iTime * 0.09 + seed * 4.0)));
        span = smoothstep(0.06, 0.62, span);
        if (span <= 0.0) { continue; }

        // Striations: the rays that run up the sheet. They lean with the fold
        // so they follow it instead of hanging over it in a straight grid, and
        // they wash out towards the top where a real curtain goes smooth.
        float lean = uv.x + fold(uv.x, seed * 1.3, rate) * 1.6;
        float rays = 0.5 + 0.5 * sin(lean * STRIPES + seed * 40.0);
        rays = mix(rays, 0.5 + 0.5 * sin(lean * STRIPES * 0.37 - iTime * 0.4 + seed), 0.5);
        rays = mix(rays, 0.75, smoothstep(0.0, height * 0.7, max(above, 0.0)));

        vec3 tint = mix(AURORA_LOW, AURORA_HIGH, clamp(above / (height * 0.55), 0.0, 1.0));
        color += tint * body * span * mix(0.45, 1.0, rays) * 0.50;
    }

    // The skyline: black hills, so the curtains have something to hang over.
    float ridge = RIDGE_Y
        + 0.045 * sin(uv.x * 2.1 + 0.7)
        + 0.028 * sin(uv.x * 4.7 - 1.3)
        + 0.014 * sin(uv.x * 9.3 + 2.9);
    float land = smoothstep(0.004, -0.004, uv.y - ridge);
    // A little of the glow still spills onto the land rather than a hard cut.
    color = mix(color, color * 0.06, land);

    fragColor = vec4(color, 1.0);
}
