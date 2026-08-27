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
// How far from a polygon its glow is still worth drawing, in pixels. The glow
// falls off as exp(-distance / 9px) from a peak of 0.3, and 24 copies are
// drawn, so even if every one of them were this far away their sum stays
// under half of what an 8-bit channel can hold at 74px. Rounded up from
// there, since the box this bounds is cheap to widen and expensive to get
// wrong.
const float GLOW_REACH = 80.0;

const float TAU = 6.28318;
// The ribbon's colour cycle: where the three channels sit in it, how fast the
// leading edge moves through it, and how far back one trailing copy is.
const vec3 HUE_PHASE = vec3(0.0, 0.33, 0.67);
const float HUE_RATE = 0.045;
const float HUE_PER_STEP = 0.016;

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

// Squared, so that the four sides can be compared without a square root
// each. Only the winner needs the root taken, which is 24 of them a pixel
// rather than 96.
float segmentDistanceSquared(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    vec2 offset = pa - ba * h;
    return dot(offset, offset);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Work in units of screen height so line widths and speeds mean the same
    // thing at any resolution.
    float aspect = iResolution.x / iResolution.y;
    vec2 p = fragCoord / iResolution.y;
    float pixel = 1.0 / iResolution.y;

    vec3 color = vec3(0.0);

    // How far a polygon's outline can move from one copy to the next. Every
    // point of it is a blend of two corners, so none of it travels further
    // than the fastest corner does; bounce() has slope 1, so a corner covers
    // its rate times the span it crosses, every second.
    vec2 fastest = vec2(0.0);
    for (int i = 0; i < SHAPES * CORNERS; i++) {
        fastest = max(fastest, MOTION[i].xy);
    }
    float outlineMove = TRAIL_STEP
        * length(fastest * vec2(aspect - 2.0 * MARGIN, 1.0 - 2.0 * MARGIN));
    float reach = pixel * GLOW_REACH;

    // One trailing copy's hue is the next one's rotated by a fixed angle, so
    // the trail can be walked with a rotation instead of a cosine per copy.
    // The hue does not depend on the pixel, and a cosine of a vec3 twelve times
    // over was the second largest thing in this shader.
    float stepCos = cos(TAU * HUE_PER_STEP);
    float stepSin = sin(TAU * HUE_PER_STEP);

    for (int shape = 0; shape < SHAPES; shape++) {
        vec3 angle = TAU * (iTime * HUE_RATE + float(shape) * 0.5 + HUE_PHASE);
        vec3 hueCos = cos(angle);
        vec3 hueSin = sin(angle);
        // A lower bound on how far this pixel is from the copy about to be
        // drawn, carried forward from the one before it.
        float carried = 0.0;

        // age reaches 1 on the last copy, and fade is its square complement,
        // so that copy is drawn at zero: TRAIL is where the ribbon fades out,
        // not how many copies there are to draw.
        for (int step = 0; step < TRAIL - 1; step++) {
            // Each copy is drawn in the hue the leading edge had that long ago,
            // which is where the ribbon's colour gradient comes from. Taken and
            // rotated on at the top of the loop, so the early-out below cannot
            // skip a copy's turn and put the rest of the trail out of step.
            vec3 hue = 0.5 + 0.5 * hueCos;
            vec3 turned = hueCos * stepCos + hueSin * stepSin;
            hueSin = hueSin * stepCos - hueCos * stepSin;
            hueCos = turned;

            // The outline cannot have moved further than outlineMove, so what
            // the previous copy was found to be from this pixel bounds what
            // this one can be. A pixel the bound holds outside the glow's
            // reach can leave before its corners are worked out at all.
            if (step > 0) {
                carried -= outlineMove;
                if (carried > reach) continue;
            }

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

            // Most of the screen is nowhere near this polygon, and the four
            // segment distances below are what the shader spends its time on.
            // The corners bound it, so a pixel further than the glow reaches
            // from that box contributes nothing and can leave now.
            vec2 lo = min(min(points[0], points[1]), min(points[2], points[3]));
            vec2 hi = max(max(points[0], points[1]), max(points[2], points[3]));
            vec2 outside = max(max(lo - p, p - hi), vec2(0.0));
            float boxAway = length(outside);
            if (boxAway > reach) {
                carried = boxAway;
                continue;
            }

            // Closed polygon, the way Mystify draws it.
            float nearestSquared = 1e9;
            for (int i = 0; i < CORNERS; i++) {
                // Wrapping with a conditional rather than a modulo: the
                // converter turns "% CORNERS" into a signed-remainder helper,
                // and an integer division 96 times a pixel is not free.
                int next = i + 1 == CORNERS ? 0 : i + 1;
                nearestSquared = min(nearestSquared, segmentDistanceSquared(p, points[i], points[next]));
            }
            float nearest = sqrt(nearestSquared);
            carried = nearest;

            // Older copies are thinner as well as dimmer, so the ribbon tapers
            // instead of reading as a stack of equal outlines.
            float width = pixel * LINE_WIDTH * mix(1.0, 0.55, age);
            float core = smoothstep(width * 2.0, width * 0.5, nearest);
            float glow = exp(-nearest / (pixel * 9.0)) * 0.30;

            float fade = (1.0 - age) * (1.0 - age);
            // Each copy is drawn in the hue the leading edge had that long ago,
            // which is where the ribbon's colour gradient comes from.
            color += hue * (core + glow) * fade;
        }
    }

    // Enough of a lift that the black between the ribbons is not flat.
    color += vec3(0.02, 0.02, 0.05);

    fragColor = vec4(color, 1.0);
}
