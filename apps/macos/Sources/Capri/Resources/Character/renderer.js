/* The host owns geometry, clicks and lifecycle. This renderer has no network access. */
(() => {
  const canvas = document.getElementById('sprite');
  const notify = value => window.webkit?.messageHandlers?.capri?.postMessage(value);
  let renderer, state = 'idle', paused = false, reduced = false;
  let frameTimer, stateAt = performance.now();
  let frameCount = 0;

  const pose = {
    seed: 0, boil: 0.3, hair: 0, head: 0, mane: 0, armL: 0, armR: 0,
    longL: 1, longR: 1, sit: 0, kickL: 0, kickR: 0,
    smear: [0, 0], echo: [0, 0], glitch: 0, glitchSeed: 0, split: 0,
    collapse: 0, dissolve: 0, sparkle: 0.65, grade: 1,
    sil: [0.08, 0.06, 0.11], silAmount: 0, misreg: [-1.6, 1.2], alpha: 1,
  };

  function draw() {
    if (!renderer) return;
    const elapsed = (performance.now() - stateAt) / 1000;
    const t = (paused || reduced) ? 0 : performance.now() / 1000;
    Object.assign(pose, {
      seed: Math.floor(t * 12), head: Math.sin(t * 1.4) * 0.025,
      hair: Math.sin(t * 1.6) * 2, mane: Math.sin(t * 1.4) * 0.025,
      armL: 0.025 * Math.sin(t), armR: 0.025 * Math.cos(t),
      glitch: 0, split: 0, collapse: 0, dissolve: 0, alpha: 1, sit: 0,
    });
    if (state === 'thinking') { pose.head += 0.1; pose.mane = 0.08; }
    if (state === 'working') { pose.armL = 0.1; pose.mane = 0.06; }
    if (state === 'approval') { pose.head -= 0.08; pose.mane = 0.16; pose.armR = 0.35; }
    if (state === 'success') { pose.armL = 0.5; pose.armR = 0.5; pose.mane = 0.2; }
    if (state === 'sleep') { pose.head = 0.15; pose.mane = -0.12; pose.armL = -0.2; pose.armR = -0.2; }
    if (state === 'error') { pose.head = -0.12; pose.mane = 0.2; pose.glitch = reduced ? 0 : 0.15; }
    if (state === 'teleport' && !reduced) {
      const strength = Math.max(0, 1 - Math.abs(elapsed - 0.3) / 0.3);
      pose.collapse = strength * 0.99;
      pose.dissolve = strength * 0.5;
      pose.glitch = strength * 0.8;
      pose.glitchSeed = Math.floor(elapsed * 24);
      pose.split = strength * 7;
    }
    if (state === 'teleport' && elapsed >= 0.65) state = 'idle';
    renderer.draw(pose);
    frameCount++;
  }

  function schedule() {
    clearInterval(frameTimer);
    draw();
    // No requestAnimationFrame at 60/120 Hz: the sprite is drawn on twos at 12 fps.
    if (!paused && !reduced) frameTimer = setInterval(draw, state === 'sleep' ? 250 : 1000 / 12);
  }

  window.capri = {
    setState(value) {
      if (!['idle', 'teleport', 'thinking', 'working', 'approval', 'success', 'error', 'sleep'].includes(value)) return;
      state = value; stateAt = performance.now(); schedule();
      notify({ kind: 'state', state });
    },
    configure(options) {
      paused = !!options.paused; reduced = !!options.reducedMotion;
      if (renderer) renderer.resize(innerWidth / 352);
      schedule();
    },
    diagnostics() { return { state, paused, reducedMotion: reduced, frameCount, webgl: !!renderer }; },
  };

  const image = new Image();
  image.onload = () => {
    try {
      renderer = new SpriteRenderer(canvas, image);
      renderer.resize(innerWidth / 352);
      schedule();
      notify({ kind: 'ready', webgl: true, width: canvas.width, height: canvas.height });
    } catch (error) {
      canvas.hidden = true;
      document.getElementById('fallback').hidden = false;
      notify({ kind: 'error', message: String(error), fallback: true });
    }
  };
  image.onerror = () => notify({ kind: 'error', message: 'Character texture could not load' });
  image.src = window.CAPRI_TEXTURE || 'capri-full.png';
  addEventListener('resize', () => { if (renderer) renderer.resize(innerWidth / 352); draw(); });
  canvas.addEventListener('webglcontextrestored', () => { schedule(); notify({ kind: 'restored' }); });
})();
