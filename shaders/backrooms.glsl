// The Backrooms: a slow camcorder walk through endless yellow rooms under
// fluorescent light, on a worn VHS tape, past a corner where the lights are out.
//
// Stateless like every shader here: the camera's position, every wall, every
// flickering tube and every tape fault is a function of iTime and a hash.
//
// The world is a grid of 4 m cells with a square pillar at every corner and,
// on a hash of the edge, a partition wall along it. Walls repeat every
// SUPER cells in both directions, and a fixed walk through one such tile is
// baked in below: the walk ends one tile north of where it starts, so a lap
// of the loop moves the camera one tile on and never shows the same room
// twice from the same side. Every edge the walk crosses is forced open
// (OPEN_SIDES), which is what lets the camera be placed in closed form from
// iTime without ever tracing the maze.
//
// Rays are not sphere-traced: an SDF evaluated in one cell knows nothing
// about the next cell's wall and would step through it at grazing angles. A
// 2D DDA walks the ray cell by cell instead, testing the pillars of each
// cell and the wall on each boundary it crosses, and stops at the floor or
// ceiling. Everything up to the VHS pass runs for every pixel with no early
// exit, because the chroma bleed is a dFdx of the scene colour and, as
// gears found out, a derivative taken after a skip draws differently on
// different GPUs.
//
// The picture is the 4:3 camcorder frame, with black bars either side on a
// wide screen; set PILLARBOX to 0 to fill the screen instead.

#define PILLARBOX 1

const float CELL = 4.0;            // metres per grid cell
const float SUPER = 8.0;           // cells per repeating tile
const float CEILING = 2.7;         // metres, a standard office drop ceiling
const float EYE = 1.60;            // camera height: the eye of someone 170 cm
                                   // tall, with the viewfinder pressed to it
const float PILLAR = 0.19;         // half width of a corner pillar
const float WALL_HALF = 0.06;      // half thickness of a partition wall
const float WALL_DENSITY = 0.42;   // fraction of edges that carry a wall
const float LIGHT_DENSITY = 0.72;  // fraction of cells with a working tube
const int MAX_CELLS = 24;          // DDA steps before a ray gives up in fog: 96 m,
                                   // where the fog leaves under 0.1 % of the scene

// How often things happen. A bad tube has a fit with probability
// FIT_CHANCE in every FIT_SLOT seconds; the deck drops a frame with
// probability DROP_CHANCE in every DROP_SLOT seconds; a tracking band rolls
// with probability BAND_CHANCE in every BAND_SLOT seconds. All of them are
// rare: the walk should be dull, and a fault is an event.
const float FIT_SLOT = 10.0;
const float FIT_CHANCE = 0.15;
const float FIT_LENGTH = 0.7;      // seconds a fit lasts
const float DROP_SLOT = 8.0;
const float DROP_CHANCE = 0.2;
const float DROP_HOLD = 0.25;      // seconds the picture freezes
const float BAND_SLOT = 10.0;
const float BAND_CHANCE = 0.2;
const float BAND_ROLL = 2.0;       // seconds the band takes to roll through

// The tape's colour. VHS records luma as FM, which suppresses noise above
// its threshold, and colour as AM on a 629 kHz subcarrier, which does not;
// and it keeps only about 40 colour samples to a line against 333 of
// luma. So the noise on a tape is coloured before it is grey, and it
// comes as wide, flat blotches rather than grain; the hue of a line drifts
// with the tape's speed (yellow swings between green and orange); a fine
// luma pattern such as the wallpaper's stripes is mistaken for colour
// (cross-colour, the rainbow on a striped shirt); and colour leaks back
// into luma as the dots that crawl along a saturated edge. The tracking
// band itself is grey, luma FM falling below its threshold, and colour
// only tears at its edges.
const float LUMA_SAMPLES = 333.0;  // luma samples to a line
const float CHROMA_SAMPLES = 40.0; // colour samples to a line
const float LINES = 480.0;         // lines to the picture
const float CHROMA_NOISE = 0.04;   // in I/Q, where the yellow walls are about 0.17
const float LUMA_GRAIN = 0.06;     // fine grain in Y
const float LUMA_SNOW = 0.018;     // sparse impulses in Y
const float PHASE_ERROR = 0.14;    // radians the hue of a line drifts by
const float CROSS_COLOR = 0.8;     // colour made from a horizontal luma slope
const float DOT_CRAWL = 0.18;      // luma made from colour at the subcarrier
const float SUBCARRIER = 0.125;    // cycles per pixel
const float YC_DELAY = 6.0;        // pixels the colour lags the luma by

// The walk is slow: 30 cells in what is left of a 150 s lap after two
// pauses is 0.90 m/s, the pace of someone who does not know the place,
// against the 1.3 m/s of a commuter.
const float LAP = 150.0;           // seconds per lap of the walk
const float PAUSE = 10.0;          // seconds the camera stands still, twice a lap
const float EASE = 2.0;            // seconds to slow into and out of a pause
const float PAUSE1 = 30.0;         // lap seconds at which each pause begins:
const float PAUSE2 = 106.0;        // on the blackout's edge, and on the way back
const int STEPS = 30;              // cells walked per lap
const float PACE = 6.8;            // footsteps per cell: 0.59 m steps, 1.5 Hz

