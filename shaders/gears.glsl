// A gear train that is actually meshing, drawn as an engraving: seven wheels
// whose teeth sit in each other's gaps, with one escapement ticking among them.
//
// Stateless by construction. The driver's angle is iTime * DRIVE and every
// other wheel's angle is derived from its driver's, so --at reproduces any
// moment and nothing is stepped forward.
//
// What makes it a mechanism rather than a picture of gears is that nothing
// about the mesh is tuned by eye. All wheels share one module, so a wheel's
// pitch radius is MODULE * teeth / 2 and two meshing centres are exactly the
// sum of their pitch radii apart. A driven wheel turns the other way at the
// driver's speed times the tooth ratio. And its phase is derived: write
// f_i(t) = (alpha - theta_i(t)) * N_i / 2pi for the tooth phase of wheel i
// along the line of centres at angle alpha, and f_j(t) for the partner along
// alpha + pi. Because omega_j = -omega_i * N_i / N_j, f_i + f_j is constant
// in time, so meshing - a tooth of i on the line whenever a gap of j is, that
// is f_i integer when f_j is a half - holds at every moment once it holds at
// t = 0. phaseFor() solves f_j(0) = 1/2 - f_i(0) for the driven wheel's phase.
//
// The escapement is wheel F: its angle advances one tooth per tick, with a
// short overshoot as it lands, and G is driven off it so the pair step
// together while the rest of the train turns steadily.
//
// Per pixel the loop is over seven wheels, each bounded first by the distance
// to its centre less its outer radius, so only the pixels on or near a wheel
// pay for the tooth profile and the hatching. The shading is
// shaders/lib/hatch.glsl: tone comes from a raking light on the rim and the
// hatch is one patch of strokes per wheel, which is what gives it the
// engraved look.

const float MODULE = 0.011;           // pitch diameter per tooth, in screen heights
const float DRIVE = 0.35;             // radians per second on the driver
const float TICK = 2.0;               // escapement beats per second
const float LINE_PX = 1.5;            // outline width in pixels
const vec3 INK = vec3(0.90, 0.84, 0.66);
const vec3 GROUND = vec3(0.035, 0.03, 0.04);

const int WHEELS = 7;
// Centres, in screen heights from the middle. Each driven wheel sits exactly
// r_driver + r_driven from its driver along the stated bearing; the bearing
// is what phaseFor() reads back with atan, so it need not be stored.
const vec2 CENTRE[WHEELS] = vec2[WHEELS](
    vec2(-0.5000,  0.0500),   // A 30 teeth, the driver
    vec2(-0.2906,  0.1476),   // B 12, off A at 25 degrees
    vec2(-0.0356,  0.0793),   // C 36, off B at -15
    vec2( 0.1412, -0.1314),   // D 14, off C at -50
    vec2( 0.0735, -0.3174),   // E 22, off D at -110
    vec2( 0.6000, -0.2200),   // F 24, the escape wheel
    vec2( 0.4610, -0.3367)    // G  9, off F at -140
);
const float TEETH[WHEELS] = float[WHEELS](30.0, 12.0, 36.0, 14.0, 22.0, 24.0, 9.0);
// Which wheel drives each one; -1 for the two that are driven by time.
const int DRIVER[WHEELS] = int[WHEELS](-1, 0, 1, 2, 3, -1, 5);

float pitchRadius(int i) { return MODULE * TEETH[i] * 0.5; }

// Tooth profile: 0 at the root, 1 at the tip, over one tooth period.
float toothProfile(float u) {
    float f = abs(u - 0.5) * 2.0;            // 0 at tooth centre, 1 at gap centre
    return 1.0 - smoothstep(0.35, 0.65, f);
}

