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
// wide screen; set PILLARBOX to 0 to fill the screen instead. It is drawn
// as a tape plays it, a field at a time (see FIELD_RATE).

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
// with probability BAND_CHANCE in every BAND_SLOT seconds; the deck's
// servo loses the time base with probability WOBBLE_CHANCE in every
// WOBBLE_SLOT seconds. All of them are rare where nothing is happening:
// the walk should be dull, and a fault is an event. Where something is
// happening they are not rare at all; see STORM_LEAD.
const float FIT_SLOT = 10.0;
const float FIT_CHANCE = 0.15;
const float FIT_LENGTH = 0.7;      // seconds a fit lasts
const float DROP_SLOT = 8.0;
const float DROP_CHANCE = 0.2;
const float DROP_HOLD = 0.25;      // seconds the picture freezes
const float BAND_SLOT = 10.0;
const float BAND_CHANCE = 0.2;
const float BAND_ROLL = 2.0;       // seconds the band takes to roll through
const float WOBBLE_SLOT = 12.0;
const float WOBBLE_CHANCE = 0.25;
const float WOBBLE_LENGTH = 4.0;   // seconds the ripple takes to swell and die
const float WOBBLE = 0.0012;       // of the picture's height the verticals ripple by, at most

// Except around the two things the walker reacts to, where the tape is
// worse. Whether a tape really knows what is on it is not a question found
// footage has ever wanted asked: the picture goes wrong where something is
// wrong, it starts going wrong before the thing rather than after it, and
// that is most of how the form tells you to be afraid. So a disturbance
// comes up over STORM_LEAD seconds before the fright and the stop and
// takes STORM_TRAIL to go, and while it is up the deck drops more frames,
// tears more bands, loses the time base more often and lays down more
// noise. Nothing about it is a new kind of fault: it is the same four,
// asked for more often and louder, so what it looks like is a tape that
// was always going to do this getting to the part where it does.
const float STORM_LEAD = 6.0;      // seconds it is up before
const float STORM_TRAIL = 10.0;    // and takes to die after
const float STORM_DROP = 0.35;     // added to DROP_CHANCE at its peak
const float STORM_BAND = 0.50;     // to BAND_CHANCE
const float STORM_WOBBLE = 0.50;   // and to WOBBLE_CHANCE
const float STORM_GRAIN = 1.00;    // how much more noise there is in Y and in colour
const float STORM_SNOW = 0.12;     // and how much further down the snow's threshold goes

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

// The tape's time. VHS records fields, not frames: the two heads on the
// drum each lay down one track a half turn, 59.94 tracks a second, and a
// track is one field, every other line of the picture. There is no frame
// on the tape. What is on screen at any moment is the lines of the latest
// field over the lines of the one before it, a field older; on a still
// picture the two agree and it is sharp, on a moving one every edge is
// combed, odd lines a field behind even ones, and the picture loses
// resolution as it moves, which is much of what VHS motion looks like.
// Each line's scene is traced from where the camera was at its own
// field's instant (to first order; see Pose), so the comb costs nothing:
// one trace a pixel either way. Everything on the tape, the noise, the
// head switch, the subcarrier's phase, ticks by the field too.
//
// The comb is drawn smaller than it is. A tape's picture is soft, some
// 333 luma samples a line, nine pixels at 4K, and the comb a walk puts on
// a near wall, ten pixels or so, is a wobble in an edge that soft; traced
// once a pixel, the picture here is sharp, and the same comb is teeth.
// There is no blurring it without a second trace, so the older lines are
// drawn COMB of a field back instead of a whole one, which is about what
// the tape's comb reads as.
const float FIELD_RATE = 59.94;    // fields a second: NTSC's 60000 / 1001
const float COMB = 0.5;            // of a field the older lines lag by

// The walk is slow: 30 cells in what is left of a 150 s lap once the two
// pauses and the creep have taken their seconds out is 0.98 m/s, the pace
// of someone who does not know the place, against the 1.3 m/s of a
// commuter - and 0.54 m/s where it creeps, which is barely walking.
const float LAP = 150.0;           // seconds per lap of the walk
const float PAUSE = 10.0;          // seconds of the two pauses the walk is planned round
const float EASE = 2.0;            // seconds to slow into and out of a pause
const float PAUSE1 = 30.0;         // lap seconds at which each pause begins:
const float PAUSE2 = 106.0;        // on the blackout's edge, and on the way back
const int STEPS = 30;              // cells walked per lap
const float PACE = 6.8;            // footsteps per cell: 0.59 m steps, 1.5 Hz

