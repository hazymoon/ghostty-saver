// Windows "Mystify Your Mind": polygons whose corners bounce around the screen,
// each redrawn a dozen times at earlier moments so the shape trails a ribbon.
//
// Stateless by construction, like every shader here. A corner reflecting off
// the edges at constant speed is a triangle wave, so its position is a closed
// form in iTime and the trail is the same expression evaluated at earlier
// times. Nothing is integrated frame to frame.

const int SHAPES = 2;
const int CORNERS = 4;
const int TRAIL = 12;

const float TRAIL_STEP = 0.10;    // seconds between one trailing copy and the next
const float LINE_WIDTH = 1.3;     // px, at the leading copy
const float MARGIN = 0.04;        // how far the corners stay off the edges

// Per-corner rate and phase: (horizontal rate, vertical rate, horizontal
// phase, vertical phase). These came out of a hash of the corner index and
// never depended on iTime or on the pixel, so hashing them here cost every
// pixel of every frame 32 sines to arrive at the same eight constants. They
// are written out instead, at the exact float32 values the hash produced.
const vec4 MOTION[SHAPES * CORNERS] = vec4[SHAPES * CORNERS](
    vec4(0.0738671869, 0.127304688, 19.0332031, 18.828125),
    vec4(0.153320312, 0.142773435, 17.5,        13.3691406),
    vec4(0.0770312473, 0.139257818, 3.59375,    10.15625),
    vec4(0.126249999, 0.0845898464, 15.546875,  0.859375),
    vec4(0.110561527, 0.149453133, 0.390625,    19.4921875),
    vec4(0.0875781253, 0.123964846, 10.546875,  12.265625),
    vec4(0.106562503, 0.12871094,  1.2109375,   1.69921875),
    vec4(0.0868749991, 0.143300787, 18.1738281, 2.890625)
);

// A corner reflecting off two walls at constant speed: a triangle wave.
// abs() of a sawtooth gives the reflection for free.
float bounce(float x) {
    return abs(fract(x * 0.5) * 2.0 - 1.0);
}

float segmentDistance(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return length(pa - ba * h);
}

vec3 palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Work in units of screen height so line widths and speeds mean the same
    // thing at any resolution.
    float aspect = iResolution.x / iResolution.y;
    vec2 p = fragCoord / iResolution.y;
    float pixel = 1.0 / iResolution.y;

    vec3 color = vec3(0.0);

    for (int shape = 0; shape < SHAPES; shape++) {
        for (int step = 0; step < TRAIL; step++) {
            float age = float(step) / float(TRAIL - 1);
            float t = iTime - float(step) * TRAIL_STEP;

            vec2 points[CORNERS];
            for (int i = 0; i < CORNERS; i++) {
                vec4 m = MOTION[shape * CORNERS + i];
                points[i] = vec2(
                    mix(MARGIN, aspect - MARGIN, bounce(t * m.x + m.z)),
                    mix(MARGIN, 1.0 - MARGIN, bounce(t * m.y + m.w))
                );
            }

            // Closed polygon, the way Mystify draws it.
            float nearest = 1e9;
            for (int i = 0; i < CORNERS; i++) {
                nearest = min(nearest, segmentDistance(p, points[i], points[(i + 1) % CORNERS]));
            }

            // Older copies are thinner as well as dimmer, so the ribbon tapers
            // instead of reading as a stack of equal outlines.
            float width = pixel * LINE_WIDTH * mix(1.0, 0.55, age);
            float core = smoothstep(width * 2.0, width * 0.5, nearest);
            float glow = exp(-nearest / (pixel * 9.0)) * 0.30;

            float fade = (1.0 - age) * (1.0 - age);
            // Each copy is drawn in the hue the leading edge had that long ago,
            // which is where the ribbon's colour gradient comes from.
            vec3 hue = palette(iTime * 0.045 - float(step) * 0.016 + float(shape) * 0.5);
            color += hue * (core + glow) * fade;
        }
    }

    // Enough of a lift that the black between the ribbons is not flat.
    color += vec3(0.02, 0.02, 0.05);

    fragColor = vec4(color, 1.0);
}
