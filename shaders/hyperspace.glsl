// Jump to lightspeed: stars drift, then stretch into streaks, then the whole
// field whites out and drops back to a cruise.
//
// Stateless by construction, like every shader here. The star field is a polar
// grid rather than a list of particles: each angular cell holds one star whose
// distance from the middle is a closed form in iTime, so there is nothing to
// carry between frames.
//
// The travelled distance is written as a function whose derivative is known in
// closed form, and that derivative is the speed the streak lengths are taken
// from. Differentiating the position rather than estimating it is what keeps
// the streaks exactly as long as the star's own motion during one exposure.

const int LAYERS = 5;
const float CELLS = 55.0;         // angular cells in one layer

const float CYCLE = 22.0;         // seconds from one jump to the next
const float RAMP_AT = 13.0;       // when the engines start winding up
const float CRUISE = 0.16;        // units of travel per second while drifting
const float ACCEL = 0.10;         // how hard the wind-up pulls
const float FLASH_FOR = 0.9;      // seconds of white-out either side of a jump
const float FLASH_PEAK = 0.82;    // held short of pure white: this runs in a dark room

const float SPREAD = 4.2;         // e-foldings of radius a star crosses on its way out
const float NEAR_EDGE = 1.5;      // radius, in screen heights, it ends that journey at
const float EXPOSURE = 1.0 / 26.0; // shutter time the streak length stands for

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Distance travelled since the last jump. Quadratic after the wind-up starts,
// so the speed below is its exact derivative rather than a second guess at it.
float travelled(float u) {
    float wind = max(u - RAMP_AT, 0.0);
    return CRUISE * u + ACCEL * wind * wind;
}

float speed(float u) {
    return CRUISE + 2.0 * ACCEL * max(u - RAMP_AT, 0.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Units of screen height, origin in the middle: the vanishing point the
    // stars come out of.
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float radius = length(p);
    float pixel = 1.0 / iResolution.y;

    float u = mod(iTime, CYCLE);
    float travel = travelled(u);
    float rate = speed(u);
    // Streak length is how far the star moves while the shutter is open, so it
    // falls out of the speed instead of being animated separately.
    float streak = SPREAD * rate * EXPOSURE;

    float turns = atan(p.y, p.x) * 0.15915494 + 0.5;   // 1/(2*pi), then 0..1

    vec3 color = vec3(0.0);

    for (int layer = 0; layer < LAYERS; layer++) {
        float depth = float(layer);
        float around = turns * CELLS + depth * 0.317;
        // Wrapping the cell index rather than taking it straight from floor()
        // is what keeps a star from being cut in half at the seam where the
        // angle rolls over.
        float cell = mod(floor(around), CELLS);
        float seed = hash21(vec2(cell, depth));

        // Where in its cell the star sits, so the field does not read as spokes.
        float offset = fract(around) - hash11(seed * 31.7);
        float sideways = abs(offset) / CELLS * 6.28318 * radius;

        // 0 far, 1 near. Radius grows exponentially with it, which is what a
        // constant closing speed looks like under perspective.
        //
        // It lands exactly on NEAR_EDGE at the end rather than somewhere short
        // of it, which is what the fade below needs: a star that restarts
        // before that fade has finished blinks out with the screen still under
        // it.
        float along = fract(seed * 13.0 + travel + depth * 0.611);
        float head = NEAR_EDGE * exp(SPREAD * (along - 1.0));

        float behind = head - radius;
        float reach = streak * head;
        if (behind < -pixel || behind > reach + pixel) { continue; }

        // Along the streak: solid at the head, tapering back.
        float tail = 1.0 - smoothstep(0.0, max(reach, pixel * 0.7), max(behind, 0.0));
        // Across it: a thin core that thickens a little as the star closes in.
        float width = pixel * (0.95 + 1.7 * head);
        float across = exp(-(sideways * sideways) / (width * width));

        // Fade in out of the vanishing point and out again at the edge, so
        // nothing pops into or out of existence mid-screen.
        float born = smoothstep(0.0, 0.16, along);
        float dying = 1.0 - smoothstep(NEAR_EDGE * 0.55, NEAR_EDGE, head);
        float brightness = (0.45 + 0.75 * hash11(seed * 7.11)) * born * dying;

        // Mostly white, tinted towards blue with a few warm ones.
        vec3 tint = mix(vec3(0.62, 0.78, 1.00), vec3(1.00, 0.92, 0.78), hash11(seed * 3.13));
        color += tint * across * tail * brightness;
    }

    // The blue wash that builds as the engines wind up.
    float winding = smoothstep(RAMP_AT, CYCLE, u);
    color += vec3(0.10, 0.24, 0.65) * winding * winding
        * (0.22 + 0.42 * smoothstep(1.3, 0.0, radius));

    // The white-out spans the wrap: the star positions restart there, and this
    // is what covers the seam.
    float toJump = min(u, CYCLE - u);
    float flash = smoothstep(FLASH_FOR, 0.0, toJump);
    color = mix(color, vec3(0.82, 0.90, 1.00), flash * flash * FLASH_PEAK);

    fragColor = vec4(color, 1.0);
}
