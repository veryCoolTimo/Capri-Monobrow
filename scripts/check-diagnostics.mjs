import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const directory = resolve(process.argv[2] ?? 'docs/preview');
const native = JSON.parse(await readFile(resolve(directory, 'native.json'), 'utf8'));
const renderer = JSON.parse(await readFile(resolve(directory, 'renderer.json'), 'utf8'));
assert.equal(renderer.webgl, true, 'A real WebGL renderer must be ready');
assert.ok(renderer.frameCount > 1, 'The character must draw multiple frames');
assert.equal(native.panelCanBecomeKey, false, 'The overlay must not take keyboard focus');
assert.notEqual(native.transparentHitWindow, native.panelWindow, 'A transparent corner must pass through the native input window');
assert.notEqual(native.transparentHitWindow, native.rendererWindow, 'The renderer must never intercept background clicks');
assert.equal(native.opaqueHitWindow, native.panelWindow, 'The character body must hit the native input window');
console.log('PASS: WebGL animation, non-key overlay, transparent corner pass-through, opaque body hit');
