import { Renderer } from './render/renderer';
import { PathCamera } from './game/camera';

/**
 * Bootstrap: wire up the canvas, renderer and camera, then run the render loop.
 * Milestone 2 flies a preview camera down an endless procedural neon city.
 */

const canvas = document.querySelector<HTMLCanvasElement>('#scene');
const hud = document.querySelector<HTMLDivElement>('#hud');
if (!canvas) throw new Error('Missing <canvas id="scene"> in the document.');

// If WebGL2 or shader compilation fails, surface it on the HUD instead of a
// blank screen so the failure is visible without opening the console.
let renderer: Renderer;
try {
  renderer = new Renderer(canvas);
} catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  if (hud) hud.textContent = 'Renderer error — see console';
  console.error(message);
  throw err;
}

const camera = new PathCamera();

// Smoothed fps: exponential moving average, displayed ~2x per second so the
// readout is stable rather than flickering every frame.
let smoothedFps = 60;
let lastHudUpdate = 0;
let lastFrame = performance.now();

function frame(now: number): void {
  const dt = Math.min((now - lastFrame) / 1000, 0.1); // clamp huge tab-switch gaps
  lastFrame = now;

  if (dt > 0) {
    const instantFps = 1 / dt;
    smoothedFps += (instantFps - smoothedFps) * 0.1;
  }

  camera.update(dt);

  renderer.render({
    time: now / 1000,
    camera: camera.getRayBasis(),
  });

  if (hud && now - lastHudUpdate > 500) {
    hud.textContent = `fps ${smoothedFps.toFixed(0)}`;
    lastHudUpdate = now;
  }

  requestAnimationFrame(frame);
}

requestAnimationFrame(frame);
