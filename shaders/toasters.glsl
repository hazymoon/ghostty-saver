// After Dark's flying toasters, with the toast.
//
// Stateless by construction, like every shader here. There is no list of
// toasters: the screen is rotated so that the direction of flight is the x
// axis, slid along that axis by iTime, and cut into tiles. One tile holds one
// toaster - or one slice of toast - and which it is comes out of a hash of the
// tile, so the flock is decided by where you are rather than by what happened
// before.
//
// A pixel checks the nine tiles around it, because a toaster is drawn larger
// than its tile and overhangs its neighbours. Eight of those nine miss, and
// the bounding box test at the top of the loop is what makes that cheap.

const int LAYERS = 2;
const float FLIGHT = 0.42;        // downward part of the direction of flight
const float FLAP_RATE = 5.2;      // wingbeats per second, before per-bird jitter
const float TOAST_SHARE = 0.28;   // fraction of the flock that is breakfast

const vec3 CHROME_LIGHT = vec3(0.93, 0.96, 1.00);
const vec3 CHROME_MID = vec3(0.55, 0.62, 0.74);
const vec3 CHROME_DARK = vec3(0.13, 0.16, 0.24);
const vec3 SLOT_COLOR = vec3(0.03, 0.04, 0.06);
const vec3 WING_COLOR = vec3(0.88, 0.92, 0.98);
const vec3 TOAST_COLOR = vec3(0.87, 0.68, 0.36);
const vec3 CRUST_COLOR = vec3(0.52, 0.32, 0.13);
const vec3 SKY = vec3(0.014, 0.016, 0.030);

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float sdRoundedBox(vec2 p, vec2 halfSize, float radius) {
    vec2 d = abs(p) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Good enough for drawing: exact on the axes, slightly off on the diagonals.
float sdEllipse(vec2 p, vec2 radii) {
    return (length(p / radii) - 1.0) * min(radii.x, radii.y);
}

mat2 rotation(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat2(c, s, -s, c);
}

// Coverage of a shape at signed distance d, with aa the size of a pixel in
// whatever units d is measured in.
float fill(float d, float aa) {
    return 1.0 - smoothstep(-aa, aa, d);
}

// Over operator, on straight (not premultiplied) colour.
vec4 over(vec4 top, vec4 bottom) {
    float alpha = top.a + bottom.a * (1.0 - top.a);
    if (alpha <= 0.0) { return vec4(0.0); }
    return vec4((top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / alpha, alpha);
}

// One wing: a feathered paddle that pivots about its root. Drawn in the
// toaster's own space, so x is 1.0 across the body.
vec4 wing(vec2 p, vec2 pivot, float angle, float aa) {
    vec2 w = rotation(angle) * (p - pivot);
    // Grown out along +x from the root: they trail behind, the toaster flies
    // the other way.
    float d = sdEllipse(w - vec2(0.33, 0.0), vec2(0.36, 0.155));
    float shape = fill(d, aa);
    if (shape <= 0.0) { return vec4(0.0); }

    // A few feather divisions and a shaded trailing edge, kept faint: at this
    // size strong grooves read as a striped tube rather than as a wing.
    float groove = abs(fract(w.x * 3.0) - 0.5) * 2.0;
    float shade = mix(0.88, 1.0, smoothstep(0.25, 0.65, groove))
        * mix(0.66, 1.0, smoothstep(0.15, -0.05, w.y));
    return vec4(WING_COLOR * shade, shape);
}

// A toaster in its own space: the body is 1.0 wide and centred on the origin,
// with y downward.
vec4 toaster(vec2 p, float seed, float aa) {
    float flap = sin(iTime * FLAP_RATE * (0.8 + 0.4 * seed) + seed * 39.0);

    // Far wing first, so the near one lands on top of it.
    vec4 image = wing(p, vec2(0.30, -0.14), 0.95 - flap * 0.40, aa);
    image = over(wing(p, vec2(0.16, -0.28), 0.42 + flap * 0.46, aa), image);

    float body = sdRoundedBox(p, vec2(0.50, 0.32), 0.09);
    float onBody = fill(body, aa);
    if (onBody > 0.0) {
        // Chrome: a bright top, a dark waist and a lift again at the foot.
        float down = (p.y + 0.32) / 0.64;
        vec3 metal = mix(CHROME_LIGHT, CHROME_MID, smoothstep(0.0, 0.50, down));
        metal = mix(metal, CHROME_DARK, smoothstep(0.62, 0.92, down));
        metal = mix(metal, CHROME_MID, 0.75 * smoothstep(0.93, 1.0, down));
        // A highlight running down the left cheek.
        metal = mix(metal, CHROME_LIGHT, 0.45 * fill(sdEllipse(p - vec2(-0.28, -0.02), vec2(0.07, 0.20)), aa));
        image = over(vec4(metal, onBody), image);

        // The slot is cut into the body, so it is clipped to it.
        float slot = sdRoundedBox(p - vec2(-0.02, -0.22), vec2(0.30, 0.048), 0.035);
        image = over(vec4(SLOT_COLOR, fill(slot, aa) * onBody), image);
    }

    // The lever stands proud of the side, so it is drawn outside the test
    // above: inside it, the part that overhangs the body would be cut off.
    float lever = sdRoundedBox(p - vec2(0.46, -0.06), vec2(0.06, 0.085), 0.04);
    image = over(vec4(CHROME_MID * 1.2, fill(lever, aa)), image);

    return image;
}

// A slice of toast, same space: 1.0 wide, crust all the way round.
vec4 toast(vec2 p, float seed, float aa) {
    // The bread shape: a rounded square with a dome on top.
    float square = sdRoundedBox(p - vec2(0.0, 0.10), vec2(0.32, 0.22), 0.07);
    float dome = sdEllipse(p - vec2(0.0, -0.12), vec2(0.32, 0.19));
    float d = min(square, dome);

    float shape = fill(d, aa);
    if (shape <= 0.0) { return vec4(0.0); }

    // Crust is the outer band; the crumb inside is lighter and blotchy. The
    // distance is negative inside, so this rises towards the rim - no `1.0 -`,
    // which would paint a dark middle inside a pale edge.
    float crust = smoothstep(-0.075, -0.045, d);
    float toasting = 0.91 + 0.09 * sin(p.x * 12.0 + seed * 30.0) * sin(p.y * 9.0 - seed * 11.0);
    vec3 colour = mix(TOAST_COLOR * toasting, CRUST_COLOR, crust);
    return vec4(colour, shape);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle, y downward - which is the way
    // fragCoord already runs here and in Ghostty alike.
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float pixel = 1.0 / iResolution.y;

    // Rotate so that the direction of flight is +x. Everything below tiles
    // along that axis, which is what makes the flock fly in formation without
    // any of them being told where the others are.
    vec2 heading = normalize(vec2(-1.0, FLIGHT));
    mat2 toLane = mat2(heading.x, -heading.y, heading.y, heading.x);
    // ...and back again, because the flock flies along a slanted lane but each
    // toaster stays the right way up.
    mat2 fromLane = mat2(heading.x, heading.y, -heading.y, heading.x);

    vec4 image = vec4(0.0);

    for (int layer = 0; layer < LAYERS; layer++) {
        // The near layer is bigger, faster and drawn last, so it passes in
        // front of the far one.
        float near = float(layer) / float(LAYERS - 1);
        float tile = mix(0.23, 0.36, near);
        float speed = mix(0.14, 0.26, near);
        float scale = 0.52;                       // tiles per body width
        float aa = pixel / (tile * scale);        // a pixel, in toaster units

        vec2 lane = toLane * p / tile;
        lane.x -= iTime * speed / tile;
        vec2 home = floor(lane);

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                vec2 cell = home + vec2(float(dx), float(dy));
                float seed = hash21(cell + float(layer) * 31.7);

                // Scatter them off the lattice, or the flock reads as wallpaper.
                vec2 jitter = vec2(hash21(cell + 5.1), hash21(cell + 8.3)) * 0.34 - 0.17;
                vec2 local = fromLane * (lane - (cell + 0.5 + jitter)) / scale;

                // The bounding box that makes nine tiles per pixel affordable:
                // eight of them stop here.
                if (abs(local.x) > 1.15 || abs(local.y) > 1.15) { continue; }

                vec4 drawn = seed < TOAST_SHARE ? toast(local, seed, aa) : toaster(local, seed, aa);
                // The far layer is dimmer as well as smaller and slower, which
                // is most of what sells the two depths.
                drawn.rgb *= mix(0.52, 1.0, near);
                // The nine tiles are visited in ascending order and any two
                // that overlap are both inside the window, so which of them
                // ends up on top is the same for every pixel they cover.
                image = over(drawn, image);
            }
        }
    }

    vec3 color = mix(SKY, image.rgb, image.a);
    fragColor = vec4(color, 1.0);
}
