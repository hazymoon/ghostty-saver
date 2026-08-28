// The Moon at tonight's phase, nodding through its libration, with the dark
// limb faintly lit by earthshine.
//
// Stateless by construction, like every shader here, and the date is an
// input rather than something invented: iDate carries the calendar day and
// the seconds since midnight, so every frame works out the Moon's age from
// scratch. The age comes from a mean synodic month against a known new moon
// (2000-01-06 18:14 UTC). That is a few hours off the true phase at any given
// date - the real month wobbles by up to half a day - which is invisible on
// a disc a few hundred pixels across. A full ephemeris would buy nothing.
//
// The disc is one ray-sphere intersection. The sun direction is the phase
// angle swung round the disc; earthshine is a second, much dimmer light from
// the opposite side, strongest near new moon. Libration is two slow rotations
// of the surface (latitude and longitude, on the anomalistic and draconic
// months) so the same face shows a little more of one limb, then the other.
// iTime does two small things: it carries the libration smoothly between the
// whole seconds iDate gives, and it drifts the disc slowly across the sky so
// the picture is not a still. A dump at the same date and time is the same
// frame.
//
// The surface is procedural: maria as low-frequency dark patches, craters as
// hash-placed rings in three sizes, both shaded by a normal that tilts at the
// crater rim so they show most where the light is shallow.

const float SYNODIC = 29.530588853;     // days, mean
const float EPOCH_JD = 2451550.26;      // JD of the reference new moon
const float MOON_RADIUS = 0.36;         // in screen heights
const float LIBRATION = 0.10;           // radians, about 6 degrees each axis
const float AXIAL_TILT = -0.12;         // the disc leans a little, as it does low in the sky
const float DRIFT = 0.09;               // how far the disc wanders, in screen heights

