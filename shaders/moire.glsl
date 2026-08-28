// Two lattices drifting out of phase: the beat between them swallows whatever
// could be read through it, then lets it back.
//
// Stateless by construction, like every shader here. Each lattice is a pure
// function of position, and the drift between them is a function of iTime -
// one turns by a few degrees on a slow sine, the other slides - so the
// interference is wherever those two functions disagree, recomputed every
// frame from nothing.
//
// The intended moire is the low-frequency beat between two pitches a few
// percent apart. The unintended kind, from sampling a fine grating once per
// pixel, is kept out the way synthwave keeps its grid clean: each lattice
// fades as its own pitch approaches the pixel spacing, so a small window sees
// a soft field rather than resolution-dependent speckle.

const float PITCH = 0.030;        // lattice spacing, in screen heights
const float RATIO = 1.045;        // the second lattice's pitch over the first
const float TILT = 0.06;          // how far the second lattice turns, radians
const float TILT_PERIOD = 47.0;   // seconds for one swing of the tilt
const float SLIDE = 0.0022;       // screen heights per second the second lattice slides
const float LINE_FRACTION = 0.30; // how much of each cell is line rather than gap
const float FADE_PX = 3.0;        // pitch in pixels at which a lattice is gone

const vec3 GROUND = vec3(0.02, 0.02, 0.035);
const vec3 INK_A = vec3(0.18, 0.62, 0.70);
const vec3 INK_B = vec3(0.90, 0.55, 0.22);

// Distance to the nearest line of a unit lattice, in lattice units.
float toLine(float x) {
    float f = fract(x);
    return min(f, 1.0 - f);
}

// Line coverage of a square lattice at unit pitch, antialiased over one
// pixel; `span` is how many lattice units one screen pixel covers.
float lattice(vec2 p, float span) {
    float halfWidth = LINE_FRACTION * 0.5;
    float edge = span * 0.7;
    float x = 1.0 - smoothstep(halfWidth - edge, halfWidth + edge, toLine(p.x));
    float y = 1.0 - smoothstep(halfWidth - edge, halfWidth + edge, toLine(p.y));
    return max(x, y);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float pixel = 1.0 / iResolution.y;

    // The first lattice holds still; the second turns and slides against it.
    // The beat moves by the slide divided by the pitch difference, so a slide
    // the eye would not notice on the lattice itself sweeps the pattern.
    float tilt = TILT * sin(iTime * 6.28318 / TILT_PERIOD);
    float c = cos(tilt);
    float s = sin(tilt);
    vec2 turned = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    vec2 slid = turned + vec2(iTime * SLIDE, iTime * SLIDE * 0.37);

    float pitchB = PITCH * RATIO;
    float a = lattice(uv / PITCH, pixel / PITCH);
    float b = lattice(slid / pitchB, pixel / pitchB);

    // Past resolving, a lattice is drawn as its own average rather than as
    // lines, so it stops contributing speckle and the beat with it fades.
    float pxA = PITCH / pixel;
    float pxB = pitchB / pixel;
    a = mix(LINE_FRACTION * 2.0 - LINE_FRACTION * LINE_FRACTION, a, smoothstep(FADE_PX, FADE_PX * 2.5, pxA));
    b = mix(LINE_FRACTION * 2.0 - LINE_FRACTION * LINE_FRACTION, b, smoothstep(FADE_PX, FADE_PX * 2.5, pxB));

    // Where the lines of both land on the same pixel the ink doubles up; where
    // they interleave it averages out. That difference is the moire.
    float both = a * b;
    float either = a + b - both;

    vec3 color = GROUND;
    color += INK_A * a * 0.20;
    color += INK_B * b * 0.20;
    color += vec3(0.95, 0.92, 0.80) * both * 0.75;
    color *= 0.75 + 0.25 * either;

    fragColor = vec4(color, 1.0);
}
