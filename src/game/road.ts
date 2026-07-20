/**
 * Analytic road centerline — the CPU half of a contract shared with the shader.
 *
 * The road is NOT stored geometry: it is a closed-form curve `x = roadX(z)` that
 * both the fragment shader (for rendering the asphalt + building canyon) and the
 * game logic (camera path now, car physics later) evaluate independently. Because
 * both sides use the identical formula and constants, they always agree on where
 * the road is.
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │ SYNC CONTRACT: the constants and roadX()/roadDX() below are duplicated in │
 * │ raymarch.frag.glsl (the RD_* consts + roadX/roadDX). Change one, change   │
 * │ the other, or the rendered road and the driven road diverge.             │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * The centerline sums three sines of increasing frequency and decreasing
 * amplitude. Kept deliberately gentle so the curve is drivable at speed:
 * the worst-case heading is ~28deg off straight and the tightest radius of
 * curvature is ~29 units, well above the car's turning envelope.
 */

// Amplitudes (world units) and angular frequencies (radians per unit of z).
// Frequencies are 2*pi / wavelength for wavelengths 200 / 95 / 55 units.
const RD_A1 = 6.0;
const RD_A2 = 3.0;
const RD_A3 = 1.2;
const RD_F1 = 0.03141593; // 2*pi / 200
const RD_F2 = 0.06613879; // 2*pi / 95
const RD_F3 = 0.11424174; // 2*pi / 55
const RD_P2 = 1.7; // phase offsets so the harmonics do not all peak together
const RD_P3 = 4.2;

/** Lateral position of the road centerline at longitudinal position `z`. */
export function roadX(z: number): number {
  return (
    RD_A1 * Math.sin(z * RD_F1) +
    RD_A2 * Math.sin(z * RD_F2 + RD_P2) +
    RD_A3 * Math.sin(z * RD_F3 + RD_P3)
  );
}

/** dx/dz of the centerline — the slope of the road in the x–z plane. */
export function roadDX(z: number): number {
  return (
    RD_A1 * RD_F1 * Math.cos(z * RD_F1) +
    RD_A2 * RD_F2 * Math.cos(z * RD_F2 + RD_P2) +
    RD_A3 * RD_F3 * Math.cos(z * RD_F3 + RD_P3)
  );
}

/**
 * Unit tangent of the centerline at `z`, pointing forward (+z). The path is
 * (roadX(z), y, z), so its derivative is (roadDX(z), 0, 1) normalized.
 * Useful for orienting the car and (later) road-aligned obstacles.
 */
export function roadDir(z: number): [number, number, number] {
  const dx = roadDX(z);
  const len = Math.hypot(dx, 1) || 1;
  return [dx / len, 0, 1 / len];
}

// --- Road cross-section constants (mirrored in raymarch.frag.glsl) -----------
/** Half of the drivable road width. Road spans x in [roadX-HW, roadX+HW]. */
export const ROAD_HALF_WIDTH = 4.5;
/** Lane width. Two lanes per direction => four lanes across the 9-unit road. */
export const LANE_WIDTH = ROAD_HALF_WIDTH / 2;
/** Number of lanes per travel direction. */
export const LANES_PER_SIDE = 2;
