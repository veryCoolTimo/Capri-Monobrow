export type AgentKind = 'codex' | 'claude';
export type SessionControl = 'observed' | 'tmux-controlled' | 'managed';
export type SessionState =
  | 'starting' | 'running' | 'thinking' | 'needs_input'
  | 'permission_required' | 'completed' | 'error'
  | 'rate_limited' | 'suspected_stall' | 'disconnected' | 'unknown';

export interface CapriEvent {
  id: string;
  ts: string;
  source: AgentKind | 'tmux' | 'ssh' | 'system';
  hostId: string;
  projectId?: string;
  sessionId: string;
  turnId?: string;
  state: SessionState;
  kind: string;
  summary?: string;
  requiresResponse?: boolean;
  approvalId?: string;
  confidence: 'event' | 'inferred';
}

export interface SessionSnapshot {
  sessionId: string;
  hostId: string;
  turnId?: string;
  state: SessionState;
  connected: boolean;
  approvalId?: string;
  updatedAt: string;
  /** Bounded in-memory cursor; durable deduplication belongs in SQLite in P2. */
  recentEventIds: readonly string[];
}

export interface AgentAdapter {
  readonly kind: AgentKind;
  readonly capabilities: ReadonlySet<'observe' | 'start' | 'resume' | 'interrupt' | 'approve'>;
  events(signal: AbortSignal): AsyncIterable<CapriEvent>;
}