// The camera is held by a person, and a person's head is steadier than the
// hand-held shake that shaders reach for. Everything below is chosen so
// that watching for an hour is not like being on a boat:
//
// - No motion at all between 0.1 and 0.4 Hz, the band where motion
//   sickness peaks (Golding 2001; Diels & Howarth 2013). A slow "drift" on
//   yaw, pitch, roll or position is exactly that band, so there is none.
//   The gait's unevenness is a phase modulation of the steps, which puts
//   sidebands round the step rate and nothing at the modulating rate.
// - The footstep bob and sway move the camera's position only, never its
//   angle: a rotational bob sweeps the whole image and drives vection.
// - The eyes counter the bob (the vestibulo-ocular reflex): the camera
//   keeps looking at a point GAZE metres ahead of where the head would be
//   without the bob, so the far wall stands still and only the near walls
//   show the step, as parallax. The reflex's gain falls with frequency,
//   so the step's fundamental is countered by VOR_STEP and its harmonics
//   and the heel strike by only VOR_HIGH: the strike leaks into the
//   picture a little, which is what makes a step feel like a footfall
//   rather than a swell.
// - Roll is a fraction of a degree with each stride, and never on a turn.
//   Leaning into a turn is a lateral shift of LEAN instead.
// - Turns are spread over a tent of TURN cells either side of the path's
//   corner, so the yaw rate is continuous and stays under about 30
//   degrees a second, and the looks in the pauses under 60.
//   The body walks the same smoothed path that its heading is read from,
//   so it always moves the way it faces and slows into a corner, on a
//   radius of about 2 m; the gait scales with that speed, so it does not
//   march on the spot through a corner; and the head turns on the neck, NECK metres
//   behind the eyes, so turning the head moves the eyes sideways and the
//   picture parallaxes as well as rotates. Without both, a turn is a tank
//   pivoting on the spot.
//
// And a person's gait is not a metronome, or a sine wave. The steps are
// uneven (JITTER, ASYM, STEP_JITTER), the rise of each is the arc of an
// inverted pendulum, flat at the top and sharp at the bottom (ARCH2,
// ARCH3), each heel strike rings for a few hundredths of a second (IMPACT,
// KICK), the pace surges at each strike and slows over the stance
// (RIPPLE), and the head turns with the steps rather than at a steady
// rate: its yaw advances fastest in each step's swing (GATE), and leads
// the body into a corner by about a second (LEAD). Once a stride rather
// than once a step, the turn came in pulses that read as pivoting on one
// foot.
const float BOB = 0.025;           // metres, vertical, once a step
const float SWAY = 0.020;          // metres, lateral, once a stride
const float GAIT_ROLL = 0.007;     // radians, once a stride
const float GAZE = 6.0;            // metres ahead, where the eyes fix
const float VOR_STEP = 0.75;       // share of the step's fundamental the eyes counter
const float VOR_HIGH = 0.5;        // share of the harmonics and the strike
const float TURN = 1.5;            // cells either side of a corner it is turned over
const float LEAD = 0.25;           // cells the head looks ahead of the body
const float NECK = 0.10;           // metres from the neck's axis forward to the eyes
const float NECK_MAX = 0.73;       // radians the head turns on the neck, at most
const float LEAN = 0.025;          // metres shifted into a turn
const float GATE = 0.5;            // depth of the step's modulation of the yaw rate
const float ARCH2 = 0.20;          // second and third harmonics of the bob
const float ARCH3 = 0.05;
const float IMPACT = 0.004;        // metres the heel strike rings by
const float IMPACT_TAU = 0.07;     // seconds it takes to die away (>= 3 frames)
const float IMPACT_HZ = 9.0;       // and how fast it rings
const float KICK = 0.0017;         // radians of pitch the strike knocks in, uncountered
const float KICK_TAU = 0.08;
const float RIPPLE = 0.05;         // fraction the pace surges by at each strike
const float JITTER = 0.22;         // steps of slow phase wander in the gait
const float ASYM = 0.03;           // one leg's bob over the other's
const float STEP_JITTER = 0.06;    // random size of each step's bob

// A 1990s camcorder at the wide end of its zoom is not wide: about 45
// degrees across, 55 to 65 with the wide converter Kane Pixels' footage
// looks shot through. This is the converter: 56 degrees across the 4:3
// frame, with the converter's few percent of barrel on top.
const float FOCAL = 1.25;          // 1 / tan(half the vertical field of view)
const float BARREL = 0.05;         // lens distortion at the corners

// Colours, before the camera's white balance goes wrong on them.
const vec3 WALL_COLOR = vec3(0.78, 0.66, 0.30);
const vec3 CARPET_COLOR = vec3(0.42, 0.35, 0.17);
const vec3 CEILING_COLOR = vec3(0.70, 0.66, 0.50);
const vec3 TUBE_COLOR = vec3(1.00, 0.98, 0.82);
const vec3 FOG_COLOR = vec3(0.09, 0.075, 0.03);

// The walk, in cells. Consecutive entries differ by one step along an axis,
// the last is the first moved one tile north, and OPEN_SIDES is derived
// from it: bit 1 = +x, 2 = +z, 4 = -x, 8 = -z, indexed by z * SUPER + x.
// The three edges between x = 4 and x = 5 at z = 3..5 are open too, so the
// first pause looks into the blackout rather than at a wall.
//
// The walk is one wide anticlockwise loop with six corners, none nearer
// than three cells to the next, and it leaves the tile heading the way it
// entered. Corners any closer than that, and above all a pair that
// reverses the direction within a cell or two, come out of the smoothing
// below as the body turning on the spot while its feet keep going, which
// is not walking. No room is entered twice from the same side, and none
// of the blackout's rooms is entered at all.
const vec2 WAYPOINT[31] = vec2[31](
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(1.0, 2.0), vec2(2.0, 2.0), vec2(3.0, 2.0),
    vec2(4.0, 2.0), vec2(4.0, 3.0), vec2(4.0, 4.0), vec2(4.0, 5.0), vec2(4.0, 6.0),
    vec2(4.0, 7.0), vec2(4.0, 8.0), vec2(4.0, 9.0), vec2(4.0, 10.0), vec2(3.0, 10.0),
    vec2(2.0, 10.0), vec2(1.0, 10.0), vec2(0.0, 10.0), vec2(-1.0, 10.0), vec2(-2.0, 10.0),
    vec2(-3.0, 10.0), vec2(-3.0, 9.0), vec2(-3.0, 8.0), vec2(-3.0, 7.0), vec2(-3.0, 6.0),
    vec2(-2.0, 6.0), vec2(-1.0, 6.0), vec2(0.0, 6.0), vec2(1.0, 6.0), vec2(1.0, 7.0),
    vec2(1.0, 8.0)
);
const int OPEN_SIDES[64] = int[64](
     0, 10,  0,  0, 10, 10,  0,  0,
     0, 10,  0,  0, 10, 10,  0,  0,
     5, 13,  5,  5, 14,  9,  5,  5,
     0,  0,  0,  0, 11,  4,  0,  0,
     0,  0,  0,  0, 11,  4,  0,  0,
     0,  0,  0,  0, 11,  4,  0,  0,
     5,  6,  0,  0, 10,  3,  5,  5,
     0, 10,  0,  0, 10, 10,  0,  0
);

