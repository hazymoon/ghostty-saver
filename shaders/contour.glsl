// A contour map whose hills drift: iso-lines of a slowly evolving noise
// field, drawn as line work with the slopes cross-hatched.
//
// Stateless by construction. The field is a few octaves of value noise over
// the shared hash, evaluated at (position, iTime * DRIFT); every frame is a
// pure function of the pixel and the clock, so --at reproduces any moment.
//
// The lines are where fract(field * LEVELS) is near zero, and their width is
// taken from fwidth of the field so it stays the same on screen whether the
// contours are crowded on a steep slope or spread across a plain. Between the
// lines the ground is shaded by shaders/lib/hatch.glsl: line density stands
// in for tone, and the hatching runs along the contours, which is what makes
// this the check on that header - if it can draw this it can draw the
// geometry shaders that come after it.
//
// Ink on a dark ground rather than on paper, so it stays a screensaver.

const float SCALE = 2.2;          // noise cells across one screen height
const float DRIFT = 0.045;        // field evolution, in cells per second
const float LEVELS = 14.0;        // contour lines across the field's range
const float LINE_PX = 1.4;        // contour width in pixels
const vec3 INK = vec3(0.92, 0.86, 0.70);
const vec3 GROUND = vec3(0.03, 0.035, 0.045);

float valueNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i);
    float n100 = hash31(i + vec3(1, 0, 0));
    float n010 = hash31(i + vec3(0, 1, 0));
    float n110 = hash31(i + vec3(1, 1, 0));
    float n001 = hash31(i + vec3(0, 0, 1));
    float n101 = hash31(i + vec3(1, 0, 1));
    float n011 = hash31(i + vec3(0, 1, 1));
    float n111 = hash31(i + vec3(1, 1, 1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// `octaves` octaves, normalised to about 0..1 whatever the count, so the
// smooth version of the field sits under the detailed one.
float fbm(vec3 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        if (i >= octaves) break;
        sum += amplitude * valueNoise(p);
        total += amplitude;
        p = p * 2.03 + vec3(17.3, 9.1, 3.7);
        amplitude *= 0.5;
    }
    return sum / total;
}

float field(vec2 uv) {
    return fbm(vec3(uv * SCALE, iTime * DRIFT), 4);
}

// The two low octaves only: the hills without the gravel on them, which is
// what the hatching should follow. Hatching the full field turns every
// pebble into a whorl of lines.
float relief(vec2 uv) {
    return fbm(vec3(uv * SCALE, iTime * DRIFT), 2);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.y;
    float h = field(uv);

    // Gradient of the relief by finite difference, a few pixels apart, for
    // the hatch direction and the shading tone.
    float step = 3.0 / iResolution.y;
    float r = relief(uv);
    vec2 grad = vec2(relief(uv + vec2(step, 0.0)) - r, relief(uv + vec2(0.0, step)) - r) / step;

    // Contour lines: distance to the nearest level in units of the field,
    // widened to LINE_PX pixels by the field's rate of change.
    float rate = fwidth(h) * LEVELS;
    float toLine = abs(fract(h * LEVELS) - 0.5);
    float halfWidth = LINE_PX * 0.5 * rate;
    float line = 1.0 - smoothstep(halfWidth - rate * 0.5, halfWidth + rate * 0.5, 0.5 - toLine);
    // The lines fade out where a pixel spans more than a level - the
    // minification rule every projection shader here follows.
    line *= 1.0 - smoothstep(0.3, 0.6, rate);

    // Slopes are darker on the side facing away from an upper-left light, and
    // valleys darker than hills; the hatch turns that tone into line density.
    vec2 light = normalize(vec2(-0.6, 0.8));
    float slope = clamp(dot(grad, light) * 0.5, -1.0, 1.0);
    float tone = clamp(0.30 + 0.60 * r + 0.30 * slope, 0.0, 1.0);
    float ink = hatch(tone, hatchDirection(grad), fragCoord) * 0.55;

    float coverage = max(line, ink);
    vec3 color = mix(GROUND, INK, coverage);
    fragColor = vec4(color, 1.0);
}
