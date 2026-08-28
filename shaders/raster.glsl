// The SNES raster effect over a 16-bit sunset: every scanline of the picture
// is read back a little to the left or right, so the sky ripples like a flag
// and a tear sweeps down the screen once a cycle.
//
// Stateless by construction. There is no frame buffer to read back from, so
// the picture is a function - scene(p) - that can be asked for any point, and
// mainImage asks for it once, at the displaced point. The displacement is a
// sum of sines in the row and in iTime: one sine is a wobble, two at
// different rates is a flag. The sky and the ground get different profiles,
// and a band of sharp offsets - the interlace tear - drops through the frame
// on a fixed period, its top being a function of iTime alone.
//
// Everything else is closed-form too: the hills are a hash of the column at
// each layer's own scroll speed, so parallax is a lookup, not a scroll.
//
// The picture is counted in screen heights. The last step is the shared
// RGB555 quantise and Bayer dither from shaders/lib/dither.glsl, which is
// counted in pixels on purpose - that is what makes the effect period
// accurate rather than merely wobbly.

const float HORIZON = -0.12;         // screen heights above the middle
const float WAVE_A = 0.035;          // flag amplitude, screen heights
const float WAVE_B = 0.016;
const float TEAR_PERIOD = 9.0;       // seconds between tears
const float TEAR_HEIGHT = 0.08;      // screen heights
const float TEAR_SHIFT = 0.12;       // screen heights
const int HILL_LAYERS = 4;

const vec3 SKY_TOP = vec3(0.12, 0.05, 0.36);
const vec3 SKY_MID = vec3(0.86, 0.30, 0.45);
const vec3 SKY_LOW = vec3(1.00, 0.74, 0.32);
const vec3 SUN_COLOR = vec3(1.00, 0.92, 0.62);
const vec3 HILL_FAR = vec3(0.38, 0.14, 0.42);
const vec3 HILL_NEAR = vec3(0.08, 0.03, 0.14);
const vec3 GROUND = vec3(0.05, 0.02, 0.09);

// Height of hill layer `layer` at horizontal position x, in screen heights.
// A hash per column segment, blended between neighbours so the ridge has
// slopes rather than steps.
float ridge(float x, float layer) {
    float seg = 0.30 + 0.12 * layer;
    float i = floor(x / seg);
    float f = fract(x / seg);
    float a = hash21(vec2(i, layer));
    float b = hash21(vec2(i + 1.0, layer));
    float h = mix(a, b, f * f * (3.0 - 2.0 * f));
    // Far layers are taller and gentler; near ones lower and sharper.
    return h * (0.22 - 0.035 * layer);
}

// The picture, at a point in screen heights (origin centre, y up).
vec3 scene(vec2 p) {
    float pixel = 1.0 / iResolution.y;
    float up = p.y - HORIZON;

    // Banded sky: three stops, then the classic hard stripes near the sun.
    vec3 color = mix(SKY_LOW, SKY_MID, smoothstep(0.0, 0.28, up));
    color = mix(color, SKY_TOP, smoothstep(0.22, 0.75, up));
    float stripe = smoothstep(0.30, 0.62, 0.5 + 0.5 * sin(up * 90.0));
    color *= 1.0 - 0.18 * stripe * (1.0 - smoothstep(0.0, 0.5, up));

    // The sun, big and low, with the slotted lower half of the era.
    vec2 toSun = vec2(p.x - 0.18, up - 0.16);
    float sun = length(toSun);
    float disc = 1.0 - smoothstep(0.19 - pixel * 2.0, 0.19, sun);
    // Slots widen towards the foot of the disc, so it reads as the era's sun.
    float slotWidth = mix(0.15, 0.55, clamp(-toSun.y / 0.19, 0.0, 1.0));
    float slots = smoothstep(0.5 - slotWidth, 0.5 - slotWidth + 0.08, 0.5 + 0.5 * sin(toSun.y * 140.0))
        * step(toSun.y, 0.0);
    vec3 face = mix(SUN_COLOR, SKY_MID, smoothstep(0.19, -0.19, toSun.y) * 0.5);
    color = mix(color, face, disc * (1.0 - slots));

    // Hills, far to near. Each layer scrolls at its own speed, so the
    // parallax comes from asking the hash at a different x per layer.
    for (int i = 0; i < HILL_LAYERS; i++) {
        float layer = float(i);
        float speed = 0.02 + 0.03 * layer;
        float h = ridge(p.x + iTime * speed + layer * 7.3, layer);
        float edge = smoothstep(pixel, -pixel, up - h);
        vec3 tone = mix(HILL_FAR, HILL_NEAR, layer / float(HILL_LAYERS - 1));
        color = mix(color, tone, edge);
    }

    // Ground below the horizon.
    color = mix(color, GROUND, smoothstep(pixel, -pixel, up));
    return color;
}

// Horizontal displacement of a scanline, in screen heights.
float offset(float y, float t) {
    float up = y - HORIZON;
    // The flag: two sines at different spatial and temporal rates.
    float flag = WAVE_A * sin(y * 18.0 + t * 2.1) + WAVE_B * sin(y * 47.0 - t * 3.7);
    // Sky waves in full; the ground only shimmers.
    float amount = mix(0.25, 1.0, smoothstep(-0.05, 0.05, up));
    // The tear: a band that starts at the top on every period and falls,
    // shifting the rows it covers by a sharp, row-dependent amount.
    float phase = fract(t / TEAR_PERIOD);
    float tearTop = 0.5 - phase * 1.2;
    float inTear = step(tearTop - TEAR_HEIGHT, y) * step(y, tearTop);
    float tear = inTear * TEAR_SHIFT * (0.5 + 0.5 * sin(y * 400.0 + t * 20.0));
    return flag * amount + tear;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;
    uv.x += offset(uv.y, iTime);
    vec3 color = scene(uv);
    fragColor = vec4(dither555(color, fragCoord), 1.0);
}