const vec3 SUNLIT = vec3(0.92, 0.90, 0.84);
const vec3 EARTHSHINE = vec3(0.18, 0.21, 0.30);
const vec3 SKY = vec3(0.010, 0.012, 0.024);
const vec3 MARIA = vec3(0.62, 0.62, 0.66);

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float hash31(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

// Value noise on the sphere, three octaves. Cheap enough to run twice.
float noise3(vec3 p) {
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

mat3 rotateX(float a) {
    float c = cos(a), s = sin(a);
    return mat3(1, 0, 0, 0, c, s, 0, -s, c);
}

mat3 rotateY(float a) {
    float c = cos(a), s = sin(a);
    return mat3(c, 0, -s, 0, 1, 0, s, 0, c);
}

// Days since the reference new moon, from the calendar in iDate. The Julian
// day formula is the usual integer one; iDate.y is the month counted from 0.
float daysSinceEpoch() {
    float y = iDate.x;
    float m = iDate.y + 1.0;
    float d = iDate.z;
    float a = floor((14.0 - m) / 12.0);
    float yy = y + 4800.0 - a;
    float mm = m + 12.0 * a - 3.0;
    float jdn = d + floor((153.0 * mm + 2.0) / 5.0) + 365.0 * yy + floor(yy / 4.0)
        - floor(yy / 100.0) + floor(yy / 400.0) - 32045.0;
    // The whole seconds from iDate, plus the fraction iTime has run past
    // them, so the libration does not step once a second.
    float seconds = iDate.w + fract(iTime);
    return (jdn - 0.5 + seconds / 86400.0) - EPOCH_JD;
}

// Height field of the surface at a unit-sphere point: maria below, craters
// above. Returns the height and writes the crater-rim slope for the normal.
float surface(vec3 p, out float rim, out float maria) {
    // Maria: two octaves of noise, thresholded softly, in a few large patches.
    maria = smoothstep(0.52, 0.66, noise3(p * 2.3) * 0.7 + noise3(p * 4.7) * 0.3);

    // Craters: cells on the cube-mapped position, one ring per cell if the
    // cell's hash says so. Three sizes, the small ones dense.
    rim = 0.0;
    float height = 0.0;
    for (int layer = 0; layer < 3; layer++) {
        float scale = 6.0 * pow(2.2, float(layer));
        vec3 cell = floor(p * scale);
        vec3 inCell = fract(p * scale) - 0.5;
        float seed = hash31(cell + float(layer) * 17.0);
        if (seed > 0.30 + 0.12 * float(layer)) continue;
        vec3 centre = vec3(hash31(cell + 1.3), hash31(cell + 5.7), hash31(cell + 9.1)) - 0.5;
        float radius = 0.16 + 0.18 * hash31(cell + 3.3);
        float d = length(inCell - centre * 0.5) / radius;
        // A bowl with a raised rim: down inside, up at the edge.
        float bowl = smoothstep(1.0, 0.7, d) * -0.35;
        float ring = smoothstep(1.15, 1.0, d) * smoothstep(0.75, 1.0, d);
        float weight = 1.0 / (1.0 + float(layer) * 0.8);
        height += (bowl + ring) * weight;
        rim += (ring - smoothstep(1.0, 0.7, d)) * weight;
    }
    return height - maria * 0.3;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;
    float pixel = 1.0 / iResolution.y;

    float days = daysSinceEpoch();
    float age = mod(days, SYNODIC);
    float phase = age / SYNODIC;                    // 0 new, 0.5 full
    float phaseAngle = phase * 6.28318530718;

    // The Sun as seen from the Moon: swings round the disc once a month.
    // At new moon it is behind (-z), at full moon it is in front (+z).
    // Waxing on the right, waning on the left, as seen from the north.
    vec3 sunDir = normalize(vec3(sin(phaseAngle), 0.0, -cos(phaseAngle)));
    // Earthshine comes from the Earth, which is where the viewer is: +z.
    // Brightest when the Earth is full as seen from the Moon, i.e. our new moon.
    float earthshine = 0.5 + 0.5 * cos(phaseAngle);

    // Sky: a faint hashed starfield.
    vec3 color = SKY;
    vec2 starCell = floor(fragCoord / (iResolution.y / 48.0));
    float starSeed = hash21(starCell);
    if (starSeed < 0.06) {
        vec2 inCell = fract(fragCoord / (iResolution.y / 48.0));
        vec2 at = vec2(hash21(starCell + 3.7), hash21(starCell + 9.1)) * 0.8 + 0.1;
        float star = exp(-dot(inCell - at, inCell - at) * 400.0);
        color += vec3(0.75, 0.78, 0.9) * star * (0.4 + 0.5 * hash21(starCell + 1.1));
    }

    // The disc wanders slowly, on two incommensurate periods so it does not
    // trace a visible loop.
    vec2 centre = DRIFT * vec2(sin(iTime * 0.073), 0.6 * cos(iTime * 0.047));

    // Ray-sphere, orthographic: the disc is a circle, the depth a square root.
    vec2 q = (uv - centre) / MOON_RADIUS;
    float rr = dot(q, q);
    float edge = smoothstep(1.0 + 2.0 * pixel / MOON_RADIUS, 1.0 - 2.0 * pixel / MOON_RADIUS, rr);
    if (edge <= 0.0) {
        fragColor = vec4(color, 1.0);
        return;
    }
    vec3 n = vec3(q, sqrt(max(0.0, 1.0 - rr)));

    // Libration: the face turns a few degrees in latitude and longitude on
    // two periods close to a month, so the wobble drifts against the phase.
    float lat = LIBRATION * sin(days * 6.28318530718 / 27.212);
    float lon = LIBRATION * sin(days * 6.28318530718 / 27.555 + 1.3);
    mat3 toSurface = rotateY(lon) * rotateX(lat) * rotateY(0.0);
    mat3 lean = mat3(cos(AXIAL_TILT), sin(AXIAL_TILT), 0, -sin(AXIAL_TILT), cos(AXIAL_TILT), 0, 0, 0, 1);
    vec3 p = toSurface * (lean * n);

    float rim, maria;
    float height = surface(p, rim, maria);

    // The normal tilts at crater rims: sample the height along two tangents.
    vec3 tangent = normalize(cross(n, vec3(0, 1, 0)));
    vec3 bitangent = cross(n, tangent);
    float step = 0.012;
    float unusedRim, unusedMaria;
    float hx = surface(toSurface * (lean * normalize(n + tangent * step)), unusedRim, unusedMaria);
    float hy = surface(toSurface * (lean * normalize(n + bitangent * step)), unusedRim, unusedMaria);
    float bump = 0.035;
    vec3 shadingNormal = normalize(n - tangent * (hx - height) * bump / step
                                     - bitangent * (hy - height) * bump / step);

    // Albedo: maria darker, crater floors darker still, rims bright.
    float albedo = 0.80 + height * 0.12 + rim * 0.10;
    vec3 base = mix(vec3(1.0), MARIA / 0.66, maria);

    // Sunlight. The bumped normal gives the crater shading; the geometric
    // normal gates it, so a rim on the night side cannot catch light that
    // the body of the Moon is in the way of. The terminator is softened a
    // touch so the crescent's inner edge is not a hard line.
    float sun = smoothstep(-0.03, 0.12, dot(shadingNormal, sunDir))
        * smoothstep(-0.02, 0.10, dot(n, sunDir));
    // Earthshine lights the disc from the viewer's side, cosine falloff.
    float earth = max(0.0, dot(shadingNormal, vec3(0, 0, 1))) * earthshine;

    vec3 lit = base * albedo * (SUNLIT * sun + EARTHSHINE * earth * 0.55);
    // A trace of the disc against the sky even at new moon, so it is there.
    lit += EARTHSHINE * 0.06 * earthshine;

    color = mix(color, lit, edge);
    fragColor = vec4(color, 1.0);
}