// A hash without a sin(), on whole numbers (pcg2d). The walls and the
// tubes are placed by it, and so are the stains, the grain and the tape's
// faults: the walls are looked up a dozen times a pixel and the tubes
// nine, and the shared sin() hash was a measurable part of the frame.
// The tape's rarer events keep hash11.
float cheap21(vec2 p) {
    uvec2 v = uvec2(ivec2(p)) * 1664525u + 1013904223u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v ^= v >> 16u;
    return float((v.x ^ v.y) & 0x00ffffffu) / 16777216.0;
}

// The dark corner: cells x in [5, 8) and z in [3, 6) of every tile have no
// working light. The walk runs up its west edge, x = 4, and the first pause
// is there, looking in.
bool inBlackout(vec2 cell) {
    vec2 c = mod(cell, SUPER);
    return c.x >= 5.0 && c.y >= 3.0 && c.y < 6.0;
}

// --- the walk -------------------------------------------------------------

// Integral of smoothstep(a, b, x) from -inf to x. Zero before a, rising to
// (b - a) / 2 at b and then growing at slope one.
float smoothstepIntegral(float a, float b, float x) {
    float w = b - a;
    float n = clamp((x - a) / w, 0.0, 1.0);
    float ramp = w * (n * n * n - 0.5 * n * n * n * n);
    return ramp + max(x - b, 0.0);
}

// Seconds spent standing still by lap-time u in a pause that begins at
// `start`: eases in over EASE, holds, eases out over EASE.
float stoodStill(float u, float start) {
    return smoothstepIntegral(start, start + EASE, u)
         - smoothstepIntegral(start + PAUSE - EASE, start + PAUSE, u);
}

// How far into the lap's walk the camera is at lap-time u, in cells. Each
// eased pause costs PAUSE - EASE seconds of walking, and the speed is
// whatever gets STEPS cells done in what is left of the lap: walked(LAP) is
// exactly STEPS, so the seam between laps is continuous in position and in
// speed. Lap-time, not iTime: stoodStill saturates after its pause, so fed
// absolute time the pauses would only ever happen once.
float walkSpeed() {
    return float(STEPS) / (LAP - 2.0 * (PAUSE - EASE));
}

float walked(float u) {
    return walkSpeed() * (u - stoodStill(u, PAUSE1) - stoodStill(u, PAUSE2));
}

// Fraction of walking pace at lap-time u: 1 on the move, 0 mid-pause. Drives
// the footstep bob so it fades out as the camera stops.
float pace(float u) {
    float p1 = smoothstep(PAUSE1, PAUSE1 + EASE, u) - smoothstep(PAUSE1 + PAUSE - EASE, PAUSE1 + PAUSE, u);
    float p2 = smoothstep(PAUSE2, PAUSE2 + EASE, u) - smoothstep(PAUSE2 + PAUSE - EASE, PAUSE2 + PAUSE, u);
    return 1.0 - p1 - p2;
}

// A bump that rises over the first half of a pause and falls over the
// second: how far the camera has turned to look at something before
// turning back. Both halves are long, so the looks peak at about 35
// degrees a second.
float lookBump(float u, float start) {
    return smoothstep(start + 0.3, start + PAUSE * 0.5, u)
         - smoothstep(start + PAUSE * 0.55, start + PAUSE - 0.2, u);
}

// Waypoint k of the walk, for any k: laps beyond the first move the whole
// tile north.
vec2 waypoint(float k) {
    float lap = floor(k / float(STEPS));
    return WAYPOINT[int(k - lap * float(STEPS))] + vec2(0.0, lap * SUPER);
}

// The polyline convolved with a tent of half-width TURN, at arc length s:
// where the body is and which way it is moving. Segment by segment under
// the tent, the position is linear and the weight is linear, so both
// integrals are closed form and cost one waypoint per segment. The tent
// leaves the position C2 and the tangent C1: the yaw rate never jumps.
// `dir` is not normalised; it is shorter in a corner than on a straight,
// and that is how fast the body is going in cells per cell of s.
void smoothPath(float s, out vec2 pos, out vec2 dir) {
    pos = vec2(0.0);
    dir = vec2(0.0);
    float k0 = floor(s - TURN);
    float k1 = floor(s + TURN);
    vec2 w = waypoint(k0);
    for (float k = k0; k <= k1; k += 1.0) {
        vec2 wn = waypoint(k + 1.0);
        vec2 d = wn - w;
        vec2 at0 = w + d * (s - k);  // the segment's line at tau = 0
        // tau = sigma - s over the segment, clipped to the tent, and split
        // at tau = 0 where the tent's slope changes sign.
        float a = max(k - s, -TURN);
        float b = min(k + 1.0 - s, TURN);
        for (int part = 0; part < 2; part++) {
            float ta = part == 0 ? a : max(a, 0.0);
            float tb = part == 0 ? min(b, 0.0) : b;
            if (tb > ta) {
                float c = part == 0 ? -1.0 / TURN : 1.0 / TURN;  // weight = 1 - c * tau
                float i1 = tb - ta;
                float i2 = 0.5 * (tb * tb - ta * ta);
                float i3 = (tb * tb * tb - ta * ta * ta) / 3.0;
                pos += at0 * (i1 - c * i2) + d * (i2 - c * i3);
                dir += d * (i1 - c * i2);
            }
        }
        w = wn;
    }
    pos /= TURN;
    dir /= TURN;
}