// Everywhere the walk is off its pace, as a start, a length, an ease and a
// depth: 1 stops it, less than 1 slows it, and below zero it is the walk
// going faster instead. There are four things in it.
//
// The two pauses. Either side of the first of them the creep - the walk up
// the edge of the blackout, which is the one stretch of the lap the walker
// can see into the dark from, taken at half pace. The stop that nothing
// explains. And after each of the two things the walker reacts to, a
// while spent walking faster than they were before it: not running, which
// would be a different tape, but the pace of somebody who has decided they
// would rather be somewhere else and is not admitting it. The first of
// them starts inside the creep's own ease, so the walk goes from treading
// to hurrying without passing through its ordinary pace, which is what the
// decision looks like.
//
// The depths add, so no entry may overlap another far enough to take the
// total over 1 or the walk goes backwards. The two creeps are written so
// that each meets the pause exactly across its ease, where the two sum to
// 1 and no more, which is also what lets the walk creep into the stop and
// creep back out of it rather than returning to pace first.
//
// Whatever they cost between them comes back everywhere else: walkSpeed
// divides by what is left of the lap, so a lap is always STEPS cells
// however much of it is spent going slowly, and the hurrying is paid for
// by the ordinary pace being a little under a metre a second rather than
// a little over.
// The third stop is not planned at all. It is three seconds, it stops the
// walk in six tenths rather than two seconds, and nothing in the picture
// says why: the walker has heard something, and the tape does not record
// what. It is on the way back, in the middle of a straight, well clear of
// the pauses - the depths add - and it is not tied to any of the tape's
// faults or the tubes' fits, which are hashed on absolute time and would
// line up with it on one lap in a hundred and never again.
const float CREEP = 0.45;          // how much of the pace the creep takes off
const float CREEP_IN = 6.77;       // seconds of it before the pause: from where
                                   // the blackout's first doorway comes into view
const float CREEP_OUT = 18.89;     // and after it: past the last of the doorways
const float FREEZE_AT = 132.25;    // lap second the walk stops dead
const float FREEZE = 3.0;          // for this long
const float FREEZE_EASE = 0.6;     // and this is all the warning it gives
const float HURRY = -0.30;         // how much faster the walk is afterwards
const float HURRY_ON = 2.5;        // seconds it takes to pick up, after the blackout
const float HURRY_LEN = 22.0;      // and how long it lasts
const float HURRY2_ON = 1.5;       // and after the stop, where it is quicker to
const float HURRY2_LEN = 12.0;     // come on and does not last as long
const vec4 OFF_PACE[7] = vec4[7](
    vec4(PAUSE1, PAUSE, EASE, 1.0),
    vec4(PAUSE2, PAUSE, EASE, 1.0),
    vec4(PAUSE1 - CREEP_IN, CREEP_IN + EASE, EASE, CREEP),
    vec4(PAUSE1 + PAUSE - EASE, CREEP_OUT + EASE, EASE, CREEP),
    vec4(FREEZE_AT, FREEZE, FREEZE_EASE, 1.0),
    vec4(PAUSE1 + PAUSE + CREEP_OUT - EASE, HURRY_LEN, HURRY_ON, HURRY),
    vec4(FREEZE_AT + FREEZE, HURRY2_LEN, HURRY2_ON, HURRY)
);

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
//   degrees a second, and the looks, taken at a pause or on the move,
//   under 60.
//   The body walks the same smoothed path that its heading is read from,
//   so it always moves the way it faces and slows into a corner, on a
//   radius of about 2 m; the gait scales with that speed, so it does not
//   march on the spot through a corner; and the head turns on the neck, NECK metres
//   behind the eyes, so turning the head moves the eyes sideways and the
//   picture parallaxes as well as rotates. Without both, a turn is a tank
//   pivoting on the spot.
// - The eyes leave the heading only for something that is there: a look
//   taken while stood still, or a gaze held on a place the body walks past
//   (GAZE_AT). Both are events, a few seconds long and most of a lap
//   apart, and neither is a wander. A wander is the sickness band again.
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
const float GAZE_HOLD = 1.45;      // radians off the walk's heading the eyes will follow
const float GAZE_KNEE = 6.0;       // how squarely the follow runs out at GAZE_HOLD
const float GAZE_ON = 2.0;         // seconds the eyes take to find something
const float GAZE_OFF = 1.6;        // and to come back off it

// The glance back. Not a gaze: a point behind the walker is past where the
// neck runs out, and its bearing swings through the whole of a turn as the
// body walks away from it, which is a rate no neck has. It is an angle,
// like the looks taken at the pauses, and unlike those it is taken on the
// move - in the middle of the long leg west, clear of both its corners, so
// that the head's yaw is not compounding with the body's. The turn out is
// 54 degrees a second and the turn back 41: the doc's ceiling is 60, and
// the whole point of a glance behind is that it is over before it has
// begun.
const float GLANCE = -1.7;         // radians over the left shoulder
const float GLANCE_AT = 81.68;     // lap second it starts
const float GLANCE_LEN = 6.0;      // seconds it is anything at all
const float GLANCE_ON = 1.8;       // of which this is turning to look
const float GLANCE_OFF = 2.4;      // and this is turning back
const float VOR_STEP = 0.75;       // share of the step's fundamental the eyes counter
const float VOR_HIGH = 0.5;        // share of the harmonics and the strike

