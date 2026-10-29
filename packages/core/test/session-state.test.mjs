import test from 'node:test';
import assert from 'node:assert/strict';
import { applyEvent } from '../src/session-state.ts';

const event = (extra = {}) => ({
  id: 'e1', ts: '2026-10-27T10:00:00Z', source: 'codex', hostId: 'local',
  sessionId: 's1', turnId: 't1', state: 'running', kind: 'lifecycle', confidence: 'event',
  ...extra,
});

test('duplicate IDs do not change session status', () => {
  const first = applyEvent(undefined, event());
  assert.deepEqual(applyEvent(first, event({ state: 'error' })), first);
});

test('disconnect preserves a completed turn and marks connection offline', () => {
  const done = applyEvent(undefined, event({ state: 'completed' }));
  const next = applyEvent(done, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state: 'disconnected' }));
  assert.equal(next.state, 'completed');
  assert.equal(next.connected, false);
});

test('a tool event cannot dismiss a pending approval', () => {
  const pending = applyEvent(undefined, event({ state: 'permission_required', approvalId: 'a1', requiresResponse: true }));
  const next = applyEvent(pending, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state: 'running', kind: 'tool' }));
  assert.equal(next.state, 'permission_required');
  assert.equal(next.approvalId, 'a1');
});

test('explicit resolution clears an approval for the same request', () => {
  const pending = applyEvent(undefined, event({ state: 'permission_required', approvalId: 'a1', requiresResponse: true }));
  const next = applyEvent(pending, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state: 'running', kind: 'permission.resolved', approvalId: 'a1' }));
  assert.equal(next.state, 'running');
  assert.equal(next.approvalId, undefined);
});

test('a new turn may run after completion', () => {
  const done = applyEvent(undefined, event({ state: 'completed' }));
  const next = applyEvent(done, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state: 'running', turnId: 't2' }));
  assert.equal(next.state, 'running');
  assert.equal(next.turnId, 't2');
});

test('stale events cannot regress a newer state', () => {
  const done = applyEvent(undefined, event({ ts: '2026-10-27T10:02:00Z', state: 'completed' }));
  assert.deepEqual(applyEvent(done, event({ id: 'e0', ts: '2026-10-27T09:59:00Z' })), done);
});

test('events from another session cannot contaminate a snapshot', () => {
  const first = applyEvent(undefined, event());
  assert.throws(() => applyEvent(first, event({ id: 'e2', sessionId: 'other' })), /session/i);
});

test('a mismatched approval resolution does not release the active request', () => {
  const pending = applyEvent(undefined, event({ state: 'permission_required', approvalId: 'a1', requiresResponse: true }));
  const next = applyEvent(pending, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state: 'running', kind: 'permission.resolved', approvalId: 'wrong' }));
  assert.equal(next.state, 'permission_required');
  assert.equal(next.approvalId, 'a1');
});

for (const state of ['needs_input', 'permission_required']) {
  test(`a mismatched approval resolution cannot change equal-priority state ${state}`, () => {
    const pending = applyEvent(undefined, event({ state: 'permission_required', approvalId: 'a1', requiresResponse: true }));
    const next = applyEvent(pending, event({ id: 'e2', ts: '2026-10-27T10:01:00Z', state, kind: 'permission.resolved', approvalId: 'wrong' }));
    assert.deepEqual(next, pending);
  });
}