// --- the gait -------------------------------------------------------------

// Value noise on a line, and three octaves of it, in [-0.5, 0.5].
float noise1(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), f);
}

float fbm1(float x) {
    return 0.55 * noise1(x) + 0.30 * noise1(x * 2.1 + 7.3) + 0.15 * noise1(x * 4.3 + 19.1) - 0.5;
}

// How high step n bobs, relative to an average step: one leg over the
// other, and a little at random.
float stepSize(float n) {
    float side = mod(n, 2.0) < 0.5 ? 1.0 : -1.0;
    return 1.0 + ASYM * side + (hash11(n * 7.13) - 0.5) * 2.0 * STEP_JITTER;
}

// The heel strike as a damped ring, at seconds tt after the strike.
float ring(float tt, float tau) {
    return -exp(-tt / tau) * sin(6.2831853 * IMPACT_HZ * tt);
}

// --- the maze -------------------------------------------------------------

bool sideOpen(vec2 cell, int bit) {
    vec2 c = mod(cell, SUPER);
    int mask = OPEN_SIDES[int(c.y) * 8 + int(c.x)];
    return (mask & bit) != 0;
}

// Whether the edge on the +x side (axisX) or +z side of `cell` carries a
// wall, and which part of it: 0 none, 1 the whole edge, 2 the low half,
// 3 the high half. Half walls are what make the rooms read as rooms and not
// as a grid of corridors. One hash decides both: below WALL_DENSITY there
// is a wall, and where below says which part.
int wallOn(vec2 cell, bool axisX) {
    if (sideOpen(cell, axisX ? 1 : 2)) return 0;
    vec2 c = mod(cell, SUPER);
    float h = cheap21(vec2(c.x * 2.0 + (axisX ? 1.0 : 0.0), c.y));
    if (h > WALL_DENSITY) return 0;
    float kind = h / WALL_DENSITY;
    return kind < 0.5 ? 1 : (kind < 0.75 ? 2 : 3);
}

bool wallCovers(int kind, float along) {
    if (kind == 1) return true;
    if (kind == 2) return along < 0.5;
    if (kind == 3) return along > 0.5;
    return false;
}

// Nearest hit of the ray with the four corner pillars of `cell`, as a
// distance, or 1e9. Pillars are square columns through the whole height.
float hitPillars(vec3 ro, vec3 rd, vec2 cell, out vec3 normal) {
    float best = 1e9;
    normal = vec3(0.0);
    vec2 inv = 1.0 / vec2(rd.x == 0.0 ? 1e-6 : rd.x, rd.z == 0.0 ? 1e-6 : rd.z);
    for (int i = 0; i < 4; i++) {
        vec2 corner = (cell + vec2(float(i & 1), float(i >> 1))) * CELL;
        vec2 lo = (corner - PILLAR - ro.xz) * inv;
        vec2 hi = (corner + PILLAR - ro.xz) * inv;
        vec2 tmin = min(lo, hi);
        vec2 tmax = max(lo, hi);
        float enter = max(tmin.x, tmin.y);
        float exit = min(tmax.x, tmax.y);
        if (enter < exit && enter > 0.0 && enter < best) {
            best = enter;
            normal = tmin.x > tmin.y
                ? vec3(-sign(rd.x), 0.0, 0.0)
                : vec3(0.0, 0.0, -sign(rd.z));
        }
    }
    return best;
}

// Nearest hit of the ray with the partition walls on the two edges of
// `cell` the ray is heading for, as slabs WALL_HALF thick with their ends
// exposed, or 1e9. `inv` is 1 / rd.xz and `step` is sign(rd.xz). The
// walls on the two edges behind the ray were those ahead of it in the
// cell before, and a wall's slab is thinner than a pillar, so a hit a
// little beyond a cell's exit is accepted there and never missed here.
float hitWalls(vec3 ro, vec3 rd, vec2 cell, vec2 inv, vec2 step, out vec3 normal) {
    float best = 1e9;
    normal = vec3(0.0);
    for (int e = 0; e < 2; e++) {
        bool axisX = e == 0;
        float back = axisX ? step.x : step.y;
        vec2 owner = cell - (back < 0.0 ? (axisX ? vec2(1.0, 0.0) : vec2(0.0, 1.0)) : vec2(0.0));
        int kind = wallOn(owner, axisX);
        if (kind == 0) continue;
        float line = ((axisX ? owner.x : owner.y) + 1.0) * CELL;
        float base = (axisX ? owner.y : owner.x) * CELL;
        vec2 along = base + CELL * vec2(kind == 3 ? 0.5 : 0.0, kind == 2 ? 0.5 : 1.0);
        float oa = axisX ? ro.x : ro.z;
        float ol = axisX ? ro.z : ro.x;
        float ia = axisX ? inv.x : inv.y;
        float il = axisX ? inv.y : inv.x;
        float a0 = (line - WALL_HALF - oa) * ia;
        float a1 = (line + WALL_HALF - oa) * ia;
        float l0 = (along.x - ol) * il;
        float l1 = (along.y - ol) * il;
        float enterA = min(a0, a1);
        float enterL = min(l0, l1);
        float enter = max(enterA, enterL);
        float exit = min(max(a0, a1), max(l0, l1));
        if (enter < exit && enter > 0.0 && enter < best) {
            best = enter;
            // The face or an end: whichever axis the ray entered the box on.
            bool onFace = enterA > enterL;
            normal = (onFace == axisX) ? vec3(-sign(rd.x), 0.0, 0.0) : vec3(0.0, 0.0, -sign(rd.z));
        }
    }
    return best;
}