// The driven wheel's angle from its driver's, so that the teeth mesh along
// the line of centres. See the derivation in the leading comment: with the
// driver's tooth phase f_i along the bearing alpha, the driven wheel's tooth
// phase along alpha + pi has to be 1/2 - f_i, and this solves for the angle
// that puts it there. The answer is only defined up to one tooth, which is
// all the drawing can see.
float phaseFor(int driven, int driver, float driverAngle) {
    vec2 toDriven = CENTRE[driven] - CENTRE[driver];
    float alpha = atan(toDriven.y, toDriven.x);
    float fi = fract((alpha - driverAngle) * TEETH[driver] / 6.2831853);
    float fj = 0.5 - fi;
    return alpha + 3.14159265 - fj * 6.2831853 / TEETH[driven];
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;
    float pixel = 1.0 / iResolution.y;

    // The driver's angle from the clock, the escape wheel's from the tick,
    // and every other wheel's from the wheel that drives it: phaseFor() gives
    // the angle that meshes with the driver's angle right now, so the ratio
    // and the phase never have to be stated separately. Seven atan calls per
    // pixel is small next to the loop below.
    float land = fract(iTime * TICK);
    float settle = 1.0 - exp(-land * 16.0) * (1.0 - 0.35 * sin(land * 40.0));
    float escape = (floor(iTime * TICK) + settle) * 6.2831853 / TEETH[5];
    float angle[WHEELS];
    for (int i = 0; i < WHEELS; i++) {
        if (i == 0) angle[i] = iTime * DRIVE;
        else if (i == 5) angle[i] = escape;
        else angle[i] = phaseFor(i, DRIVER[i], angle[DRIVER[i]]);
    }

    vec2 light = normalize(vec2(-0.6, 0.8));
    float coverage = 0.0;

    for (int i = 0; i < WHEELS; i++) {
        float r = pitchRadius(i);
        float outer = r + MODULE * 0.9;
        vec2 p = uv - CENTRE[i];
        float dist = length(p);
        // Cheap bound: nothing of this wheel is drawn beyond its tips.
        if (dist - outer > pixel * 2.0) continue;

        float theta = atan(p.y, p.x) - angle[i];
        float u = fract(theta * TEETH[i] / 6.2831853);
        float root = r - MODULE * 1.0;
        float radius = root + (outer - root) * toothProfile(u);
        float rim = dist - radius;
        // The rate only softens the far edge of each line: near the hub the
        // tooth angle turns fast enough that fwidth is many pixels, and a
        // symmetric smoothstep would smear half-drawn ink across the centre.
        float rate = fwidth(rim);
        float halfWidth = LINE_PX * 0.5 * pixel;
        float outline = 1.0 - smoothstep(halfWidth, halfWidth + rate, abs(rim));

        // A hub, and on the larger wheels three windows cut between spokes:
        // an outline around each and no hatching inside.
        float hub = r * 0.22;
        float hubLine = 1.0 - smoothstep(halfWidth, halfWidth + fwidth(dist), abs(dist - hub));
        float window = 0.0;
        float windowLine = 0.0;
        if (TEETH[i] >= 20.0) {
            float s = abs(fract(theta * 3.0 / 6.2831853 + 0.5) - 0.5) * dist * 6.2831853 / 3.0;
            float w = min(min(s - r * 0.12, dist - hub - r * 0.12), root - r * 0.28 - dist);
            float wr = fwidth(w);
            window = smoothstep(-wr, wr, w);
            windowLine = 1.0 - smoothstep(halfWidth, halfWidth + wr, abs(w));
        }
        float inside = 1.0 - smoothstep(0.0, rate, rim);

        // Tone across the face: lit where the rim faces the light, darker
        // towards the tips, and the hatch runs around the wheel.
        float facing = 0.5 + 0.5 * dot(normalize(p), light);
        float tone = 0.78 - 0.45 * (1.0 - facing) * smoothstep(hub, outer, dist) - 0.15 * smoothstep(root - r * 0.3, outer, dist);
        // One stroke direction per wheel, turned a little from its
        // neighbours', the way a burin cuts one patch at a time: a direction
        // that followed the rim would spin the strokes into a whorl at the hub.
        float strokeAngle = 0.6 + float(i) * 0.5;
        vec2 stroke = vec2(cos(strokeAngle), sin(strokeAngle));
        float shade = hatch(tone, stroke, fragCoord) * 0.6 * inside * (1.0 - window);

        coverage = max(coverage, max(max(outline, hubLine * inside), max(windowLine * inside, shade)));
    }

    vec3 color = mix(GROUND, INK, clamp(coverage, 0.0, 1.0));
    fragColor = vec4(color, 1.0);
}
