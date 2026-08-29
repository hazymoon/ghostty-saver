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
const float WALL_DENSITY = 0.42;   // fraction of edges that carry a wall
const float LIGHT_DENSITY = 0.72;  // fraction of cells with a working tube
const int MAX_CELLS = 40;          // DDA steps before a ray gives up in fog

const float LAP = 120.0;           // seconds per lap of the walk
const float PAUSE = 6.0;           // seconds the camera stands still, twice a lap
const float EASE = 1.5;            // seconds to slow into and out of a pause
const float PAUSE1 = 21.0;         // lap seconds at which each pause begins
const float PAUSE2 = 78.0;
const int STEPS = 36;              // cells walked per lap

const float FOCAL = 0.85;          // 1 / tan(half the vertical field of view)
const float BARREL = 0.13;         // lens distortion, the wide camcorder look

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
const vec2 WAYPOINT[37] = vec2[37](
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(2.0, 1.0), vec2(3.0, 1.0), vec2(3.0, 2.0),
    vec2(4.0, 2.0), vec2(4.0, 3.0), vec2(4.0, 4.0), vec2(4.0, 5.0), vec2(3.0, 5.0),
    vec2(2.0, 5.0), vec2(2.0, 4.0), vec2(1.0, 4.0), vec2(0.0, 4.0), vec2(0.0, 5.0),
    vec2(0.0, 6.0), vec2(1.0, 6.0), vec2(2.0, 6.0), vec2(3.0, 6.0), vec2(3.0, 7.0),
    vec2(4.0, 7.0), vec2(5.0, 7.0), vec2(6.0, 7.0), vec2(6.0, 6.0), vec2(7.0, 6.0),
    vec2(7.0, 7.0), vec2(7.0, 8.0), vec2(6.0, 8.0), vec2(5.0, 8.0), vec2(5.0, 9.0),
    vec2(4.0, 9.0), vec2(4.0, 10.0), vec2(3.0, 10.0), vec2(3.0, 9.0), vec2(2.0, 9.0),
    vec2(2.0, 8.0), vec2(1.0, 8.0)
);
const int OPEN_SIDES[64] = int[64](
     0,  3,  6,  0,  0,  3,  5, 12,
     0,  9, 13,  6,  3, 12,  0,  0,
     0,  0,  0,  9, 14,  0,  0,  0,
     0,  0,  0,  0, 11,  4,  0,  0,
     3,  5,  6,  0, 11,  4,  0,  0,
    10,  0,  9,  5, 13,  4,  0,  0,
     9,  5,  5,  6,  0,  0,  3,  6,
     0,  0,  0,  9,  5,  5, 12, 10
);

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
float walked(float u) {
    float speed = float(STEPS) / (LAP - 2.0 * (PAUSE - EASE));
    return speed * (u - stoodStill(u, PAUSE1) - stoodStill(u, PAUSE2));
}

// Fraction of walking pace at lap-time u: 1 on the move, 0 mid-pause. Drives
// the footstep bob so it fades out as the camera stops.
float pace(float u) {
    float p1 = smoothstep(PAUSE1, PAUSE1 + EASE, u) - smoothstep(PAUSE1 + PAUSE - EASE, PAUSE1 + PAUSE, u);
    float p2 = smoothstep(PAUSE2, PAUSE2 + EASE, u) - smoothstep(PAUSE2 + PAUSE - EASE, PAUSE2 + PAUSE, u);
    return 1.0 - p1 - p2;
}

// A bump that rises over the first part of a pause and falls over the last:
// how far the camera has turned to look at something before turning back.
float lookBump(float u, float start) {
    return smoothstep(start + 0.3, start + PAUSE * 0.45, u)
         - smoothstep(start + PAUSE * 0.6, start + PAUSE - 0.2, u);
}

