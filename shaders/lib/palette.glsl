// Palette indirection: a shader names a role - sky, ground, ink, highlight,
// accent - and gets a colour, and which palette answers depends on the time
// of day. That is the only thing that changes, so "morning, noon, dusk,
// night" is four tables here rather than four copies of a shader.
//
// The clock is iDate.w, seconds since local midnight, which the screensaver
// fills from the wall clock (or from --date) and Ghostty fills itself, so
// the same file follows the day on both paths. Ghostty's own terminal
// palette, iPalette[256], is a different thing: it is zero in the
// screensaver and never written here.
//
// Neighbouring palettes are blended over PALETTE_BLEND seconds either side
// of each boundary, so dusk is a slide rather than a cut at a wall-clock
// minute. Between blends the palette is exact, and a pinned iDate gives the
// same colours every time.
//
// Night is honestly dark, except for ROLE_HIGHLIGHT, which stays bright at
// every hour: a shader that puts one element in that role clears the
// suite's "draws something" check (peak above 40) at any time of day
// without the whole palette being lightened to satisfy a test.

const int ROLE_SKY = 0;
const int ROLE_GROUND = 1;
const int ROLE_INK = 2;
const int ROLE_HIGHLIGHT = 3;
const int ROLE_ACCENT = 4;

const float PALETTE_BLEND = 1800.0;   // seconds of crossfade around a boundary

// Boundaries, in seconds since midnight: dawn from 05:00, day from 08:00,
// dusk from 17:30, night from 20:00.
const vec4 PALETTE_STARTS = vec4(18000.0, 28800.0, 63000.0, 72000.0);

// One palette per time of day, in role order.
const vec3 PALETTE_DAWN[5] = vec3[5](
    vec3(0.95, 0.58, 0.45),   // sky
    vec3(0.24, 0.16, 0.22),   // ground
    vec3(0.30, 0.12, 0.18),   // ink
    vec3(1.00, 0.92, 0.75),   // highlight
    vec3(0.98, 0.40, 0.35)    // accent
);
const vec3 PALETTE_DAY[5] = vec3[5](
    vec3(0.42, 0.68, 0.96),
    vec3(0.34, 0.52, 0.28),
    vec3(0.10, 0.12, 0.18),
    vec3(1.00, 1.00, 0.95),
    vec3(0.98, 0.78, 0.22)
);
const vec3 PALETTE_DUSK[5] = vec3[5](
    vec3(0.62, 0.30, 0.48),
    vec3(0.18, 0.10, 0.16),
    vec3(0.12, 0.05, 0.10),
    vec3(1.00, 0.72, 0.40),
    vec3(0.95, 0.35, 0.25)
);
const vec3 PALETTE_NIGHT[5] = vec3[5](
    vec3(0.03, 0.04, 0.10),
    vec3(0.02, 0.02, 0.04),
    vec3(0.01, 0.01, 0.02),
    vec3(0.85, 0.90, 1.00),
    vec3(0.30, 0.45, 0.80)
);

// The time of day, in seconds since local midnight.
float dayPhase() {
    return iDate.w;
}

vec3 paletteEntry(int which, int role) {
    if (which == 0) return PALETTE_NIGHT[role];
    if (which == 1) return PALETTE_DAWN[role];
    if (which == 2) return PALETTE_DAY[role];
    if (which == 3) return PALETTE_DUSK[role];
    return PALETTE_NIGHT[role];
}

// The colour for a role at a given time of day. Palettes are numbered
// night 0, dawn 1, day 2, dusk 3, night 4, and the boundary before palette
// n is PALETTE_STARTS[n - 1]; the blend runs from PALETTE_BLEND before it to
// PALETTE_BLEND after.
vec3 paletteColor(int role, float secondsSinceMidnight) {
    float t = mod(secondsSinceMidnight, 86400.0);
    int which = 0;
    for (int i = 0; i < 4; i++) {
        if (t >= PALETTE_STARTS[i]) which = i + 1;
    }
    vec3 color = paletteEntry(which, role);
    // Slide into the next palette as its boundary approaches, and out of the
    // previous one just after ours.
    if (which < 4) {
        float toNext = PALETTE_STARTS[which] - t;
        if (toNext < PALETTE_BLEND) {
            float k = 0.5 - 0.5 * toNext / PALETTE_BLEND;
            color = mix(color, paletteEntry(which + 1, role), smoothstep(0.0, 1.0, k));
        }
    }
    if (which > 0) {
        float sinceLast = t - PALETTE_STARTS[which - 1];
        if (sinceLast < PALETTE_BLEND) {
            float k = 0.5 - 0.5 * sinceLast / PALETTE_BLEND;
            color = mix(color, paletteEntry(which - 1, role), smoothstep(0.0, 1.0, k));
        }
    }
    return color;
}