// Being frightened, as the camera has it. A viewfinder held to the eye of
// someone who is looking where they are going is the steadiest a camcorder
// gets, and the two things that make it so are the two that go first: the
// eyes stop countering the step, because they are on whatever the fright
// was and not on the far wall, and the arm stops bracing, so the step
// arrives at the camera nearly whole. Nothing here is an angle the walker
// is given; the picture rotates only because the eyes have stopped
// countering it, which is the way it happens.
//
// It is one event a lap, it takes hold in FRIGHT_ON and wears off over
// FRIGHT_OFF, and the wearing off is the slow part: fright arrives all at
// once and leaves by being talked out of. The envelope is nowhere near the
// sickness band even so - it is the depth of a 1.5 Hz carrier, not a
// motion of its own, so what it puts in the spectrum is sidebands beside
// the step and nothing at the rate it swells at.
const float FRIGHT_AT = 44.5;      // lap second it lands: the gaze coming off the dark
const float FRIGHT_ON = 1.2;       // seconds it takes hold
const float FRIGHT_LEN = 22.0;     // seconds it is anything at all
const float FRIGHT_OFF = 13.0;     // of which it spends this many wearing off
const float FRIGHT_VOR = 0.30;     // share of the eyes' stabilisation left at the peak
const float FRIGHT_STEP = 2.2;     // and how much of the step reaches the camera

// And going carefully, which is the other half of it and not the same
// half. The fright is an event; this is a state, and the state is the
// creep: where the walk is being held back it is being held back because
// the walker is treading, so the same `pace` that slows the body takes the
// ring out of the footfall - the strike is most of what a step sounds
// like, and taking it out is what walking quietly looks like from inside
// the walker's head. The rest follows: the arc of the step flattens, the
// whole of it gets smaller, and the phase slows at the strike and hurries
// through the swing, so the foot is a long time going down and no time
// coming up. The cadence is untouched: the length of a pace is the last
// thing anyone controls when they are listening.
//
// This was read from the light once - the tubes over a tent four cells
// wide, so that the one cell in five that is unlit anywhere did not have
// the walker creeping through most of the lap - and where the creep is is
// still where that said to put it. It is not read from the light any more.
// Sixteen tube hashes are 2.3 ms a frame at 4K, a third of the whole
// budget, and what they were buying is a tenth of a grey level: the eyes
// counter the step and the bob is 25 mm, so a careful footfall and a
// careless one differ by millimetres of eye motion. The creep's own
// slowness is the part of it anyone can see, and the creep is free.
const float SNEAK_STRIKE = 0.25;   // share of the heel strike left at full care
const float SNEAK_ARCH = 0.35;     // share of the step's harmonics left
const float SNEAK_BOB = 0.72;      // share of the step's rise and sway left
const float SNEAK_DUTY = 0.55;     // how much longer the foot takes to go down
const float TURN = 1.5;            // cells either side of a corner it is turned over
const float LEAD = 0.25;           // cells the head looks ahead of the body
const float NECK = 0.10;           // metres from the neck's axis forward to the eyes
const float NECK_MAX = 0.73;       // radians the head turns on the neck, at most
const float LEAN = 0.025;          // metres shifted into a turn
const float GATE = 0.5;            // depth of the step's modulation of the yaw rate
const float ARCH2 = 0.20;          // second and third harmonics of the bob
const float ARCH3 = 0.05;
const float IMPACT = 0.004;        // metres the heel strike rings by
const float IMPACT_TAU = 0.07;     // seconds it takes to die away (about 4 fields)
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

