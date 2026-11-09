// mask-pointcloud.js — Venice mask point cloud with red hover lens + click shockwave
// Usage:
//   import { mountMask } from './mask-pointcloud.js';
//   const mask = mountMask(document.getElementById('hero-3d'), { pcdUrl: '/assets/venice_mask_rgb.pcd' });
//   // later: mask.dispose();
// Needs three.js (r150+) with an import map for 'three' and 'three/addons/'.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { PCDLoader } from 'three/addons/loaders/PCDLoader.js';

const VERT = `
      attribute float seed;
      uniform float uTime, uSize, uScale, uHover, uRadius, uForce, uUseTex, uClickT;
      uniform vec3 uRayO, uRayD, uColor, uClick;
      varying vec3 vCol; varying float vGlow; varying float vSeed;
      vec3 hsv(float h){ return clamp(abs(mod(h*6.+vec3(0,4,2),6.)-3.)-1.,0.,1.); }
      void main(){
        vec3 p = position;
        vec3 base = mix(uColor, color, uUseTex);
        // distance to the mouse ray
        vec3 v = p - uRayO; vec3 c = uRayO + dot(v, uRayD) * uRayD;
        vec3 dir = p - c; float d = length(dir);
        float f = smoothstep(uRadius, 0.0, d) * uHover * uForce;
        vec3 nrm = dir / max(d, 1e-5); vec3 tng = cross(uRayD, nrm);
        // repel + swirl + flutter
        p += nrm * d * f * 0.9;                                   // lens bulge
        p += tng * f * 0.012 * sin(uTime * 5.0 + seed * 6.283);    // shimmer swirl
        p -= uRayD * f * (0.03 + 0.05 * seed * seed);              // sparks lift toward you
        // click shockwave
        float age = uTime - uClickT;
        float ring = abs(distance(position, uClick) - age * 0.35);
        float w = smoothstep(0.045, 0.0, ring) * exp(-age * 1.1) * step(0.0, age);
        p += normalize(position - uClick + 1e-5) * w * 0.03 - uRayD * w * 0.05;
        float g = clamp(f + w, 0.0, 1.0);
        // reddish glow: hue wobbles between crimson and ember orange
        float hue = fract(0.985 + 0.045 * sin(uTime * 1.7 + d * 45.0 + seed * 6.283));
        vec3 hot = hsv(hue) * vec3(1.5, 0.75, 0.7) + vec3(0.18, 0.02, 0.03);
        vCol = mix(base, hot, g);
        vGlow = g;
        vSeed = seed;
        vec4 mv = modelViewMatrix * vec4(p, 1.0);
        gl_PointSize = uSize * uScale / -mv.z * (1.0 + 2.2 * g * (0.6 + 0.4 * sin(uTime * 10.0 + seed * 40.0)));
        gl_Position = projectionMatrix * mv;
      }`;
const FRAG = `
      uniform sampler2D uAtlas; uniform float uAscii, uGlyphs;
      varying vec3 vCol; varying float vGlow; varying float vSeed;
      void main(){
        vec2 uv = gl_PointCoord;
        if (uAscii > 0.5) {
          // ASCII: this point shows one glyph from the sprite sheet, picked by its seed
          float gi = floor(vSeed * uGlyphs);
          float m = texture2D(uAtlas, vec2((gi + uv.x) / uGlyphs, 1.0 - uv.y)).a;
          if (m < 0.2) discard;
          gl_FragColor = vec4(vCol, m);
        } else {
          float r = length(uv - 0.5);
          if (r > 0.5) discard;
          float a = mix(1.0, smoothstep(0.5, 0.0, r), vGlow);
          gl_FragColor = vec4(vCol, a);
        }
        #include <colorspace_fragment>
      }`;

