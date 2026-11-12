// The desk itself: a plain dark blue surface whose colour darkens toward the edges of the view (a vignette worked out per
// pixel on screen, so it stays put while the desk pans), soft shadows laid over it, one warm key light from the upper left
// casting those shadows, a dim cool fill, and a small room-shaped environment for reflections on glossy prints.
import { Color, DirectionalLight, HemisphereLight, Mesh, NeutralToneMapping, PCFShadowMap, PlaneGeometry, PMREMGenerator,
  ShaderMaterial, ShadowMaterial, Vector2 } from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import type { StageContext } from '../types.ts';
import { DESK, LIGHT } from './palette.ts';

/** Where the key light comes from (x left, y far, z up): high on the upper left. */
const KEY_FROM = { x: -0.55, y: 0.48, z: 1.05 };
const SHADOW_MAP = 2048;
const SHADOW_SOFTNESS = 3.5;
const SURFACE = 8000;

const vertex = /* glsl */ `
  void main() { gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }
`;
// The vignette from the pixel's place on screen; a little noise keeps the dark gradient from banding.
const fragment = /* glsl */ `
  uniform vec3 centre;
  uniform vec3 edge;
  uniform vec2 resolution;
  float noise(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
  void main() {
    vec2 q = gl_FragCoord.xy / resolution - 0.5;
    q.x *= resolution.x / resolution.y * 0.72;
    float t = smoothstep(0.18, 0.78, length(q));
    vec3 c = mix(centre, edge, t);
    c += (noise(gl_FragCoord.xy) - 0.5) / 255.0;
    gl_FragColor = vec4(c, 1.0);
    #include <colorspace_fragment>
  }
`;

export function setupStage({ scene, renderer }: StageContext): void {
  renderer.toneMapping = NeutralToneMapping;
  renderer.toneMappingExposure = 1;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = PCFShadowMap;

  const geometry = new PlaneGeometry(SURFACE, SURFACE);
  const resolution = new Vector2(1, 1);
  const surface = new Mesh(geometry, new ShaderMaterial({
    vertexShader: vertex, fragmentShader: fragment, toneMapped: false,
    uniforms: { centre: { value: new Color(DESK.centre) }, edge: { value: new Color(DESK.edge) }, resolution: { value: resolution } },
  }));
  surface.onBeforeRender = r => { r.getDrawingBufferSize(resolution); };
  surface.renderOrder = -2;
  surface.name = 'desk-surface';
  scene.add(surface);

  const shadows = new Mesh(geometry, new ShadowMaterial({ color: new Color(DESK.shadow), opacity: DESK.shadowOpacity, depthWrite: false }));
  shadows.position.z = 0.004;
  shadows.receiveShadow = true;
  shadows.name = 'desk-shadows';
  scene.add(shadows);

  const key = new DirectionalLight(LIGHT.key, LIGHT.keyIntensity);
  key.position.set(KEY_FROM.x, KEY_FROM.y, KEY_FROM.z).multiplyScalar(150);
  key.castShadow = true;
  key.shadow.mapSize.set(SHADOW_MAP, SHADOW_MAP);
  key.shadow.radius = SHADOW_SOFTNESS;
  key.shadow.bias = -0.0005;
  key.shadow.normalBias = 0.03;
  const cam = key.shadow.camera;
  cam.near = 1; cam.far = 400; cam.left = -100; cam.right = 100; cam.top = 100; cam.bottom = -100;
  cam.updateProjectionMatrix();
  key.name = 'key-light';
  scene.add(key);
  scene.add(key.target);

  const fill = new HemisphereLight(LIGHT.sky, LIGHT.ground, LIGHT.fillIntensity);
  fill.position.set(0, 0, 1);
  scene.add(fill);

  const pmrem = new PMREMGenerator(renderer);
  const room = new RoomEnvironment();
  scene.environment = pmrem.fromScene(room, 0.04).texture;
  scene.environmentIntensity = LIGHT.environmentIntensity;
  // The room is built y-up; the desk is z-up.
  scene.environmentRotation.set(Math.PI / 2, 0, 0);
  room.dispose();
  pmrem.dispose();
}