// The places the eyes stay on, and when. A look taken while stood still
// (lookBump) turns the head by a set angle; these do not set an angle at
// all. Each is a window of lap time and a point of the floor plan, in the
// cells WAYPOINT is in, and through the window the eyes are on that point:
// the angle follows from where the body has got to, so the thing sits
// still in the frame while the walls slide past it, which is what watching
// something looks like and what turning the head does not.
//
// x, z, the lap second it opens, and how long it is open. The one gaze is
// a room of the blackout, seen through the doorways on the walk up its
// edge: the walker has already stopped and looked into the dark at PAUSE1,
// and starts walking again still watching it, over the shoulder, until the
// neck gives out and the head comes back to where the feet are going.
const vec4 GAZE_AT[1] = vec4[1](
    vec4(6.0, 5.0, 40.0, 6.5)
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

float smoothstepRate(float e0, float e1, float x) {
    float f = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return 6.0 * f * (1.0 - f) / (e1 - e0);
}

// One up over a0..a1 and back down over b0..b1, and how fast it is moving:
// the shape of anything the walker does once and stops doing.
float bump(float u, float a0, float a1, float b0, float b1) {
    return smoothstep(a0, a1, u) - smoothstep(b0, b1, u);
}

float bumpRate(float u, float a0, float a1, float b0, float b1) {
    return smoothstepRate(a0, a1, u) - smoothstepRate(b0, b1, u);
}

// Seconds of walking lost by lap-time u to one entry of OFF_PACE: it
// eases off over e.z, holds at a depth of e.w, and eases back on over e.z
// again. A depth of 1 is a stop, less is the walk going slower for a
// while, and below zero it is seconds gained rather than lost; either way,
// past its end the entry has come to exactly e.w * (e.y - e.z) seconds and
// moves no further.
float slowed(float u, vec4 e) {
    return e.w * (smoothstepIntegral(e.x, e.x + e.z, u)
                - smoothstepIntegral(e.x + e.y - e.z, e.x + e.y, u));
}

float slowedAll(float u) {
    float lost = 0.0;
    for (int i = 0; i < OFF_PACE.length(); i++) lost += slowed(u, OFF_PACE[i]);
    return lost;
}

// How far into the lap's walk the camera is at lap-time u, in cells. The
// speed is whatever gets STEPS cells done in what is left of the lap once
// every entry has taken its seconds out: walked(LAP) is exactly STEPS, so
// the seam between laps is continuous in position and in speed. Lap-time,
// not iTime: `slowed` saturates after its entry, so fed absolute time each
// entry would only ever happen once.
float walkSpeed() {
    float lost = 0.0;
    for (int i = 0; i < OFF_PACE.length(); i++) {
        vec4 e = OFF_PACE[i];
        lost += e.w * (e.y - e.z);
    }
    return float(STEPS) / (LAP - lost);
}

float walked(float u) {
    return walkSpeed() * (u - slowedAll(u));
}

// Fraction of walking pace at lap-time u: 1 on the move, 0 mid-pause, in
// between where the walk is only being held back, and over 1 where it is
// hurrying. Drives the footstep bob, so it fades out as the camera stops
// and grows a little where the walk picks up.
float pace(float u) {
    float held = 0.0;
    for (int i = 0; i < OFF_PACE.length(); i++) {
        vec4 e = OFF_PACE[i];
        held += e.w * bump(u, e.x, e.x + e.z, e.x + e.y - e.z, e.x + e.y);
    }
    return 1.0 - held;
}

// How frightened the walker is at lap-time u, from 0 to 1. See FRIGHT_AT.
float fright(float u) {
    return bump(u, FRIGHT_AT, FRIGHT_AT + FRIGHT_ON,
                FRIGHT_AT + FRIGHT_LEN - FRIGHT_OFF, FRIGHT_AT + FRIGHT_LEN);
}

// How badly the tape is going at lap-time u, from 0 to 1: up either side of
// the fright and of the stop, and nothing anywhere else. See STORM_LEAD.
float stormAt(float u) {
    float about = bump(u, FRIGHT_AT - STORM_LEAD, FRIGHT_AT - STORM_LEAD * 0.35,
                       FRIGHT_AT + STORM_TRAIL * 0.35, FRIGHT_AT + STORM_TRAIL)
                + bump(u, FREEZE_AT - STORM_LEAD, FREEZE_AT - STORM_LEAD * 0.35,
                       FREEZE_AT + STORM_TRAIL * 0.35, FREEZE_AT + STORM_TRAIL);
    return clamp(about, 0.0, 1.0);
}

// The bump of a look taken while stood still: how far the camera has turned
// to look at something before turning back. Both halves are long, so the
// looks peak at about 35 degrees a second.
float lookBump(float u, float start) {
    return bump(u, start + 0.3, start + PAUSE * 0.5, start + PAUSE * 0.55, start + PAUSE - 0.2);
}

float lookBumpRate(float u, float start) {
    return bumpRate(u, start + 0.3, start + PAUSE * 0.5, start + PAUSE * 0.55, start + PAUSE - 0.2);
}

// How far off the heading the eyes are at lap-time u because they are on
// one of GAZE_AT, and how fast that angle is moving. `eye` is the neck's
// axis in metres and `eyeVel` how fast it is moving: the angle to a point
// that does not move changes anyway as the body walks past it, and that
// change is most of what makes a held gaze read. `ahead` is the yaw the
// walk alone would have, since the answer is an offset from it.
//
// A neck runs out, and the run-out has to be soft or the yaw rate steps.
// It is soft only where it has to be: x / (1 + (x / hold)^knee)^(1/knee) is
// the angle itself until the angle is most of GAZE_HOLD, and approaches
// GAZE_HOLD after that. A tanh would do the same job but bends from zero,
// and an eye that is following something 60 degrees round has to be 60
// degrees round, not 50: the thing has to sit still in the frame.
//
// The window's edges bring the head back, and that return is the fastest
// thing in the walk: released from the limit over GAZE_OFF it comes
// forward at some 50 degrees a second, which is a person snapping their
// eyes back to where they are going.
void gazeOffset(float u, vec2 eye, vec2 eyeVel, float ahead, float aheadRate,
                out float off, out float offRate) {
    off = 0.0;
    offRate = 0.0;
    for (int i = 0; i < GAZE_AT.length(); i++) {
        vec4 g = GAZE_AT[i];
        float a0 = g.z;
        float a1 = g.z + GAZE_ON;
        float b0 = g.z + g.w - GAZE_OFF;
        float b1 = g.z + g.w;
        float w = bump(u, a0, a1, b0, b1);
        if (w <= 0.0) continue;
        vec2 d = (g.xy + 0.5) * CELL - eye;
        float rel = atan(d.x, d.y) - ahead;
        rel = atan(sin(rel), cos(rel));
        float relRate = (d.x * eyeVel.y - d.y * eyeVel.x) / dot(d, d) - aheadRate;
        float knee = 1.0 + pow(abs(rel) / GAZE_HOLD, GAZE_KNEE);
        float held = rel * pow(knee, -1.0 / GAZE_KNEE);
        off += w * held;
        offRate += w * pow(knee, -1.0 - 1.0 / GAZE_KNEE) * relRate
                 + bumpRate(u, a0, a1, b0, b1) * held;
    }
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
// and that is how fast the body is going in cells per cell of s. `turn`
// is d(dir)/ds: the tent's slope is constant either side of s, so it is
// the mean direction ahead less the mean behind, over TURN squared.
void smoothPath(float s, out vec2 pos, out vec2 dir, out vec2 turn) {
    pos = vec2(0.0);
    dir = vec2(0.0);
    turn = vec2(0.0);
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
                turn += d * i1 * (part == 0 ? -1.0 : 1.0);
            }
        }
        w = wn;
    }
    pos /= TURN;
    dir /= TURN;
    turn /= TURN * TURN;
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

