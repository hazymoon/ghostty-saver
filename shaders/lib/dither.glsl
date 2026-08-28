// RGB555 quantisation and a 4x4 Bayer dither, for the look of a console that
// had 32 levels per channel. Apply last, on the final colour, so it composes
// with anything: fragColor.rgb = dither555(color, fragCoord).
//
// The threshold is added before the rounding, not after. Rounding first and
// then adding noise gives banding with speckle on top of it; adding the
// threshold first is what turns the round into a dither.
//
// The pattern is counted in pixels rather than screen heights, on purpose: a
// dither that scales with the screen stops being a dither. It is scaled by
// an integer factor from the screen height so that the pattern stays a
// pattern on a large display. Compared on the gradient fixture at 1280x720
// and 3832x1936: at scale 1 the 4x4 cell on the 4K frame is a smooth tone at
// any distance, indistinguishable from no dither, while scale 2 there reads
// the way scale 1 does at 720p. So the scale is 1 below 1440 rows and one
// more per 720 rows after that, which is the ratio of the two heights.

// Bayer 4x4 threshold for a pixel, in 0..15.
float bayer4(vec2 pixel) {
    ivec2 p = ivec2(mod(pixel, 4.0));
    // Bit interleave of x and x^y, the closed form of the recursive matrix.
    int a = p.x ^ p.y;
    return float(((p.x & 1) << 3) | ((a & 1) << 2) | ((p.x & 2) << 0) | ((a & 2) >> 1));
}

// Integer scale of the dither cell, from the screen height.
float ditherScale() {
    return max(1.0, floor(iResolution.y / 720.0));
}

// Round each channel to one of 32 levels.
vec3 quantise555(vec3 c) {
    return floor(clamp(c, 0.0, 1.0) * 31.0 + 0.5) / 31.0;
}

// Dither and quantise. fragCoord is the pixel, so the pattern is in pixels.
vec3 dither555(vec3 c, vec2 fragCoord) {
    float threshold = (bayer4(floor(fragCoord / ditherScale())) / 16.0 - 0.5) / 31.0;
    return quantise555(c + threshold);
}