// Trace the ray. Returns the distance; `id` says what was hit (0 floor,
// 1 ceiling, 2 wall, 3 pillar), `normal` faces the camera.
float trace(vec3 ro, vec3 rd, out int id, out vec3 normal) {
    // The floor or the ceiling, whichever the ray is heading for.
    float planeT = rd.y < 0.0 ? -ro.y / rd.y : (CEILING - ro.y) / rd.y;
    if (abs(rd.y) < 1e-5) planeT = 1e9;
    int planeId = rd.y < 0.0 ? 0 : 1;

    vec2 cell = floor(ro.xz / CELL);
    vec2 step = sign(rd.xz);
    vec2 inv = 1.0 / vec2(rd.x == 0.0 ? 1e-6 : rd.x, rd.z == 0.0 ? 1e-6 : rd.z);
    // Distance to the next grid line on each axis, and per cell after that.
    vec2 next = ((cell + max(step, 0.0)) * CELL - ro.xz) * inv;
    vec2 delta = abs(CELL * inv);

    // A wall's slab reaches WALL_HALF past the boundary; a hit that far
    // beyond the cell's exit is still in this cell's walls.
    float slack = WALL_HALF * max(abs(inv.x), abs(inv.y));
    float t = 0.0;
    for (int i = 0; i < MAX_CELLS; i++) {
        vec3 pn, wn;
        float pt = hitPillars(ro, rd, cell, pn);
        float wt = hitWalls(ro, rd, cell, inv, step, wn);
        float exit = min(next.x, next.y);
        float solid = min(pt, wt);
        if (solid < exit + slack && solid < planeT) {
            id = pt < wt ? 3 : 2;
            normal = pt < wt ? pn : wn;
            return solid;
        }
        if (planeT < exit) {
            id = planeId;
            normal = vec3(0.0, planeId == 0 ? 1.0 : -1.0, 0.0);
            return planeT;
        }
        bool axisX = next.x < next.y;
        if (axisX) {
            cell.x += step.x;
            next.x += delta.x;
        } else {
            cell.y += step.y;
            next.y += delta.y;
        }
        t = exit;
    }
    id = 1;
    normal = vec3(0.0, -1.0, 0.0);
    return t;
}

// --- light and surfaces ---------------------------------------------------

// The hash that places the tubes: below LIGHT_DENSITY there is one, and
// how far below says whether it has gone bad. One hash for both, because
// tubeLevel runs for nine cells a pixel.
float tubeHash(vec2 cell) {
    return cheap21(mod(cell, SUPER) + vec2(32.0, 0.0));
}

// Whether `cell` has a working tube: not in the blackout, and on the hash.
bool hasTube(vec2 cell) {
    return !inBlackout(cell) && tubeHash(cell) <= LIGHT_DENSITY;
}

// Brightness of the tube in `cell` at scene time t: 0 for a cell without
// one, 1 for a good tube, and on the tubes that have gone bad, a fit now
// and then: under a second of irregular stutter, then steady again. Fits
// are rare on purpose. A fifth of the tubes are bad and each has a fit
// about once a minute, so of the handful in view one is stuttering at any
// moment or, more often, none is. Tubes that stutter all the time make the
// whole scene restless, and a watcher is meant to be able to rest here.
float tubeLevel(vec2 cell, float t) {
    if (inBlackout(cell)) return 0.0;
    float h = tubeHash(cell);
    if (h > LIGHT_DENSITY) return 0.0;
    float bad = h / LIGHT_DENSITY;
    if (bad > 0.22) return 1.0;
    vec2 c = mod(cell, SUPER);
    float tt = t + bad * 100.0;  // so the bad tubes' slots are out of step
    float slot = floor(tt / FIT_SLOT);
    float seed = c.x * 7.0 + c.y * 13.0;
    if (hash11(slot * 3.7 + seed) > FIT_CHANCE) return 1.0;
    float start = hash11(slot * 1.3 + seed + 4.0) * (FIT_SLOT - FIT_LENGTH);
    float within = tt - slot * FIT_SLOT;
    float fit = step(start, within) * step(within, start + FIT_LENGTH);
    float drop = step(0.55, hash11(floor(tt * 16.0) + seed));
    return mix(1.0, 0.3, fit * drop);
}

vec2 tubeCentre(vec2 cell) {
    return (cell + 0.5) * CELL;
}

