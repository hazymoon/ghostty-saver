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

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

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
        float shapeSeed = float(shape) * 41.0 + 3.0;

        // The per-corner constants do not depend on time, so they are hashed
        // once here rather than inside the trail loop, which is what keeps this
        // to a few dozen sines per pixel instead of a few hundred.
        vec4 motion[CORNERS];
        for (int i = 0; i < CORNERS; i++) {
            float s = shapeSeed + float(i) * 7.13;
            motion[i] = vec4(
                0.07 + 0.09 * hash11(s * 1.71),   // horizontal rate
                0.07 + 0.09 * hash11(s * 3.37),   // vertical rate
                hash11(s * 5.19) * 20.0,          // horizontal phase
                hash11(s * 7.77) * 20.0           // vertical phase
            );
        }

        for (int step = 0; step < TRAIL; step++) {
            float age = float(step) / float(TRAIL - 1);
            float t = iTime - float(step) * TRAIL_STEP;

            vec2 points[CORNERS];
            for (int i = 0; i < CORNERS; i++) {
                vec4 m = motion[i];
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
