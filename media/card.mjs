// Injected by the deterministic asset builder.
const logoURL = "__LOGO__",
  fontURL = "__FONT__";
export const message =
  "New frontiers of creativity lie before us, and we have decided to fund them because we have vision, we are bold, and we are driven.";
const hex = Array.from(new TextEncoder().encode(message), (b) =>
  b.toString(16).toUpperCase().padStart(2, "0"),
);
export const rows = Array.from({ length: 7 }, (_, i) =>
  hex.slice(i * 19, i * 19 + 19),
);

function faceMaps(T, logo, front) {
  const width = 1536,
    height = 968;
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, width, height);
  if (front) {
    const w = width * 0.76,
      h = (w * logo.height) / logo.width;
    ctx.drawImage(logo, (width - w) / 2, (height - h) / 2, w, h);
  } else {
    ctx.fillStyle = "#161616";
    ctx.font = "500 32px Plex";
    ctx.textBaseline = "middle";
    ctx.textAlign = "center";
    rows.forEach((row, i) =>
      row.forEach((pair, j) =>
        ctx.fillText(
          pair,
          width * (0.073 + (0.854 * j) / (row.length - 1)),
          height * (0.5 + (i - 3) * 0.082),
        ),
      ),
    );
  }
  const base = ctx.getImageData(0, 0, width, height).data;
  ctx.filter = "blur(2px)";
  ctx.drawImage(canvas, 0, 0);
  const bevel = ctx.getImageData(0, 0, width, height).data;
  const color = ctx.createImageData(width, height);
  const relief = ctx.createImageData(width, height);
  let seed = 71;
  function noise() {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 4294967296 - 0.5;
  }
  for (let y = 0; y < height; y++) {
    const line = noise() * 8;
    let grain = 0;
    for (let x = 0; x < width; x++) {
      const k = 4 * (y * width + x),
        mark = 1 - base[k] / 255;
      grain = grain * 0.94 + noise() * 2.4;
      const luminance = 204 - mark * 142 + line + grain;
      const depth = 60 + bevel[k] * 0.48 + line * 0.75 + grain * 0.6;
      color.data.set([luminance, luminance, luminance + 1, 255], k);
      relief.data.set([depth, depth, depth, 255], k);
    }
  }
  function texture(pixels, srgb) {
    const tex = new T.DataTexture(pixels.data, width, height);
    tex.flipY = true;
    tex.generateMipmaps = true;
    tex.minFilter = T.LinearMipmapLinearFilter;
    tex.magFilter = T.LinearFilter;
    tex.colorSpace = srgb ? T.SRGBColorSpace : T.NoColorSpace;
    tex.needsUpdate = true;
    return tex;
  }
  const bump = texture(relief, false);
  const material = new T.MeshStandardMaterial({
    map: texture(color, true),
    bumpMap: bump,
    bumpScale: front ? 0.62 : 0.09,
    roughnessMap: bump,
    roughness: 0.38,
    metalness: 0.95,
    envMapIntensity: 1.15,
  });
  // Finite studio strip lights. Intersect the reflected ray with a nearby light
  // bank so its image travels across the face even at nearly frontal angles.
  material.onBeforeCompile = (shader) => {
    shader.vertexShader =
      "varying vec3 cardWorld;\n" +
      shader.vertexShader.replace(
        "#include <worldpos_vertex>",
        "#include <worldpos_vertex>\n cardWorld=(modelMatrix*vec4(transformed,1.)).xyz;",
      );
    shader.fragmentShader =
      "varying vec3 cardWorld;\n" +
      shader.fragmentShader.replace(
        "#include <opaque_fragment>",
        `
      vec3 ray=reflect(normalize(cardWorld-cameraPosition),inverseTransformDirection(normal,viewMatrix));
      float bank=sign(ray.z)*105.;
      vec2 hit=cardWorld.xy+ray.xy*(bank-cardWorld.z)/max(abs(ray.z),0.08)*sign(ray.z);
      float axis=hit.x-.52*hit.y;
      float stripRadiance=.21 + 2.9*exp(-pow(abs(axis+27.)/11.,2.)) + 1.75*exp(-pow(abs(axis-50.)/19.,2.));
      outgoingLight=mix(outgoingLight,diffuseColor.rgb*stripRadiance,.82*smoothstep(.08,.45,abs(ray.z)));
      #include <opaque_fragment>`,
      );
  };
  return material;
}

