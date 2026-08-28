// An Apollonian gasket - circles packed into the gaps between circles, forever
// - zooming in on a loop that lands exactly on the next generation.
//
// Stateless by construction, like every shader here. The gasket is a fold:
// wrap the point into a cell, invert it in a circle, rescale, and repeat a
// fixed number of times, keeping the smallest circle distance seen. Nothing
// is stored; the whole picture is a function of where the pixel is and of
// iTime.
//
// The seamless zoom is arranged rather than found. The fold on its own is
// not exactly self-similar, so the screen is first taken to log-polar
// coordinates: octaves of radius become one axis and angle the other, and the
// fold runs on that strip. Halving the radius then shifts the strip by
// exactly one cell - plus a fixed twist - so the field at one zoom is the
// field at twice the zoom turned by that twist. Zooming by two over a cycle
// and turning the view by the twist over the same cycle brings the first
// frame back byte for byte. The map is conformal, so small circles stay
// circles; only the largest ring is visibly bent.
//
// Line width is held constant on screen from the size of a pixel on the
// strip, and the fold stops early once a cell has shrunk below a pixel, so the deep
// parts fade into their average instead of aliasing or paying for detail
// nobody can see.

const int ITERATIONS = 7;         // depth of the fold, and the cost
const float CYCLE = 24.0;         // seconds for one halving of the view
const float TWIST = 0.55;         // radians between octaves; also the loop's turn
const float SLICES = 6.0;         // cells around the ring; an integer, for the wrap
const float INVERT = 0.80;        // radius squared of the inverting circle
const float LINE_PX = 1.3;        // circle outline thickness in pixels
const float FADE_PX = 6.0;        // a circle this many pixels across is drawn in full

const vec3 INK_A = vec3(0.95, 0.88, 0.62);
const vec3 INK_B = vec3(0.35, 0.72, 0.95);
const vec3 WASH = vec3(0.40, 0.18, 0.36);
const vec3 GROUND = vec3(0.012, 0.010, 0.022);

const float TAU = 6.28318530718;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;

    // One cycle zooms in by two and turns by one twist, which the strip below
    // undoes exactly, so the loop has no seam.
    float phase = fract(iTime / CYCLE);
    float turn = TWIST * phase;
    // mat2 is column-major: this is the rotation by +turn, which the
    // TWIST * octave term below cancels exactly at the end of the cycle.
    vec2 view = mat2(cos(turn), sin(turn), -sin(turn), cos(turn)) * uv * exp2(-phase);

    float r = max(length(view), 1e-6);
    float lr = log2(r);
    float octave = floor(lr);
    float angle = atan(view.y, view.x) + TWIST * octave;

    // The strip: one cell per octave along x, SLICES cells around along y.
    // Both axes wrap on the fold's own period, so the seams are invisible.
    vec2 z = vec2(lr - octave, angle / TAU * SLICES) * 2.0;

    // How big a pixel is on the strip, for stopping the fold and for the
    // final fade. Uniform across the loop, so taken once.
    float pixel = max(fwidth(z.x), fwidth(z.y));

    float scale = 1.0;
    float circle = 1e9;   // distance to the nearest circle edge, in strip units
    float weight = 0.0;   // how fully that circle is drawn, by its size
    float trap = 1e9;     // orbit trap, for colour
    float radius = sqrt(INVERT);
    for (int i = 0; i < ITERATIONS; i++) {
        z = 2.0 * fract(0.5 * z + 0.5) - 1.0;
        float r2 = dot(z, z);
        // The inverting circle is the edge of every disc in the packing, so
        // its outline at each level is the drawing.
        float d = abs(sqrt(r2) - radius) / scale;
        if (d < circle) {
            circle = d;
            // A circle a few pixels across fades out rather than aliasing.
            weight = smoothstep(pixel, pixel * FADE_PX, radius / scale);
        }
        trap = min(trap, r2 + 0.3 * float(i));
        float k = max(INVERT / r2, 1.0);
        z *= k;
        scale *= k;
        // A cell smaller than a pixel has nothing left to draw.
        if (radius / scale < pixel * 0.5) break;
    }

    // The map is conformal and every distance above was divided back to strip
    // units, so one pixel is the same length everywhere the line is drawn. A
    // fwidth on the loop's result would break into dashes wherever the pixels
    // of a quad picked different circles.
    float width = pixel * LINE_PX;
    float ink = (1.0 - smoothstep(0.0, width, circle)) * weight;

    // The wash between the lines comes from the trap, so a gap reads as part
    // of a structure rather than as empty ground.
    float t = clamp(trap * 0.35, 0.0, 1.0);
    vec3 line = mix(INK_A, INK_B, 0.5 + 0.5 * cos(TAU * t + angle));
    vec3 color = GROUND + WASH * 0.35 * (1.0 - t) * (1.0 - ink);
    color = mix(color, line, ink);

    fragColor = vec4(color, 1.0);
}