// Position on the polyline at arc length s (cells), in cells. Laps beyond
// the first move the whole tile north.
vec2 onPath(float s) {
    float lap = floor(s / float(STEPS));
    float local = s - lap * float(STEPS);
    int k = int(floor(local));
    float f = local - float(k);
    vec2 a = WAYPOINT[k];
    vec2 b = WAYPOINT[k + 1];
    return mix(a, b, f) + vec2(0.0, lap * SUPER);
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
// as a grid of corridors.
int wallOn(vec2 cell, bool axisX) {
    if (sideOpen(cell, axisX ? 1 : 2)) return 0;
    vec2 c = mod(cell, SUPER);
    vec2 key = c + (axisX ? vec2(0.37, 0.61) : vec2(0.83, 0.19));
    float h = hash21(key);
    if (h > WALL_DENSITY) return 0;
    float kind = hash21(key + 5.0);
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

    float t = 0.0;
    for (int i = 0; i < MAX_CELLS; i++) {
        vec3 pn;
        float pt = hitPillars(ro, rd, cell, pn);
        float exit = min(next.x, next.y);
        if (pt < exit && pt < planeT) {
            id = 3;
            normal = pn;
            return pt;
        }
        if (planeT < exit) {
            id = planeId;
            normal = vec3(0.0, planeId == 0 ? 1.0 : -1.0, 0.0);
            return planeT;
        }
        // Crossing a boundary: is there a wall on it, here?
        bool axisX = next.x < next.y;
        vec3 p = ro + rd * exit;
        int kind;
        float along;
        if (axisX) {
            vec2 wallCell = step.x > 0.0 ? cell : cell - vec2(1.0, 0.0);
            kind = wallOn(wallCell, true);
            along = fract(p.z / CELL);
        } else {
            vec2 wallCell = step.y > 0.0 ? cell : cell - vec2(0.0, 1.0);
            kind = wallOn(wallCell, false);
            along = fract(p.x / CELL);
        }
        if (wallCovers(kind, along)) {
            id = 2;
            normal = axisX ? vec3(-step.x, 0.0, 0.0) : vec3(0.0, 0.0, -step.y);
            return exit;
        }
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

// Brightness of the tube in `cell` at scene time t: 0 for a cell without one
// or in the blackout, and a nervous flicker on the cells that have gone bad.
float tubeLevel(vec2 cell, float t) {
    if (inBlackout(cell)) return 0.0;
    vec2 c = mod(cell, SUPER);
    float h = hash21(c + vec2(0.11, 0.73));
    if (h > LIGHT_DENSITY) return 0.0;
    float bad = hash21(c + vec2(0.57, 0.29));
    float level = 1.0;
    if (bad < 0.22) {
        // A tube on its way out: mostly on, with drops to a dim buzz.
        float tick = floor(t * 19.0 + bad * 100.0);
        float drop = step(0.72, hash11(tick + c.x * 7.0 + c.y * 13.0));
        level = mix(1.0, 0.25, drop);
    }
    return level;
}

vec2 tubeCentre(vec2 cell) {
    return (cell + 0.5) * CELL;
}

// Light arriving at p with normal n from the tubes in the surrounding cells:
// direct light, and a share that bounced off everything else, which is what
// keeps the ceiling from going black when the tubes hang level with it.
vec3 lighting(vec3 p, vec3 n, float t) {
    vec2 cell = floor(p.xz / CELL);
    float direct = 0.0;
    float bounced = 0.0;
    for (int dz = -2; dz <= 2; dz++) {
        for (int dx = -2; dx <= 2; dx++) {
            vec2 c = cell + vec2(float(dx), float(dz));
            float level = tubeLevel(c, t);
            if (level == 0.0) continue;
            vec3 lp = vec3(tubeCentre(c).x, CEILING - 0.05, tubeCentre(c).y);
            vec3 l = lp - p;
            float d2 = dot(l, l);
            float lambert = max(dot(n, l * inversesqrt(d2)), 0.0);
            direct += level * lambert * 4.5 / (1.0 + d2 * 0.55);
            bounced += level * 0.5 / (1.0 + d2 * 0.3);
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
        mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
        mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x),
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
        float level = tubeLevel(cell, 0.0) > 0.0 ? 1.0 : 0.0;
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

// Scene time, after the deck has dropped a frame: every couple of seconds
// there is a chance the picture freezes for a quarter second.
float droppedFrames(float t) {
    float slot = floor(t / 2.0);
    float h = hash11(slot * 3.1 + 0.7);
    float start = slot * 2.0 + h * 1.6;
    float hold = step(h, 0.22) * 0.25;
    return t - clamp(t - start, 0.0, hold);
}

// The tracking band: a bright, torn stripe that rolls up the picture now
// and then. Returns its strength at screen height y (0 at the bottom).
float trackingBand(float y, float t) {
    float slot = floor(t * 0.5);
    float h = hash11(slot * 7.3 + 2.1);
    float rolling = step(h, 0.16);
    float centre = fract(h * 13.0 - (t - slot * 2.0) * 0.55);
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
    vec2 uv = (fragCoord - 0.5 * res) / res.y;
    float screenY = 1.0 - fragCoord.y / res.y;
#endif
    uv.y = -uv.y;

    // Tape faults that displace whole scan lines are applied here, to the
    // ray, so the picture really shifts rather than a copy of it.
    float band = trackingBand(screenY, iTime);
    float bandShift = band * (0.05 + 0.04 * hash11(floor(screenY * 90.0) + floor(iTime * 30.0)));
    float headSwitch = 1.0 - smoothstep(0.0, 0.03, screenY);
    float headShift = headSwitch * 0.03 * (hash11(floor(iTime * 60.0)) - 0.5);
    float wobble = 0.0012 * sin(screenY * 37.0 + iTime * 21.0) * (0.5 + 0.5 * sin(iTime * 0.7));
    uv.x += bandShift + headShift + wobble;

    // The lens: barrel distortion, then a wide field of view.
    float r2 = dot(uv, uv);
    uv *= 1.0 + BARREL * r2;

    // --- the camera --------------------------------------------------------
    float u = mod(t, LAP);
    float s = floor(t / LAP) * float(STEPS) + walked(u);
    vec2 here = onPath(s);
    // Rounded corners: the average of a point just behind and just ahead.
    vec2 pos2 = 0.5 * (onPath(s - 0.25) + onPath(s + 0.25));
    vec2 ahead = onPath(s + 0.6) - onPath(s - 0.1);
    float heading = atan(ahead.x, ahead.y);

    // Looking around while stood still: into the dark on the first pause,
    // back over the shoulder on the second.
    float look = 1.6 * lookBump(u, PAUSE1) + 2.7 * lookBump(u, PAUSE2);
    // Hand-held: slow drift on every axis and a footstep bob that fades out
    // when the camera stops.
    float moving = pace(u);
    float yaw = heading + look
        + 0.05 * sin(t * 0.9) + 0.03 * sin(t * 2.3 + 1.0);
    // Level, on average: the walker looks down the room, not at the floor,
    // and the barrel distortion already pulls the floor up into view.
    float pitch = 0.03 * sin(t * 0.7 + 2.0) + 0.02 * sin(t * 1.9)
        + 0.012 * moving * sin(s * 2.0 * 6.2831853 * 2.8);
    float roll = 0.02 * sin(t * 0.5 + 1.0) + 0.012 * moving * sin(s * 6.2831853 * 2.8);
    float bob = 0.035 * moving * sin(s * 6.2831853 * 2.8 * 2.0);
    vec2 side = vec2(cos(heading), -sin(heading));
    vec2 sway = side * (0.12 * sin(t * 0.43) + 0.06 * moving * sin(s * 6.2831853 * 2.8));

    vec3 ro = vec3(pos2.x * CELL + CELL * 0.5 + sway.x, EYE + bob, pos2.y * CELL + CELL * 0.5 + sway.y);
    vec2 ruv = vec2(uv.x * cos(roll) - uv.y * sin(roll), uv.x * sin(roll) + uv.y * cos(roll));
    ruv.y += pitch;
    vec3 forward = vec3(sin(yaw), 0.0, cos(yaw));
    vec3 right = vec3(cos(yaw), 0.0, -sin(yaw));
    vec3 rd = normalize(forward * FOCAL + right * ruv.x + vec3(0.0, ruv.y, 0.0));

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

    // --- the tape ----------------------------------------------------------
    // Chroma bleed and fringing from the derivative of the scene: the red
    // and blue records land a few pixels to either side of the green one.
    // Every pixel reaches this line.
    vec3 dcol = dFdx(col);
    col = vec3(col.r + dcol.r * 2.5, col.g, col.b - dcol.b * 2.5);
    col = max(col, 0.0);

    // The camcorder's white balance is wrong: it warms everything, lifts the
    // blacks, and cannot resolve much contrast.
    col = pow(col, vec3(0.85));
    col = col * vec3(1.05, 0.98, 0.78) + vec3(0.035, 0.03, 0.02);
    col = mix(vec3(dot(col, vec3(0.3, 0.59, 0.11))), col, 0.9);
    col = col * 0.9 + 0.02;

    // Tape noise: grain, the torn bright tracking band, snow at the head
    // switch, scan lines, a flicker in the level, and the vignette.
    float grain = hash21(floor(fragCoord / 1.5) + fract(iTime * 7.0) * 100.0);
    col += (grain - 0.5) * 0.09;
    float bandNoise = hash21(vec2(floor(screenY * 240.0), floor(iTime * 30.0)));
    col = mix(col, vec3(0.7 + 0.3 * bandNoise), band * 0.8);
    float snow = hash21(fragCoord + fract(iTime * 13.0) * 50.0);
    col = mix(col, vec3(snow * 0.6), headSwitch * 0.9);
    col *= 0.9 + 0.1 * sin(fragCoord.y * 3.14159 * 0.5);
    col *= 0.97 + 0.06 * (hash11(floor(iTime * 24.0)) - 0.5);
    col *= 1.0 - 0.4 * r2;

    fragColor = vec4(clamp(col, 0.0, 1.0) * mask, 1.0);
}
