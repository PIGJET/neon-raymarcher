import vertSource from './shaders/fullscreen.vert.glsl?raw';
import fragSource from './shaders/raymarch.frag.glsl?raw';
import type { RayBasis } from '../game/camera';

/**
 * WebGL2 raymarch renderer.
 *
 * Draws a single fullscreen triangle (see fullscreen.vert.glsl) and lets the
 * fragment shader paint the entire scene. There is no geometry to manage, so
 * this class only owns: the GL context, the compiled program, cached uniform
 * locations, and the canvas sizing.
 */

/** Uniforms handed to the shader each frame. */
export interface FrameState {
  time: number;
  camera: RayBasis;
}

export class Renderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly program: WebGLProgram;
  private readonly vao: WebGLVertexArrayObject;
  private readonly uniforms: Record<string, WebGLUniformLocation | null>;

  /**
   * Resolution multiplier for the backing store. 1.0 = full native resolution;
   * lower values render fewer pixels (cheap upscale) to trade sharpness for fps.
   * Backing store = clientSize * devicePixelRatio * renderScale.
   */
  renderScale = 1.0;

  constructor(private readonly canvas: HTMLCanvasElement) {
    const gl = canvas.getContext('webgl2', {
      antialias: false,
      alpha: false,
      powerPreference: 'high-performance',
    });
    if (!gl) {
      throw new Error('WebGL2 is not available in this browser.');
    }
    this.gl = gl;

    this.program = this.buildProgram(vertSource, fragSource);

    // A VAO is required in WebGL2 even when the vertex shader reads no
    // attributes; the fullscreen triangle is generated from gl_VertexID.
    const vao = gl.createVertexArray();
    if (!vao) throw new Error('Failed to create vertex array object.');
    this.vao = vao;

    this.uniforms = this.cacheUniformLocations([
      'uResolution',
      'uTime',
      'uCamPos',
      'uCamRight',
      'uCamUp',
      'uCamForward',
    ]);

    this.resize();
  }

  /** Compile one shader stage, throwing the full info log on failure. */
  private compileShader(type: number, source: string): WebGLShader {
    const { gl } = this;
    const shader = gl.createShader(type);
    if (!shader) throw new Error('Failed to allocate shader object.');

    gl.shaderSource(shader, source);
    gl.compileShader(shader);

    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(shader) ?? '(no info log)';
      gl.deleteShader(shader);
      const stage = type === gl.VERTEX_SHADER ? 'vertex' : 'fragment';
      // Surface the driver's full log loudly — shader errors are otherwise silent.
      throw new Error(`Failed to compile ${stage} shader:\n${log}`);
    }
    return shader;
  }

  /** Compile + link both stages, throwing the full info log on any failure. */
  private buildProgram(vert: string, frag: string): WebGLProgram {
    const { gl } = this;
    const vertShader = this.compileShader(gl.VERTEX_SHADER, vert);
    const fragShader = this.compileShader(gl.FRAGMENT_SHADER, frag);

    const program = gl.createProgram();
    if (!program) throw new Error('Failed to allocate program object.');

    gl.attachShader(program, vertShader);
    gl.attachShader(program, fragShader);
    gl.linkProgram(program);

    // Shaders can be detached/deleted once linked; the program keeps its copy.
    gl.detachShader(program, vertShader);
    gl.detachShader(program, fragShader);
    gl.deleteShader(vertShader);
    gl.deleteShader(fragShader);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(program) ?? '(no info log)';
      gl.deleteProgram(program);
      throw new Error(`Failed to link program:\n${log}`);
    }
    return program;
  }

  private cacheUniformLocations(names: string[]): Record<string, WebGLUniformLocation | null> {
    const { gl } = this;
    const map: Record<string, WebGLUniformLocation | null> = {};
    for (const name of names) {
      map[name] = gl.getUniformLocation(this.program, name);
    }
    return map;
  }

  /**
   * Match the drawing buffer to the canvas' displayed size. Returns true if the
   * backing store changed, so the caller can react if needed.
   */
  resize(): boolean {
    const { gl, canvas } = this;
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.round(canvas.clientWidth * dpr * this.renderScale));
    const height = Math.max(1, Math.round(canvas.clientHeight * dpr * this.renderScale));

    if (canvas.width === width && canvas.height === height) return false;

    canvas.width = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
    return true;
  }

  /** Render one frame. */
  render(state: FrameState): void {
    const { gl } = this;
    this.resize();

    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);

    const cam = state.camera;
    gl.uniform2f(this.uniforms.uResolution, gl.drawingBufferWidth, gl.drawingBufferHeight);
    gl.uniform1f(this.uniforms.uTime, state.time);
    gl.uniform3fv(this.uniforms.uCamPos, cam.position);
    gl.uniform3fv(this.uniforms.uCamRight, cam.right);
    gl.uniform3fv(this.uniforms.uCamUp, cam.up);
    gl.uniform3fv(this.uniforms.uCamForward, cam.forward);

    // 3 vertices, no buffer: the vertex shader synthesises the triangle.
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