export function mountMask(container, opts = {}) {
  const o = Object.assign({
    pcdUrl: './venice_mask_rgb.pcd',
    size: 0.00343, radius: 0.07705, force: 0.816,
    textureColors: true, color: '#ffffff',
    ascii: false, glyphs: '01<>/\\#%_=+X', // ascii: draw each point as a character from `glyphs`
    background: null,          // null = transparent, or e.g. '#000000'
    autoRotate: false, controls: true, cameraZ: 1.4
  }, opts);

  const w = () => container.clientWidth || 1, h = () => container.clientHeight || 1;
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: o.background === null });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setSize(w(), h());
  renderer.domElement.style.display = 'block';
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  if (o.background !== null) scene.background = new THREE.Color(o.background);
  const camera = new THREE.PerspectiveCamera(30, w() / h(), 0.01, 40);
  camera.position.set(0, 0, o.cameraZ);

  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true; controls.enabled = o.controls;
  controls.enableZoom = false;   // don't hijack page scroll
  controls.autoRotate = o.autoRotate;

  const clock = new THREE.Clock(), raycaster = new THREE.Raycaster(), ndc = new THREE.Vector2(9, 9);
  const rayO = new THREE.Vector3(), rayD = new THREE.Vector3(0, 0, -1);
  let points, material, hover = 0, hoverTarget = 0;

  // sprite sheet for ASCII mode: one glyph per cell, white on transparent
  const glyphs = [...o.glyphs], cell = 64, atlasCv = document.createElement('canvas');
  atlasCv.width = cell * glyphs.length; atlasCv.height = cell;
  const actx = atlasCv.getContext('2d');
  actx.fillStyle = '#ffffff'; actx.font = `bold ${cell * 0.8}px ui-monospace, Consolas, monospace`;
  actx.textAlign = 'center'; actx.textBaseline = 'middle';
  glyphs.forEach((ch, i) => actx.fillText(ch, i * cell + cell / 2, cell / 2 + cell * 0.03));
  const atlas = new THREE.CanvasTexture(atlasCv);
  atlas.generateMipmaps = false; atlas.minFilter = THREE.LinearFilter; // no mipmaps: the sprite sheet isn't power-of-two

  new PCDLoader().load(o.pcdUrl, (pts) => {
    points = pts;
    points.geometry.center();
    points.geometry.rotateX(Math.PI);
    const n = points.geometry.attributes.position.count, seed = new Float32Array(n);
    for (let i = 0; i < n; i++) seed[i] = Math.random();
    points.geometry.setAttribute('seed', new THREE.BufferAttribute(seed, 1));
    material = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false, vertexColors: true,
      vertexShader: VERT, fragmentShader: FRAG,
      uniforms: {
        uTime: { value: 0 }, uSize: { value: o.size }, uScale: { value: h() / 2 },
        uRayO: { value: rayO }, uRayD: { value: rayD }, uHover: { value: 0 },
        uRadius: { value: o.radius }, uForce: { value: o.force },
        uUseTex: { value: o.textureColors ? 1 : 0 }, uColor: { value: new THREE.Color(o.color) },
        uClick: { value: new THREE.Vector3() }, uClickT: { value: -10 },
        uAtlas: { value: atlas }, uAscii: { value: o.ascii ? 1 : 0 }, uGlyphs: { value: glyphs.length }
      }
    });
    points.material = material;
    scene.add(points);
  });

  const el = renderer.domElement;
  const setNdc = (e) => { const r = el.getBoundingClientRect();
    ndc.set((e.clientX - r.left) / r.width * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1); };
  const onMove = (e) => { setNdc(e); hoverTarget = 1; };
  const onLeave = () => { hoverTarget = 0; };
  let downAt = 0;
  const onDown = () => { downAt = performance.now(); };
  const onUp = (e) => {
    if (!points || performance.now() - downAt > 250) return;
    setNdc(e);
    raycaster.params.Points.threshold = 0.01;
    raycaster.setFromCamera(ndc, camera);
    const hit = raycaster.intersectObject(points)[0];
    if (hit) { material.uniforms.uClick.value.fromBufferAttribute(points.geometry.attributes.position, hit.index);
               material.uniforms.uClickT.value = clock.elapsedTime; }
  };
  el.addEventListener('pointermove', onMove); el.addEventListener('pointerleave', onLeave);
  el.addEventListener('pointerdown', onDown); el.addEventListener('pointerup', onUp);

  const tmpO = new THREE.Vector3(), tmpD = new THREE.Vector3();
  renderer.setAnimationLoop(() => {
    controls.update();
    if (material) {
      raycaster.setFromCamera(ndc, camera);
      tmpO.copy(raycaster.ray.origin); tmpD.copy(raycaster.ray.direction);
      rayO.lerp(tmpO, 0.18); rayD.lerp(tmpD, 0.18).normalize();
      hover += (hoverTarget - hover) * 0.08;
      material.uniforms.uHover.value = hover;
      material.uniforms.uTime.value = clock.getElapsedTime();
    }
    renderer.render(scene, camera);
  });

  const ro = new ResizeObserver(() => {
    camera.aspect = w() / h(); camera.updateProjectionMatrix();
    renderer.setSize(w(), h());
    if (material) material.uniforms.uScale.value = h() / 2;
  });
  ro.observe(container);

  return {
    get material() { return material; }, controls, renderer,
    dispose() {
      renderer.setAnimationLoop(null); ro.disconnect(); controls.dispose();
      el.removeEventListener('pointermove', onMove); el.removeEventListener('pointerleave', onLeave);
      el.removeEventListener('pointerdown', onDown); el.removeEventListener('pointerup', onUp);
      if (points) { points.geometry.dispose(); material.dispose(); }
      renderer.dispose(); el.remove();
    }
  };
}