// Light arriving at p with normal n from the tubes in the surrounding cells:
// direct light from the tubes of p's own cell and the eight around it that
// have a clear line to p across the walls, and a share that bounced off
// everything else, which is what keeps the ceiling from going black when
// the tubes hang level with it, and what light the walls' shadows have.
//
// The line of sight is tested against the first wall it would cross, one
// of the four edges of p's own cell, which is exact for the four cells
// beside it; a tube on the diagonal is tested against that crossing only.
// Nothing here loops or diverges: a walk over the boundaries, however
// short, cost a third of the frame, and each tube costs about a
// twentieth, which is why the ring two cells out is not lit at all.
vec3 lighting(vec3 p, vec3 n, float t) {
    vec2 from = p.xz + n.xz * 0.05;  // off its own wall
    vec2 cell = floor(from / CELL);
    // The walls on this cell's edges, -x, +x, -z, +z.
    ivec4 own = ivec4(wallOn(cell - vec2(1.0, 0.0), true), wallOn(cell, true),
                      wallOn(cell - vec2(0.0, 1.0), false), wallOn(cell, false));
    float direct = 0.0;
    float bounced = 0.0;
    for (int dz = -1; dz <= 1; dz++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 c = cell + vec2(float(dx), float(dz));
            float level = tubeLevel(c, t);
            if (level == 0.0) continue;
            vec3 lp = vec3(tubeCentre(c).x, CEILING - 0.05, tubeCentre(c).y);
            vec3 l = lp - p;
            float d2 = dot(l, l);
            bounced += level * 0.5 / (1.0 + d2 * 0.3);
            float lambert = max(dot(n, l * inversesqrt(d2)), 0.0);
            if (lambert == 0.0) continue;
            if (dx != 0 || dz != 0) {
                vec2 d = lp.xz - from;
                vec2 edge = (cell + vec2(dx > 0 ? 1.0 : 0.0, dz > 0 ? 1.0 : 0.0)) * CELL;
                float ux = dx != 0 ? (edge.x - from.x) / d.x : 2.0;
                float uz = dz != 0 ? (edge.y - from.y) / d.y : 2.0;
                bool firstX = ux < uz;
                vec2 q = from + d * min(ux, uz);
                int kind = firstX ? (dx > 0 ? own.y : own.x) : (dz > 0 ? own.w : own.z);
                if (wallCovers(kind, fract((firstX ? q.y : q.x) / CELL))) continue;
            }
            direct += level * lambert * 4.5 / (1.0 + d2 * 0.55);
        }
    }
    return (direct + bounced) * TUBE_COLOR;
}


// Value noise, for the stains on everything.
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(cheap21(i), cheap21(i + vec2(1.0, 0.0)), f.x),
        mix(cheap21(i + vec2(0.0, 1.0)), cheap21(i + vec2(1.0, 1.0)), f.x),
        f.y
    );
}

// Albedo and emission of the surface hit at p.
vec3 surface(vec3 p, int id, vec3 n, float t, out vec3 emission) {
    emission = vec3(0.0);
    if (id == 0) {
        // Carpet: fine speckle, and slow patches where it has been wet.
        float fibre = noise(p.xz * 40.0) * 0.5 + noise(p.xz * 90.0) * 0.5;
        float damp = smoothstep(0.45, 0.75, noise(p.xz * 0.35 + 3.0));
        return CARPET_COLOR * (0.75 + 0.5 * fibre) * (1.0 - 0.45 * damp);
    }
    if (id == 1) {
        // Ceiling tiles on a 0.6 m grid, and the tube panel over the middle
        // of any cell that has one.
        vec2 tile = abs(fract(p.xz / 0.6) - 0.5);
        float seam = smoothstep(0.44, 0.48, max(tile.x, tile.y));
        vec2 cell = floor(p.xz / CELL);
        vec2 local = p.xz - tubeCentre(cell);
        float panel = step(abs(local.x), 0.6) * step(abs(local.y), 0.3);
        float level = hasTube(cell) ? 1.0 : 0.0;
        float lit = tubeLevel(cell, t);
        vec3 albedo = CEILING_COLOR * (0.9 + 0.2 * noise(p.xz * 6.0)) * (1.0 - 0.5 * seam);
        // A dead panel is a dark grey box, a live one is where the light is.
        albedo = mix(albedo, vec3(0.25), panel * (1.0 - level));
        emission = TUBE_COLOR * panel * level * (0.6 + 1.4 * lit);
        return mix(albedo, vec3(0.0), panel * level);
    }
    // Wallpaper on walls and pillars: faint vertical stripes, a darker band
    // near the floor, and blotches where it has been rubbed and stained.
    float u = abs(n.x) > 0.5 ? p.z : p.x;
    float stripe = 0.5 + 0.5 * sin(u * 31.4);
    float grime = noise(vec2(u * 1.7, p.y * 1.3) + 11.0);
    float skirting = 1.0 - 0.35 * smoothstep(0.12, 0.09, p.y);
    float top = 1.0 - 0.15 * smoothstep(CEILING - 0.3, CEILING, p.y);
    return WALL_COLOR * (0.92 + 0.08 * stripe) * (0.8 + 0.35 * grime) * skirting * top;
}

// --- the tape -------------------------------------------------------------

// Scene time, after the deck has dropped a frame: in every DROP_SLOT
// seconds there is a chance the picture freezes for DROP_HOLD.
float droppedFrames(float t) {
    float slot = floor(t / DROP_SLOT);
    float h = hash11(slot * 3.1 + 0.7);
    float start = slot * DROP_SLOT + h * (DROP_SLOT - DROP_HOLD);
    float hold = step(h, DROP_CHANCE) * DROP_HOLD;
    return t - clamp(t - start, 0.0, hold);
}