// Four concentric rounded profiles form the two bevels and the continuous thin rim.
function body(T, materials) {
  const positions = [],
    uv = [],
    indices = [],
    groups = [];
  function vertex(x, y, z, back = false) {
    positions.push(x, y, z);
    uv.push(0.5 + (back ? -x : x) / 85.6, 0.5 + y / 53.98);
    return positions.length / 3 - 1;
  }
  function ring(inset, z, back = false) {
    const result = [],
      radius = 3.18 - inset;
    for (let q = 0; q < 4; q++)
      for (let j = 0; j <= 12; j++) {
        const a = ((q + j / 12) * Math.PI) / 2;
        const x =
          (q === 0 || q === 3 ? 1 : -1) * (42.8 - 3.18) + Math.cos(a) * radius;
        const y = (q < 2 ? 1 : -1) * (26.99 - 3.18) + Math.sin(a) * radius;
        result.push(vertex(x, y, z, back));
      }
    return result;
  }
  for (const back of [false, true]) {
    const start = indices.length,
      z = back ? -0.4 : 0.4,
      r = ring(0.14, z, back),
      c = vertex(0, 0, z, back);
    r.forEach((p, i) => {
      const n = r[(i + 1) % r.length];
      indices.push(c, back ? n : p, back ? p : n);
    });
    groups.push([start, indices.length - start, back ? 1 : 0]);
  }
  const rings = [
      ring(0.14, -0.4),
      ring(0, -0.26),
      ring(0, 0.26),
      ring(0.14, 0.4),
    ],
    start = indices.length;
  for (let j = 0; j < 3; j++)
    rings[j].forEach((a, i) => {
      const n = (i + 1) % rings[j].length,
        b = rings[j][n],
        c = rings[j + 1][n],
        d = rings[j + 1][i];
      indices.push(a, b, d, b, c, d);
    });
  const g = new T.BufferGeometry();
  g.setAttribute("position", new T.Float32BufferAttribute(positions, 3));
  g.setAttribute("uv", new T.Float32BufferAttribute(uv, 2));
  g.setIndex(indices);
  groups.push([start, indices.length - start, 2]);
  groups.forEach((args) => g.addGroup(...args));
  g.computeVertexNormals();
  return new T.Mesh(g, materials);
}

