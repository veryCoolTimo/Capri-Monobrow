import type { CapriEvent, SessionSnapshot, SessionState } from '../../protocol/src/index.ts';

const priority: Record<SessionState, number> = {
  permission_required: 5, needs_input: 5, rate_limited: 4, error: 4,
  completed: 3, running: 2, thinking: 2, starting: 2,
  suspected_stall: 1, unknown: 0, disconnected: 0,
};

/** Pure transition policy. Transport, durable dedupe and expiry checks are future Core work. */
export function applyEvent(current: SessionSnapshot | undefined, event: CapriEvent): SessionSnapshot {
  if (current && (current.sessionId !== event.sessionId || current.hostId !== event.hostId)) {
    throw new Error('Event belongs to a different session or host');
  }
  if (!Number.isFinite(Date.parse(event.ts))) throw new Error('Invalid event timestamp');
  if (current?.recentEventIds.includes(event.id)) return current;
  if (current && Date.parse(event.ts) < Date.parse(current.updatedAt)) return current;
  if (current && event.kind === 'permission.resolved'
    && (!current.approvalId || event.approvalId !== current.approvalId)) return current;

  const newTurn = event.turnId !== undefined && current?.turnId !== event.turnId;
  const approvalResolved = event.kind === 'permission.resolved'
    && current?.approvalId !== undefined && event.approvalId === current.approvalId;
  const inputResolved = event.kind === 'input.resolved' && current?.state === 'needs_input';
  let state = event.state;
  if (event.state === 'disconnected') {
    state = current?.state ?? 'unknown';
  } else if (current && !newTurn && !approvalResolved && !inputResolved
    && priority[current.state] > priority[event.state]) {
    state = current.state;
  }

  const approvalId = state === 'permission_required'
    ? (event.state === 'permission_required' ? event.approvalId : current?.approvalId)
    : undefined;

  return {
    sessionId: event.sessionId, hostId: event.hostId,
    turnId: event.turnId ?? current?.turnId, state,
    connected: event.state !== 'disconnected', approvalId, updatedAt: event.ts,
    recentEventIds: [...(current?.recentEventIds ?? []), event.id].slice(-256),
  };
}
