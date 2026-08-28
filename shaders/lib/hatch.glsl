// Hatching and line work driven by luminance, for shaders that want to look
// like an engraving rather than a render. hatch(luminance, direction,
// fragCoord) returns ink coverage in 0..1: a family of parallel lines appears
// where the luminance falls below one threshold, a second family at another
// angle appears in the darker range, and a third in the darkest, so the
// shading is cross-hatched instead of screened once. The direction is the
// caller's - a surface normal, or the gradient of whatever field is being
// drawn - and lines run across it.
//
// The line spacing is counted in pixels rather than screen heights, like the
// dither, because hatching that scales with the screen is a fill pattern
// rather than a drawing. It is scaled by the same integer factor as the
// dither cell (one below 1440 rows, one more per 720 rows after that) so the
// density at 3832x1936 matches the density at 1280x720 rather than being a
// fine grey.
//
// Line width is held constant on screen by measuring the projected
// coordinate's rate of change with fwidth, the way synthwave widens its grid
// lines: without it lines drawn across a steep gradient are slabs and lines
// across a shallow one alias into a shimmer.
//
// The direction is snapped to one of HATCH_ANGLES before the lines are laid
// down. Lines are periodic in the pixel projected onto the direction, so a
// direction that turns smoothly from pixel to pixel turns the phase with it
// and the lines wind into whorls - the first version of the contour shader
// did exactly that. An engraver's burin does not steer per pixel either: it
// cuts a patch of parallel strokes and changes angle between patches.

const float HATCH_SPACING_PX = 7.0;   // between lines of one family, in pixels
const float HATCH_ANGLES = 12.0;      // directions a patch of strokes can take
const float HATCH_LINE_PX = 1.2;      // ink width, in pixels
// Luminance below which each family starts, and where it is fully drawn.
const vec3 HATCH_STARTS = vec3(0.80, 0.50, 0.25);
const vec3 HATCH_FULL = vec3(0.55, 0.30, 0.10);

// Integer scale of the hatch spacing, from the screen height.
float hatchScale() {
    return max(1.0, floor(iResolution.y / 720.0));
}

// Ink coverage of one family of lines running across `along`, which is the
// pixel projected onto the line-normal direction, in pixels.
float hatchLines(float along, float spacing) {
    float rate = fwidth(along);
    float f = abs(fract(along / spacing) - 0.5) * spacing;   // distance to nearest line
    float halfWidth = HATCH_LINE_PX * 0.5;
    return 1.0 - smoothstep(halfWidth - rate, halfWidth + rate, f);
}

// Cross-hatched ink coverage for a luminance in 0..1. `direction` is the
// unit direction the first family runs along; the second is turned 60
// degrees from it and the third 120, which keeps them from ever lining up.
float hatch(float luminance, vec2 direction, vec2 fragCoord) {
    vec2 p = fragCoord / hatchScale();
    float spacing = HATCH_SPACING_PX;
    float angle = atan(direction.y, direction.x);
    angle = floor(angle * HATCH_ANGLES / 3.14159265 + 0.5) * 3.14159265 / HATCH_ANGLES;
    vec2 d1 = vec2(cos(angle), sin(angle));
    vec2 d2 = vec2(d1.x * 0.5 - d1.y * 0.8660254, d1.x * 0.8660254 + d1.y * 0.5);
    vec2 d3 = vec2(d2.x * 0.5 - d2.y * 0.8660254, d2.x * 0.8660254 + d2.y * 0.5);
    // Perpendicular to each direction is the coordinate the lines step in.
    vec3 weight = 1.0 - smoothstep(HATCH_FULL, HATCH_STARTS, vec3(luminance));
    float ink = 0.0;
    ink = max(ink, hatchLines(dot(p, vec2(-d1.y, d1.x)), spacing) * weight.x);
    ink = max(ink, hatchLines(dot(p, vec2(-d2.y, d2.x)), spacing) * weight.y);
    ink = max(ink, hatchLines(dot(p, vec2(-d3.y, d3.x)), spacing) * weight.z);
    return clamp(ink, 0.0, 1.0);
}

// The direction to hatch along for a scalar field with gradient `gradient`:
// lines follow the contours, which is what an engraver does. A flat field
// (no gradient) hatches at a fixed angle rather than nowhere.
vec2 hatchDirection(vec2 gradient) {
    float len = length(gradient);
    if (len < 1e-5) return vec2(0.7071068, 0.7071068);
    return vec2(-gradient.y, gradient.x) / len;
}
