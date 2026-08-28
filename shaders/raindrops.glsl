// Drops running down a dark window at night, each one bending the city
// lights behind it and leaving a beaded trail that thins out behind it.
//
// Stateless by construction, like every shader here. The window is cut into
// columns, and each column carries one drop at a time: where it is comes from
// mod(iTime * speed + phase, 1.0), and which drop it is - size, wobble, where
// in the column it runs - is re-hashed from floor(...) of the same quantity,
// so a column gets a different drop each pass, the way a column of rain in
// matrix.glsl gets a different trail.
//
// The trail needs no memory either. A drop's path is a closed form (straight
// down with a small sine wobble), so a pixel can ask how long ago the drop
// passed it and fade on that answer; the beads left behind are a hash along
// the path, gated by the same fade.
//
// The background is a function, not a buffer: a few soft coloured discs, so
// that the refraction inside a drop has something to invert.
//
// A drop reaches into its neighbours' columns by at most its own width, so
// three columns are checked, with a cheap horizontal bound before anything is
// evaluated exactly. That is the whole cost.

const float COLUMN = 0.075;       // column width, in screen heights
const float FALL_SECONDS = 9.0;   // slowest drop takes this long down the window
const float TRAIL_LIFE = 6.0;     // seconds for a trail to dry out
const float DROP_SHARE = 0.72;    // fraction of column passes that carry a drop
const float REFRACT = 14.0;       // how far the background is pulled in, in drop radii
const float BEADS = 34.0;         // beads per screen height along a trail

const vec3 GLASS = vec3(0.012, 0.014, 0.022);
const vec3 LIGHT_A = vec3(1.00, 0.72, 0.30);   // sodium
const vec3 LIGHT_B = vec3(0.35, 0.65, 1.00);   // neon
const vec3 LIGHT_C = vec3(0.95, 0.30, 0.55);   // signage

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Out-of-focus city lights. Low frequency and soft, so the displacement inside
// a drop shows as a shifted, inverted patch of colour rather than as noise.
vec3 background(vec2 p) {
    vec3 color = GLASS;
    // A grid of candidate lights; a hash decides which cells carry one.
    vec2 scale = vec2(6.0, 4.0);
    vec2 cell = floor(p * scale);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 c = cell + vec2(float(i), float(j));
            float seed = hash21(c);
            if (seed > 0.42) { continue; }
            vec2 at = (c + vec2(hash21(c + 1.3), hash21(c + 7.9))) / scale;
            float r = 0.045 + 0.08 * hash21(c + 3.1);
            float d = length(p - at);
            float disc = 1.0 - smoothstep(r * 0.75, r * 1.15, d);
            vec3 tint = seed < 0.14 ? LIGHT_A : (seed < 0.28 ? LIGHT_B : LIGHT_C);
            color += tint * disc * (0.20 + 0.35 * hash21(c + 5.7));
        }
    }
    // Ground glow along the bottom, so the lower window is not empty.
    color += LIGHT_A * 0.10 * smoothstep(0.35, 1.0, p.y);
    return color;
}