function studio(T, renderer) {
  const room = new T.Scene();
  room.background = new T.Color(0.19, 0.19, 0.2);
  const panels = [
    [13, 10, 82, 14, 155, 3.6, -0.64],
    [-30, 3, 80, 19, 135, 1.75, -0.64],
    [-82, 15, 28, 28, 130, 3.6, -0.25],
    [67, -12, 42, 23, 105, 2.5, 0.5],
    [10, 8, -75, 18, 143, 3.3, 0.57],
    [50, -34, -54, 28, 95, 3.3, 0.5],
    [-25, -55, 50, 130, 27, 0.06, 0.25],
  ];
  for (const [x, y, z, w, h, p, roll] of panels) {
    const mesh = new T.Mesh(
      new T.PlaneGeometry(w, h),
      new T.MeshBasicMaterial({ color: new T.Color(p, p, p) }),
    );
    mesh.position.set(x, y, z);
    mesh.lookAt(0, 0, 0);
    mesh.rotateZ(roll);
    room.add(mesh);
  }
  const pmrem = new T.PMREMGenerator(renderer),
    env = pmrem.fromScene(room, 0.05, 0.1, 300);
  pmrem.dispose();
  room.traverse((o) => {
    o.geometry?.dispose();
    o.material?.dispose();
  });
  return env;
}
const ease = (u) => u * u * (3 - 2 * u);
function turn(t) {
  const s = t % 24;
  return (
    Math.PI *
    (s < 2
      ? 0
      : s < 12
        ? ease((s - 2) / 10)
        : s < 14
          ? 1
          : 1 + ease((s - 14) / 10))
  );
}
export async function mount(T) {
  const font = new FontFace("Plex", "url(" + fontURL + ")", { weight: "500" });
  const logo = new Image();
  logo.src = logoURL;
  await Promise.all([logo.decode(), font.load()]);
  document.fonts.add(font);
  const renderer = new T.WebGLRenderer({
    antialias: true,
    alpha: true,
    preserveDrawingBuffer: true,
  });
  renderer.debug.onShaderError = () => {
    throw Error("Card material could not compile");
  };
  renderer.setClearColor(0, 0);
  renderer.toneMapping = T.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1;
  const scene = new T.Scene(),
    env = studio(T, renderer);
  scene.environment = env.texture;
  const card = body(T, [
    faceMaps(T, logo, true),
    faceMaps(T, logo, false),
    new T.MeshStandardMaterial({
      color: 0xe5e5e6,
      metalness: 1,
      roughness: 0.15,
    }),
  ]);
  scene.add(card);
  const cam = new T.PerspectiveCamera(30, 1, 0.1, 400);
  const canvas = renderer.domElement;
  canvas.tabIndex = 0;
  canvas.setAttribute(
    "aria-label",
    "Rotating Industrial Imagination card. Drag or use arrow keys to inspect. Space pauses. Home resets.",
  );
  document.body.append(canvas);
  const motion = matchMedia("(prefers-reduced-motion: reduce)");
  let phase = 0,
    offset = 0,
    pitch = 0,
    idle = 0,
    paused = false,
    pointer = null,
    last = 0,
    raf = 0,
    lost = false;
  function resize() {
    const w = innerWidth,
      h = innerHeight;
    renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
    renderer.setSize(w, h);
    cam.aspect = w / h;
    cam.position.z =
      Math.max(74, 103 / cam.aspect) / (2 * Math.tan(Math.PI / 12));
    cam.updateProjectionMatrix();
  }
  function draw() {
    card.rotation.set(0.12 + pitch, turn(phase) + offset, -0.018, "YXZ");
    renderer.render(scene, cam);
  }
  function tick(now) {
    raf = 0;
    if (document.hidden || lost) return;
    const dt = last ? Math.min((now - last) / 1000, 0.1) : 0;
    last = now;
    if (idle > 0) idle = Math.max(0, idle - dt);
    else if (!paused && !motion.matches && pointer === null) {
      phase = (phase + dt) % 24;
      offset =
        Math.atan2(Math.sin(offset), Math.cos(offset)) * Math.exp(-1.5 * dt);
      pitch *= Math.exp(-1.5 * dt);
    }
    draw();
    raf = requestAnimationFrame(tick);
  }
  function restart() {
    cancelAnimationFrame(raf);
    last = 0;
    if (!document.hidden && !lost) raf = requestAnimationFrame(tick);
  }
  canvas.onpointerdown = (e) => {
    if (pointer) return;
    canvas.focus();
    canvas.setPointerCapture(e.pointerId);
    pointer = { id: e.pointerId, x: e.clientX, y: e.clientY };
  };
  canvas.onpointermove = (e) => {
    if (!pointer || e.pointerId !== pointer.id) return;
    offset += (e.clientX - pointer.x) * 0.012;
    pitch = Math.max(
      -Math.PI / 6,
      Math.min(Math.PI / 6, pitch + (e.clientY - pointer.y) * 0.009),
    );
    pointer.x = e.clientX;
    pointer.y = e.clientY;
  };
  canvas.onlostpointercapture = () => {
    pointer = null;
    idle = 4;
  };
  canvas.onkeydown = (e) => {
    if (
      ![
        "ArrowLeft",
        "ArrowRight",
        "ArrowUp",
        "ArrowDown",
        " ",
        "Home",
      ].includes(e.key)
    )
      return;
    e.preventDefault();
    idle = 4;
    if (e.key === " ") paused = !paused;
    if (e.key === "Home") {
      phase = offset = pitch = 0;
      paused = false;
    }
    if (e.key === "ArrowLeft") offset -= Math.PI / 12;
    if (e.key === "ArrowRight") offset += Math.PI / 12;
    if (e.key === "ArrowUp") pitch = Math.max(-Math.PI / 6, pitch - 0.08);
    if (e.key === "ArrowDown") pitch = Math.min(Math.PI / 6, pitch + 0.08);
  };
  canvas.addEventListener("webglcontextlost", (e) => {
    e.preventDefault();
    lost = true;
    cancelAnimationFrame(raf);
    canvas.hidden = true;
    document.body.dataset.state = "fallback";
  });
  canvas.addEventListener("webglcontextrestored", () => {
    location.reload();
  });
  addEventListener("resize", resize);
  document.addEventListener("visibilitychange", restart);
  resize();
  draw();
  document.body.dataset.state = "ready";
  restart();
  return {
    seek(t) {
      paused = true;
      phase = t;
      offset = pitch = 0;
      draw();
    },
    state() {
      return {
        phase,
        offset,
        pitch,
        idle,
        paused,
        hidden: document.hidden,
        lost,
        revision: T.REVISION,
        angle: card.rotation.y,
      };
    },
  };
}