float ringRate(float tt, float tau) {
    float w = 6.2831853 * IMPACT_HZ;
    return exp(-tt / tau) * (sin(w * tt) / tau - w * cos(w * tt));
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
// The bounced share is set so the picture averages about nine tenths as
// bright as it was before the shadows and the ring of tubes two cells
// out went; the blackout, which no tube reaches, stays as dark.
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
            bounced += level * 0.75 / (1.0 + d2 * 0.3);
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
float droppedFrames(float t, float storm) {
    float slot = floor(t / DROP_SLOT);
    float h = hash11(slot * 3.1 + 0.7);
    float start = slot * DROP_SLOT + h * (DROP_SLOT - DROP_HOLD);
    float hold = step(h, DROP_CHANCE + storm * STORM_DROP) * DROP_HOLD;
    return t - clamp(t - start, 0.0, hold);
}

// The tracking band: a bright, torn stripe that rolls up the picture now
// and then, for BAND_ROLL seconds at the start of a BAND_SLOT that draws
// it. Returns its strength at screen height y (0 at the bottom).
float trackingBand(float y, float t, float storm) {
    float slot = floor(t / BAND_SLOT);
    float within = t - slot * BAND_SLOT;
    float h = hash11(slot * 7.3 + 2.1);
    float rolling = step(h, BAND_CHANCE + storm * STORM_BAND) * step(within, BAND_ROLL);
    float centre = fract(h * 13.0 - within * 0.55);
    float d = abs(y - centre);
    float width = 0.035 + 0.02 * hash11(slot + 9.0);
    return rolling * (1.0 - smoothstep(width * 0.5, width, d));
}

// Time-base error: the tape's tension wanders, each line starts a little
// early or late, and the picture's verticals ripple. The deck's servo
// holds it most of the time and loses it now and then, for WOBBLE_LENGTH
// seconds somewhere in a WOBBLE_SLOT that draws it, the ripple swelling
// and dying away. Returns its strength at time t.
float timeBaseError(float t, float storm) {
    float slot = floor(t / WOBBLE_SLOT);
    float h = hash11(slot * 5.7 + 3.3);
    float start = slot * WOBBLE_SLOT + hash11(slot * 2.9 + 1.7) * (WOBBLE_SLOT - WOBBLE_LENGTH);
    float since = t - start;
    float on = step(h, WOBBLE_CHANCE + storm * STORM_WOBBLE) * step(0.0, since) * step(since, WOBBLE_LENGTH);
    return on * sin(3.14159265 * clamp(since / WOBBLE_LENGTH, 0.0, 1.0));
}

// The camera at scene time t: the eye, the frame it looks along, the roll
// and the pitch kick its rays get, and how fast each of those is changing.
// All of it is a function of t alone, and t of the uniforms, and as long
// as it is worked out once from those the compiler lifts it out of the
// per-pixel work: measured at 4K, calling it with a time that differed by
// the pixel's line cost a millisecond a frame, and calling it twice, once
// for each field, cost nearly two, whichever way a pixel chose between
// them. So it is called once, and the older field's lines move the eye
// back along the velocity and turn the ray back by the yaw rate, which is
// exact to first order over the eightieth of a second it has to cover.
//
// The rates leave out what is too small to see across a field: the
// gait's slow wander and the random step sizes, the lean into a turn,
// the eyes' pitch against the bob, and the turning of `side` and `ahead`
// under the sway.
struct Pose {
    vec3 ro;
    vec3 forward;
    vec3 right;
    vec3 up;
    float roll;
    float kick;
    vec3 vel;         // metres a second the eye moves
    float yawRate;    // radians a second the ray turns about the vertical
    float rollRate;
    float kickRate;
};

Pose cameraPose(float t) {
    float u = mod(t, LAP);
    float s = floor(t / LAP) * float(STEPS) + walked(u);
    float moving = pace(u);
    float sRate = walkSpeed() * moving;  // cells of s a second

    // The steps. Phase 0 of a step is the heel strike; a stride is two
    // steps. The wander is a phase modulation (see the note at BOB), and
    // all of the gait fades out with `moving` as the camera stops.
    float steps = s * PACE + JITTER * fbm1(t * 0.17);
    float stepNo = floor(steps);
    float su = steps - stepNo;
    float strideP = fract(steps * 0.5);
    float stepHz = PACE * walkSpeed();
    float stepRate = PACE * sRate;       // steps a second, now
    float sinceStrike = su / stepHz;

    // The body, on the smoothed path, facing the way it moves, and going
    // slower round a corner.
    vec2 body, going, bending;
    smoothPath(s, body, going, bending);
    float heading = atan(going.x, going.y);
    float headingRate = (going.y * bending.x - going.x * bending.y) / dot(going, going) * sRate;
    float gait = moving * length(going);
    // The head turns on the neck ahead of the body, and with the steps:
    // its heading is read at an arc length warped so that d(warped)/ds =
    // 1 + GATE * sin(2 pi step), fastest a quarter step after each heel
    // strike, in the swing, and slowest before the next. The neck's angle
    // is also how far into a turn the body is, for the lean.
    float warped = s - moving * GATE / (6.2831853 * PACE) * cos(6.2831853 * su);
    float warpedRate = sRate * (1.0 + moving * GATE * sin(6.2831853 * su));
    vec2 unused, facing, facingBend;
    smoothPath(warped + LEAD, unused, facing, facingBend);
    float neck = atan(facing.x, facing.y) - heading;
    neck = atan(sin(neck), cos(neck));
    float neckRate = (facing.y * facingBend.x - facing.x * facingBend.y) / dot(facing, facing) * warpedRate
        - headingRate;
    neckRate *= step(abs(neck), NECK_MAX);  // held still at the stop
    neck = clamp(neck, -NECK_MAX, NECK_MAX);
    float turning = clamp(neck / 0.35, -1.0, 1.0);

    // Looking around while stood still: into the dark on the first pause,
    // back over the left shoulder, down the room it came through, on the
    // second.
    float look = 1.6 * lookBump(u, PAUSE1) - 1.8 * lookBump(u, PAUSE2);
    float lookRate = 1.6 * lookBumpRate(u, PAUSE1) - 1.8 * lookBumpRate(u, PAUSE2);
    // And the one look taken while still walking: see GLANCE.
    float g0 = GLANCE_AT;
    float g1 = GLANCE_AT + GLANCE_ON;
    float g2 = GLANCE_AT + GLANCE_LEN - GLANCE_OFF;
    float g3 = GLANCE_AT + GLANCE_LEN;
    look += GLANCE * bump(u, g0, g1, g2, g3);
    lookRate += GLANCE * bumpRate(u, g0, g1, g2, g3);
    // And looking at something while walking past it, which is an angle
    // that has to be worked out rather than set: see GAZE_AT.
    float gazeOff, gazeRate;
    gazeOffset(u, (body + 0.5) * CELL, going * CELL * sRate, heading + neck,
               headingRate + neckRate, gazeOff, gazeRate);
    look += gazeOff;
    lookRate += gazeRate;
    float yaw = heading + neck + look;
    float yawRate = headingRate + neckRate + lookRate;

    // The bob: the pendulum's arc with its harmonics, and the strike's ring
    // on top, split into what the eyes counter well and what they do not.
    // All of it scales with the body's speed, `gait`.
    // A frightened walker brings the step to the camera whole (`braced`)
    // and stops countering it with the eyes (`vor`); see FRIGHT_AT. A
    // careful one puts the foot down instead of dropping it: `quietly` is
    // how far into the creep the walk is, `quiet` what is left of the heel
    // strike, `arch2`/`arch3` the flattened arc, and `duty` how much of the
    // step's phase is spent going down rather than coming up. A stop is
    // past the creep's depth and reads as fully careful, which costs
    // nothing: `moving` has taken the gait to zero by then. See SNEAK_STRIKE.
    float fear = fright(u);
    float braced = mix(1.0, FRIGHT_STEP, fear);
    float vor = mix(1.0, FRIGHT_VOR, fear);
    float quietly = clamp((1.0 - moving) / CREEP, 0.0, 1.0);
    float quiet = mix(1.0, SNEAK_STRIKE, quietly);
    float arch2 = ARCH2 * mix(1.0, SNEAK_ARCH, quietly);
    float arch3 = ARCH3 * mix(1.0, SNEAK_ARCH, quietly);
    float duty = SNEAK_DUTY * quietly * moving;
    // The step's phase, slow at the strike and quick through the swing, and
    // how fast that phase is running. Substituting both for `su` and
    // `stepRate` leaves the bob's rate exact.
    float sw = su - duty / 6.2831853 * sin(6.2831853 * su);
    float swRate = stepRate * (1.0 - duty * cos(6.2831853 * su));
    float amp = mix(stepSize(stepNo), stepSize(stepNo + 1.0), su) * gait * braced
        * mix(1.0, SNEAK_BOB, quietly);
    float arch = 1.0 / (1.0 + arch2 + arch3);
    float strike = IMPACT * gait * braced * quiet;
    float bobLow = -BOB * amp * arch * cos(6.2831853 * sw);
    float bobHigh = -BOB * amp * arch * (arch2 * cos(12.566371 * sw) + arch3 * cos(18.849556 * sw))
        + strike * ring(sinceStrike, IMPACT_TAU);
    float bobRate = BOB * amp * arch * swRate * (6.2831853 * sin(6.2831853 * sw)
        + arch2 * 12.566371 * sin(12.566371 * sw) + arch3 * 18.849556 * sin(18.849556 * sw))
        + strike * ringRate(sinceStrike, IMPACT_TAU) * moving;
    // Sideways once a stride, and into the turn; forwards with the surge.
    float sway = SWAY * amp * sin(6.2831853 * strideP) + LEAN * moving * turning;
    float swayRate = SWAY * amp * cos(6.2831853 * strideP) * 3.14159265 * stepRate;
    float surge = RIPPLE * gait * walkSpeed() * CELL / (6.2831853 * stepHz) * sin(6.2831853 * su);
    float surgeRate = RIPPLE * gait * walkSpeed() * CELL * cos(6.2831853 * su) * moving;
    float roll = GAIT_ROLL * gait * sin(6.2831853 * strideP);
    float rollRate = GAIT_ROLL * gait * cos(6.2831853 * strideP) * 3.14159265 * stepRate;
    float kick = KICK * gait * braced * quiet * ring(sinceStrike, KICK_TAU);
    float kickRate = KICK * gait * braced * quiet * ringRate(sinceStrike, KICK_TAU) * moving;
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
    vec3 vel = vec3(going.x, 0.0, going.y) * CELL * sRate
        + NECK * yawRate * vec3(cos(yaw), 0.0, -sin(yaw))
        + side * swayRate + ahead * surgeRate + vec3(0.0, bobRate, 0.0);
    vec3 known = head + shift + vec3(0.0, vor * (VOR_STEP * bobLow + VOR_HIGH * bobHigh), 0.0);
    vec3 target = head + vec3(sin(yaw), 0.0, cos(yaw)) * GAZE;
    vec3 forward = normalize(target - known);
    vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
    vec3 up = cross(forward, right);
    return Pose(ro, forward, right, up, roll, kick, vel, yawRate, rollRate, kickRate);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
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

    // The field being written, and the field each line was last written
    // in (see the note at FIELD_RATE): the lines of the other parity are a
    // field older, and the scene on them is traced a field earlier. The
    // count restarts every hour, which is a whole number of fields and of
    // four-field colour cycles, so nothing below notices the restart; and
    // it is folded to [0, 100) before it seeds anything: fed straight in,
    // it reaches the millions overnight, and sin() of its multiples loses
    // enough precision on the GPU to bias the hash, which tints the whole
    // picture.
    float fields = mod(iTime, 3600.0) * FIELD_RATE;
    float fieldNo = floor(fields);
    float line = floor(inFrame.y / frame.y * LINES);
    float stale = abs(mod(line, 2.0) - mod(fieldNo, 2.0));  // 1 on the older field's lines
    float lineField = fieldNo - stale;
    float now = iTime - (fields - fieldNo) / FIELD_RATE;     // this field's instant
    // How badly the tape is going just now, from where the walk has got to:
    // read before the dropped frame, since the drop is one of the things it
    // decides. See STORM_LEAD.
    float storm = stormAt(mod(now, LAP));
    float tNow = droppedFrames(now, storm);  // a dropped frame holds both fields
    vec2 fseed = floor(vec2(hash11(fieldNo + 0.31), hash11(fieldNo + 0.77)) * 100.0);

    // Tape faults that displace whole scan lines are applied here, to the
    // ray, so the picture really shifts rather than a copy of it.
    float band = trackingBand(screenY, now, storm);
    float bandShift = band * (0.05 + 0.04 * hash11(floor(screenY * 90.0) + fseed.x));
    float headSwitch = 1.0 - smoothstep(0.0, 0.03, screenY);
    float headShift = headSwitch * 0.03 * (fseed.y * 0.01 - 0.5);
    float wobble = WOBBLE * sin(screenY * 37.0 + now * 21.0) * timeBaseError(now, storm);
    uv.x += bandShift + headShift + wobble;

    // The lens: barrel distortion, then a wide field of view.
    float r2 = dot(uv, uv);
    uv *= 1.0 + BARREL * r2;

    // --- the camera --------------------------------------------------------
    // Once, at the newer field's time; the older field's lines are moved
    // back along its rates (see the note at Pose).
    Pose cam = cameraPose(tNow);
    float back = -COMB * stale / FIELD_RATE;  // seconds this line is behind
    vec3 ro = cam.ro + cam.vel * back;
    vec2 ruv = vec2(uv.x * cos(cam.roll) - uv.y * sin(cam.roll), uv.x * sin(cam.roll) + uv.y * cos(cam.roll));
    ruv += cam.rollRate * back * vec2(-ruv.y, ruv.x);
    ruv.y += FOCAL * (cam.kick + cam.kickRate * back);
    vec3 rd = normalize(cam.forward * FOCAL + cam.right * ruv.x + cam.up * ruv.y);
    // Turned back about the vertical, to first order: the angle is under a
    // hundredth of a radian, and the length it adds is nothing the trace
    // notices.
    rd += cam.yawRate * back * vec3(rd.z, 0.0, -rd.x);

    // --- the scene ---------------------------------------------------------
    int id;
    vec3 n;
    float dist = trace(ro, rd, id, n);
    vec3 p = ro + rd * dist;
    vec3 emission;
    // The tubes' stutter is read at the newer field on every line: a 16 Hz
    // flicker a sixtieth of a second off is nothing anyone sees, and it
    // keeps the time out of the per-pixel work.
    vec3 albedo = surface(p, id, n, tNow, emission);
    vec3 col = albedo * (lighting(p, n, tNow) + vec3(0.012)) + emission;
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
    C += blotch * (CHROMA_NOISE * (1.0 + storm * STORM_GRAIN) + bandEdge * 0.35);
    // Cross-colour: a horizontal luma slope near the subcarrier's frequency
    // is demodulated as colour. The subcarrier turns a quarter cycle a
    // pixel here and, as NTSC's does, a quarter cycle back a line of the
    // picture and half a cycle a frame, on each line as of the field that
    // last wrote it: the pattern comes round every fourth field, and moved
    // a field at a time, the dots crawl.
    float sub = 6.2831853 * inFrame.x * SUBCARRIER - 1.5707963 * line + 3.14159265 * floor(mod(lineField, 4.0) * 0.5);
    vec2 carrier = vec2(cos(sub), sin(sub));
    C += carrier * clamp(dyiq.x * 0.5, -0.06, 0.06) * CROSS_COLOR;
    // Dot crawl: colour at the subcarrier leaks back into luma, where the
    // colour changes; a flat wall stays clean.
    float crawlEdge = clamp(length(dyiq.yz) * 20.0, 0.0, 1.0);
    Y += dot(C, carrier) * DOT_CRAWL * crawlEdge;

    // Luma noise: fine grain, sparse snow that widens to a streak, the
    // torn bright tracking band, and snow at the head switch, both grey,
    // all seeded by the field.
    float grain = cheap21(floor(fragCoord / 2.5) + fseed);
    float snowGate = 0.93 - storm * STORM_SNOW;
    float snow = step(snowGate, cheap21(lumaCell + fseed + 3.0))
        - step(snowGate, cheap21(lumaCell + fseed.yx + 5.0));
    Y += (grain - 0.5) * LUMA_GRAIN * (1.0 + storm * STORM_GRAIN)
        + snow * (LUMA_SNOW * (1.0 + storm * STORM_GRAIN) + band * 0.55);
    float bandNoise = cheap21(vec2(floor(screenY * 240.0), fseed.y));
    Y = mix(Y, 0.7 + 0.3 * bandNoise, band * 0.8);
    float headSnow = cheap21(floor(fragCoord) + fseed.yx);
    Y = mix(Y, headSnow * 0.6, headSwitch * 0.9);
    C *= 1.0 - headSwitch;
    col = YIQ2RGB * vec3(Y, C);

    // --- the monitor --------------------------------------------------------
    col *= 0.9 + 0.1 * sin(fragCoord.y * 3.14159 * 0.5);
    col *= 1.0 - 0.3 * r2;

    fragColor = vec4(clamp(col, 0.0, 1.0) * mask, 1.0);
}
