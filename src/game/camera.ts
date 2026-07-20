import { roadX } from './road';

/**
 * Camera for Milestone 2: a fly-along preview that rides the procedural road.
 *
 * The renderer needs a ray basis, not a view matrix: for each pixel the shader
 * builds a primary ray as `forward + uv.x*right + uv.y*up`. So the camera's job
 * is to produce an eye position plus an orthonormal (right, up, forward) basis.
 *
 * The public shape (position + basis vectors via `getRayBasis`) is deliberately
 * generic so the real chase camera can drop in later without touching the
 * renderer.
 */

export interface RayBasis {
  /** Eye position in world space. */
  position: [number, number, number];
  /** Unit basis pointing right in the image plane. */
  right: [number, number, number];
  /** Unit basis pointing up in the image plane. */
  up: [number, number, number];
  /** Unit basis pointing from the eye toward the target. */
  forward: [number, number, number];
}

/** World up used to derive the camera's right/up vectors. */
const WORLD_UP: [number, number, number] = [0, 1, 0];

function sub(a: readonly number[], b: readonly number[]): [number, number, number] {
  return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

function cross(a: readonly number[], b: readonly number[]): [number, number, number] {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
}

function normalize(v: readonly number[]): [number, number, number] {
  const len = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / len, v[1] / len, v[2] / len];
}

/**
 * PathCamera: glides forward along the road centerline and looks at a point
 * further down the road. Because both the eye and the look-at point sit on the
 * curve, the camera yaws to follow bends and banks gently through them — a
 * cheap stand-in for the eventual chase cam that previews the generated city.
 */
export class PathCamera {
  /** Longitudinal position along the road (world z). Advances every frame. */
  z = 0;
  /** Forward speed in world units per second. */
  speed = 14;
  /** Eye height above the ground plane. */
  height = 3.5;
  /** How far ahead (in z) the camera aims — larger = smoother, less banking. */
  lookAhead = 15;
  /** Height of the aim point; below eye level so we look slightly down at the road. */
  lookHeight = 1.5;

  /** Advance the flight by `dt` seconds. */
  update(dt: number): void {
    this.z += this.speed * dt;
  }

  /** Current eye position and orthonormal ray basis for the shader. */
  getRayBasis(): RayBasis {
    const position: [number, number, number] = [roadX(this.z), this.height, this.z];

    const aheadZ = this.z + this.lookAhead;
    const target: [number, number, number] = [roadX(aheadZ), this.lookHeight, aheadZ];

    const forward = normalize(sub(target, position));
    const right = normalize(cross(forward, WORLD_UP));
    // Re-derive up from the orthonormal pair so the basis stays square.
    const up = normalize(cross(right, forward));

    return { position, right, up, forward };
  }
}