// Everything a column contributes at this pixel: the drop's coverage, the
// displacement it applies to the background, and the wet trail.
// p is in screen heights with y downward, aspect is the screen width in the
// same units, column is the integer column index.
void column(vec2 p, float column, float aspect, inout float cover, inout vec2 shift, inout float wet) {
    float seed = hash21(vec2(column, 17.0));

    // Where the drop is on its way down, and which pass this is.
    float speed = (0.6 + 0.9 * hash11(seed * 3.7)) / FALL_SECONDS;
    float travelled = iTime * speed + seed * 4.0;
    float pass = floor(travelled);
    float along = fract(travelled);
    float passSeed = hash21(vec2(column, pass));

    if (passSeed > DROP_SHARE) { return; }

    float size = 0.012 + 0.016 * hash11(passSeed * 9.1);
    // The drop runs down a lane inside its column, wobbling a little.
    float lane = (column + 0.25 + 0.5 * hash11(passSeed * 5.3)) * COLUMN;
    float wobbleRate = 6.0 + 5.0 * hash11(passSeed * 2.9);
    float wobble = COLUMN * 0.18;
    float dropX = lane + wobble * sin(along * wobbleRate + passSeed * 6.28);
    // Slightly past the edges so a drop is born and dies off screen.
    float dropY = along * 1.12 - 0.06;

    // Cheap bound: nothing from this column reaches further sideways than
    // the lane plus its wobble and the widest drop.
    float reach = wobble + size * 2.2 + 0.006;
    if (abs(p.x - lane) > reach) { return; }

    // The drop: a teardrop, wider at the bottom where it is running.
    vec2 q = p - vec2(dropX, dropY);
    vec2 radii = vec2(size, size * (1.25 + 0.6 * smoothstep(-size, size, q.y)));
    float e = length(q / radii);
    float d = (e - 1.0) * size;
    float aa = 1.4 / iResolution.y;
    float drop = 1.0 - smoothstep(-aa, aa, d);
    if (drop > 0.0) {
        // Normal of the surface from the ellipse, unit length at the rim,
        // which is where it bends the most. Pulling the sample in against
        // the normal is what turns the city upside down inside the drop.
        vec2 n = q / radii;
        float rim = clamp(e, 0.0, 1.0);
        shift += -n * size * REFRACT * (0.35 + rim * rim) * drop;
        cover = max(cover, drop);
    }

    // The trail: where the drop has been in this pass. The wobble is a
    // function of along, so the path is recoverable for every y above the
    // drop, and "how long ago" is the difference in along over the speed.
    float alongHere = (p.y + 0.06) / 1.12;
    if (alongHere < along && alongHere > 0.0) {
        float ago = (along - alongHere) / speed;
        float pathX = lane + wobble * sin(alongHere * wobbleRate + passSeed * 6.28);
        float dry = 1.0 - smoothstep(0.0, TRAIL_LIFE, ago);
        // A thin wet streak that narrows as it dries.
        float width = size * (0.35 + 0.35 * dry);
        float streak = 1.0 - smoothstep(width - aa, width + aa, abs(p.x - pathX));
        wet = max(wet, streak * dry * 0.55);

        // Beads: little static drops left along the path, spaced by a hash.
        float slot = floor(p.y * BEADS);
        float beadSeed = hash21(vec2(column * 3.0 + pass, slot));
        if (beadSeed < 0.45 * dry + 0.15) {
            vec2 beadAt = vec2(
                pathX + (hash11(beadSeed * 7.7) - 0.5) * size * 0.8,
                (slot + 0.5) / BEADS
            );
            float beadSize = size * (0.22 + 0.30 * hash11(beadSeed * 3.3));
            float bd = length(p - beadAt) - beadSize;
            float bead = 1.0 - smoothstep(-aa, aa, bd);
            if (bead > 0.0) {
                vec2 bn = (p - beadAt) / beadSize;
                shift += -bn * beadSize * REFRACT * 0.5 * bead;
                cover = max(cover, bead * 0.9);
            }
        }
    }
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin top left, y downward: the drops fall with it.
    vec2 p = fragCoord / iResolution.y;
    float aspect = iResolution.x / iResolution.y;

    float cover = 0.0;
    vec2 shift = vec2(0.0);
    float wet = 0.0;

    float c = floor(p.x / COLUMN);
    column(p, c - 1.0, aspect, cover, shift, wet);
    column(p, c, aspect, cover, shift, wet);
    column(p, c + 1.0, aspect, cover, shift, wet);

    // Rain on the far side of the glass: the background is blurred and dim,
    // and inside a drop it is pulled in from further away and flipped, which
    // is what an upside-down city in a drop looks like.
    vec3 color = background(vec2(p.x / aspect, p.y)) * 0.55;
    if (cover > 0.0) {
        vec2 displaced = p + shift;
        vec3 inside = background(vec2(displaced.x / aspect, displaced.y)) * 1.35;
        // A bright edge where the surface turns away.
        float rimLight = clamp(length(shift) * 4.0, 0.0, 1.0);
        inside += vec3(0.6, 0.7, 0.85) * rimLight * 0.35;
        color = mix(color, inside, cover);
    }
    // The wet streak brightens the glass a touch; it catches light.
    color += vec3(0.30, 0.34, 0.42) * wet * 0.35;

    fragColor = vec4(color, 1.0);
}