// The tracking band: a bright, torn stripe that rolls up the picture now
// and then, for BAND_ROLL seconds at the start of a BAND_SLOT that draws
// it. Returns its strength at screen height y (0 at the bottom).
float trackingBand(float y, float t) {
    float slot = floor(t / BAND_SLOT);
    float within = t - slot * BAND_SLOT;
    float h = hash11(slot * 7.3 + 2.1);
    float rolling = step(h, BAND_CHANCE) * step(within, BAND_ROLL);
    float centre = fract(h * 13.0 - within * 0.55);
    float d = abs(y - centre);
    float width = 0.035 + 0.02 * hash11(slot + 9.0);
    return rolling * (1.0 - smoothstep(width * 0.5, width, d));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float t = droppedFrames(iTime);

    // Screen coordinates: y up, height 1, and the frame's aspect. fragCoord
    // grows downward here and in Ghostty alike, so it is flipped once, here.
    // With the pillarbox the picture is the 4:3 middle and the rest is
    // masked at the end, never skipped.
    vec2 res = iResolution.xy;
    float mask = 1.0;
#if PILLARBOX
    vec2 frame = vec2(min(res.x, res.y * 4.0 / 3.0), min(res.y, res.x * 0.75));
    vec2 offset = 0.5 * (res - frame);
    vec2 inFrame = fragCoord - offset;
    mask = step(0.0, inFrame.x) * step(inFrame.x, frame.x) * step(0.0, inFrame.y) * step(inFrame.y, frame.y);
    vec2 uv = (inFrame - 0.5 * frame) / frame.y;
    float screenY = 1.0 - inFrame.y / frame.y;
#else
    vec2 frame = res;
    vec2 inFrame = fragCoord;
    vec2 uv = (fragCoord - 0.5 * res) / res.y;
    float screenY = 1.0 - fragCoord.y / res.y;
#endif
    uv.y = -uv.y;

    // Tape faults that displace whole scan lines are applied here, to the
    // ray, so the picture really shifts rather than a copy of it.
    // The frame number restarts every hour and is folded to [0, 100)
    // before it seeds anything: fed straight in, it reaches the millions
    // overnight, and sin() of its multiples loses enough precision on the
    // GPU to bias the hash, which tints the whole picture.
    float frameNo = floor(mod(iTime, 3600.0) * 60.0);
    vec2 fseed = floor(vec2(hash11(frameNo + 0.31), hash11(frameNo + 0.77)) * 100.0);
    float band = trackingBand(screenY, iTime);
    float bandShift = band * (0.05 + 0.04 * hash11(floor(screenY * 90.0) + fseed.x));
    float headSwitch = 1.0 - smoothstep(0.0, 0.03, screenY);
    float headShift = headSwitch * 0.03 * (fseed.y * 0.01 - 0.5);
    float wobble = 0.0012 * sin(screenY * 37.0 + iTime * 21.0) * (0.5 + 0.5 * sin(iTime * 0.7));
    uv.x += bandShift + headShift + wobble;

    // The lens: barrel distortion, then a wide field of view.
    float r2 = dot(uv, uv);
    uv *= 1.0 + BARREL * r2;

    // --- the camera --------------------------------------------------------
    float u = mod(t, LAP);
    float s = floor(t / LAP) * float(STEPS) + walked(u);
    float moving = pace(u);

    // The steps. Phase 0 of a step is the heel strike; a stride is two
    // steps. The wander is a phase modulation (see the note at BOB), and
    // all of the gait fades out with `moving` as the camera stops.
    float steps = s * PACE + JITTER * fbm1(t * 0.17);
    float stepNo = floor(steps);
    float su = steps - stepNo;
    float strideP = fract(steps * 0.5);
    float stepHz = PACE * walkSpeed();
    float sinceStrike = su / stepHz;

    // The body, on the smoothed path, facing the way it moves, and going
    // slower round a corner.
    vec2 body, going;
    smoothPath(s, body, going);
    float heading = atan(going.x, going.y);
    float gait = moving * length(going);
    // The head turns on the neck ahead of the body, and with the steps:
    // its heading is read at an arc length warped so that d(warped)/ds =
    // 1 + GATE * sin(2 pi step), fastest a quarter step after each heel
    // strike, in the swing, and slowest before the next. The neck's angle
    // is also how far into a turn the body is, for the lean.
    float warped = s - moving * GATE / (6.2831853 * PACE) * cos(6.2831853 * su);
    vec2 unused, facing;
    smoothPath(warped + LEAD, unused, facing);
    float neck = atan(facing.x, facing.y) - heading;
    neck = clamp(atan(sin(neck), cos(neck)), -NECK_MAX, NECK_MAX);
    float turning = clamp(neck / 0.35, -1.0, 1.0);

    // Looking around while stood still: into the dark on the first pause,
    // back over the left shoulder, down the room it came through, on the
    // second.
    float look = 1.6 * lookBump(u, PAUSE1) - 1.8 * lookBump(u, PAUSE2);
    float yaw = heading + neck + look;

    // The bob: the pendulum's arc with its harmonics, and the strike's ring
    // on top, split into what the eyes counter well and what they do not.
    // All of it scales with the body's speed, `gait`.
    float amp = mix(stepSize(stepNo), stepSize(stepNo + 1.0), su) * gait;
    float arch = 1.0 / (1.0 + ARCH2 + ARCH3);
    float bobLow = -BOB * amp * arch * cos(6.2831853 * su);
    float bobHigh = -BOB * amp * arch * (ARCH2 * cos(12.566371 * su) + ARCH3 * cos(18.849556 * su))
        + IMPACT * gait * ring(sinceStrike, IMPACT_TAU);
    // Sideways once a stride, and into the turn; forwards with the surge.
    float sway = SWAY * amp * sin(6.2831853 * strideP) + LEAN * moving * turning;
    float surge = RIPPLE * gait * walkSpeed() * CELL / (6.2831853 * stepHz) * sin(6.2831853 * su);
    float roll = GAIT_ROLL * gait * sin(6.2831853 * strideP);
    float kick = KICK * gait * ring(sinceStrike, KICK_TAU);
    vec3 side = vec3(cos(heading), 0.0, -sin(heading));
    vec3 ahead = vec3(sin(heading), 0.0, cos(heading));

    // The eyes without the bob, NECK ahead of the neck's axis in the
    // direction the head faces, and their target ahead of them, level
    // with them: the walker looks down the room, not at the floor, and the
    // barrel distortion already pulls the floor up into view. The ray
    // starts at the bobbed eye; its direction is what the eyes think they
    // are countering, from `known`.
    vec3 head = vec3(body.x * CELL + CELL * 0.5, EYE, body.y * CELL + CELL * 0.5)
        + NECK * vec3(sin(yaw), 0.0, cos(yaw));
    vec3 shift = side * sway + ahead * surge;
    vec3 ro = head + shift + vec3(0.0, bobLow + bobHigh, 0.0);
    vec3 known = head + shift + vec3(0.0, VOR_STEP * bobLow + VOR_HIGH * bobHigh, 0.0);
    vec3 target = head + vec3(sin(yaw), 0.0, cos(yaw)) * GAZE;
    vec3 forward = normalize(target - known);
    vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
    vec3 up = cross(forward, right);
    vec2 ruv = vec2(uv.x * cos(roll) - uv.y * sin(roll), uv.x * sin(roll) + uv.y * cos(roll));
    ruv.y += FOCAL * kick;
    vec3 rd = normalize(forward * FOCAL + right * ruv.x + up * ruv.y);

    // --- the scene ---------------------------------------------------------
    int id;
    vec3 n;
    float dist = trace(ro, rd, id, n);
    vec3 p = ro + rd * dist;
    vec3 emission;
    vec3 albedo = surface(p, id, n, t, emission);
    vec3 col = albedo * (lighting(p, n, t) + vec3(0.012)) + emission;
    float fog = exp(-dist * 0.075);
    col = mix(FOG_COLOR, col, fog);

    // --- the camera's optics and electronics ------------------------------
    // Everything from here on runs for every pixel: the faults below are
    // derivatives of the scene, and a derivative taken after a skip draws
    // differently on different GPUs.
    //
    // The lens's lateral chromatic aberration: red and blue land either side
    // of green by an amount that grows with the image height, so the middle
    // is clean and the corners fringe.
    vec3 dcol = dFdx(col);
    float fringe = 3.5 * r2;
    col = vec3(col.r + dcol.r * fringe, col.g, col.b - dcol.b * fringe);
    col = max(col, 0.0);

    // The camcorder's white balance is wrong: it warms everything, lifts the
    // blacks, and cannot resolve much contrast.
    col = pow(col, vec3(0.85));
    col = col * vec3(1.05, 0.98, 0.78) + vec3(0.035, 0.03, 0.02);
    col = mix(vec3(dot(col, vec3(0.3, 0.59, 0.11))), col, 0.9);
    col = col * 0.9 + 0.02;

    // --- the tape ----------------------------------------------------------
    // In Y/C, because every fault of the tape is a failure to keep luma and
    // colour apart; see the note at LUMA_SAMPLES. Noise is fixed to the
    // screen, as are the vignette and the black bars: they are the one
    // thing in the picture that does not move, which is part of what makes
    // the walk bearable. There is no flicker in the level: a whole-screen
    // flicker at tens of hertz is a strobe, whatever the tape did.
    const mat3 RGB2YIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
    const mat3 YIQ2RGB = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.619, -0.647, 1.703);
    vec3 yiq = RGB2YIQ * col;
    vec3 dyiq = RGB2YIQ * dFdx(col);
    float Y = yiq.x;
    vec2 C = yiq.yz;
    float line = floor(inFrame.y / frame.y * LINES);
    vec2 lumaCell = floor(inFrame / frame * vec2(LUMA_SAMPLES, LINES));
    vec2 chromaCell = floor(inFrame / frame * vec2(CHROMA_SAMPLES, LINES * 0.5));
    float bandEdge = band * (1.0 - band) * 4.0;

    // Colour was recorded at a fraction of the luma bandwidth, so it lags
    // the edges it belongs to by several pixels to the right.
    C += dyiq.yz * YC_DELAY;
    // The hue of each line drifts with the tape, and tears at the band.
    float phase = PHASE_ERROR * (cheap21(vec2(line, fseed.x)) - 0.5) * 2.0 + bandEdge * 1.2;
    C = mat2(cos(phase), sin(phase), -sin(phase), cos(phase)) * C;
    // Colour noise: wide flat blotches, two lines tall; lost inside the
    // band and worst at its edges.
    vec2 blotch = vec2(cheap21(chromaCell + fseed), cheap21(chromaCell + fseed.yx + 7.0)) * 2.0 - 1.0;
    C *= 1.0 - band * 0.85;
    C += blotch * (CHROMA_NOISE + bandEdge * 0.35);
    // Cross-colour: a horizontal luma slope near the subcarrier's frequency
    // is demodulated as colour, and the subcarrier's phase turns by a
    // quarter cycle a pixel, half a cycle a line, half a cycle a frame.
    float sub = 6.2831853 * inFrame.x * SUBCARRIER + 3.14159265 * (line + frameNo);
    vec2 carrier = vec2(cos(sub), sin(sub));
    C += carrier * clamp(dyiq.x * 0.5, -0.06, 0.06) * CROSS_COLOR;
    // Dot crawl: colour at the subcarrier leaks back into luma, where the
    // colour changes; a flat wall stays clean.
    float crawlEdge = clamp(length(dyiq.yz) * 20.0, 0.0, 1.0);
    Y += dot(C, carrier) * DOT_CRAWL * crawlEdge;

    // Luma noise: fine grain, sparse snow that widens to a streak, the
    // torn bright tracking band, and snow at the head switch, both grey.
    float grain = cheap21(floor(fragCoord / 2.5) + floor(fract(iTime * 7.0) * 100.0));
    float snow = step(0.93, cheap21(lumaCell + fseed + 3.0)) - step(0.93, cheap21(lumaCell + fseed.yx + 5.0));
    Y += (grain - 0.5) * LUMA_GRAIN + snow * (LUMA_SNOW + band * 0.55);
    float bandNoise = cheap21(vec2(floor(screenY * 240.0), fseed.y));
    Y = mix(Y, 0.7 + 0.3 * bandNoise, band * 0.8);
    float headSnow = cheap21(floor(fragCoord) + floor(fract(iTime * 13.0) * 50.0));
    Y = mix(Y, headSnow * 0.6, headSwitch * 0.9);
    C *= 1.0 - headSwitch;
    col = YIQ2RGB * vec3(Y, C);

    // --- the monitor --------------------------------------------------------
    col *= 0.9 + 0.1 * sin(fragCoord.y * 3.14159 * 0.5);
    col *= 1.0 - 0.3 * r2;

    fragColor = vec4(clamp(col, 0.0, 1.0) * mask, 1.0);
}
