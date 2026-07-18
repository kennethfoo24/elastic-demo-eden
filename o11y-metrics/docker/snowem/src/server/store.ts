import { v4 as uuidv4 } from 'uuid';
import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';

export interface JournalEntry {
  value: string;
  created_on: string;
  created_by: string;
}

export interface Incident {
  sys_id: string;
  number: string;
  short_description: string;
  description: string;
  state: string;
  impact: string;
  urgency: string;
  priority: string;
  severity: string;
  category: string;
  subcategory: string;
  assignment_group: string;
  assigned_to: string;
  caller_id: string;
  opened_by: string;
  correlation_id: string;
  correlation_display: string;
  close_code: string;
  close_notes: string;
  work_notes: string;
  comments: string;
  sys_created_on: string;
  sys_updated_on: string;
  sys_created_by: string;
  sys_updated_by: string;
  active: string;
  [key: string]: string;
}

export interface ActivityEntry {
  id: string;
  timestamp: string;
  method: string;
  path: string;
  status: number;
  body?: unknown;
  response?: unknown;
}

// Real ServiceNow keeps Knowledge Base articles (post-incident reviews,
// runbooks, etc.) in a separate `kb_knowledge` table from Incident — NOT as
// another incident row. `text` is the article body (ServiceNow's real field
// name for it, distinct from Incident's `description`); `short_description`
// doubles as the title field on both tables, matching real ServiceNow.
export interface KnowledgeArticle {
  sys_id: string;
  number: string;
  short_description: string;
  text: string;
  workflow_state: string; // "published" | "draft"
  sys_created_on: string;
  sys_updated_on: string;
  sys_created_by: string;
  sys_updated_by: string;
  [key: string]: string;
}

// Shape accepted by seedIfEmpty(). Only sys_id is mandatory — everything
// else falls back to defaultIncident()'s values. Callers (the content-
// importer's snowem seed step) are free to attach arbitrary extra keys
// (e.g. `category`, `doc_id`, `tags`) beyond the strict Incident fields;
// they ride along on the record and flow straight through to the
// Elasticsearch document once the ServiceNow ingest connector syncs it,
// since the connector keeps every truthy key it sees (see
// connectors/sources/servicenow/datasource.py::_format_doc upstream).
export type SeedIncident = Partial<Incident> & { sys_id: string };
export type SeedKnowledgeArticle = Partial<KnowledgeArticle> & { sys_id: string };

const JOURNAL_FIELDS = new Set(['work_notes', 'comments']);

// Persisted on a PVC (mounted at /data by default) so seeded tickets AND any
// incidents pushed in later by the outbound `.servicenow` action connector
// survive pod restarts — a plain in-memory Map (the upstream emulator's
// original design) resets on every restart, which doesn't work for a
// long-lived ingest source. Override with SNOWEM_DB_PATH for local dev.
const DB_PATH = process.env.SNOWEM_DB_PATH || path.resolve(process.cwd(), 'data/snowem.db');

function nowTimestamp(): string {
  // toISOString() includes milliseconds ("...48.449Z"), which the
  // servicenow index's sys_created_on/sys_updated_on date mapping
  // (yyyy-MM-dd HH:mm:ss||yyyy-MM-dd'T'HH:mm:ss'Z'||epoch_millis) can't
  // parse — any incident touched by store.create()/update() (i.e. every
  // push from the outbound .servicenow connector, or any live update)
  // failed the ingest connector's bulk index with a document_parsing_exception,
  // silently dropping it from the servicenow index. Truncate to seconds.
  return new Date().toISOString().slice(0, 19).replace('T', ' ');
}

function defaultIncident(): Incident {
  return {
    sys_id: '',
    number: '',
    short_description: '',
    description: '',
    state: '1',
    impact: '3',
    urgency: '3',
    // Real ServiceNow computes priority from impact x urgency server-side;
    // this emulator doesn't implement that matrix, and Kibana's case-push
    // connector never sends a priority field directly (see the demo's own
    // findings on this), so new incidents just take this hardcoded default.
    priority: '1',
    severity: '3',
    category: '',
    subcategory: '',
    assignment_group: '',
    assigned_to: '',
    caller_id: '',
    opened_by: '',
    correlation_id: '',
    correlation_display: '',
    close_code: '',
    close_notes: '',
    work_notes: '',
    comments: '',
    sys_created_on: '',
    sys_updated_on: '',
    sys_created_by: 'system',
    sys_updated_by: 'system',
    active: 'true',
  };
}

function defaultKnowledgeArticle(): KnowledgeArticle {
  return {
    sys_id: '',
    number: '',
    short_description: '',
    text: '',
    workflow_state: 'published',
    sys_created_on: '',
    sys_updated_on: '',
    sys_created_by: 'system',
    sys_updated_by: 'system',
  };
}

interface IncidentRow {
  data: string;
}

interface KnowledgeRow {
  data: string;
}

class IncidentStore {
  private db: Database.Database;
  private nextNumber: number;
  private nextKbNumber: number;
  // The live activity feed is intentionally NOT persisted — it's a
  // debugging/demo aid (Activity Log tab), not ticket data, so it's fine
  // for it to reset on restart.
  private activityLog: ActivityEntry[] = [];
  private maxActivity = 500;

  constructor(dbPath: string) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS incidents (
        sys_id TEXT PRIMARY KEY,
        correlation_id TEXT,
        sys_created_on TEXT,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_incidents_correlation_id ON incidents(correlation_id);
      CREATE TABLE IF NOT EXISTS journal_entries (
        sys_id TEXT NOT NULL,
        field TEXT NOT NULL,
        seq INTEGER NOT NULL,
        value TEXT NOT NULL,
        created_on TEXT NOT NULL,
        created_by TEXT NOT NULL,
        PRIMARY KEY (sys_id, field, seq)
      );
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS knowledge_articles (
        sys_id TEXT PRIMARY KEY,
        sys_created_on TEXT,
        data TEXT NOT NULL
      );
    `);
    this.nextNumber = this.loadNextNumber('next_number', 10001);
    this.nextKbNumber = this.loadNextNumber('next_kb_number', 1001);
  }

  private loadNextNumber(key: string, fallback: number): number {
    const row = this.db.prepare('SELECT value FROM meta WHERE key = ?').get(key) as { value: string } | undefined;
    return row ? parseInt(row.value, 10) : fallback;
  }

  private saveNextNumber(key: string, n: number) {
    this.db
      .prepare(
        `INSERT INTO meta (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`
      )
      .run(key, String(n));
  }

  generateNumber(): string {
    const num = this.nextNumber++;
    this.saveNextNumber('next_number', this.nextNumber);
    return `INC${String(num).padStart(7, '0')}`;
  }

  generateKbNumber(): string {
    const num = this.nextKbNumber++;
    this.saveNextNumber('next_kb_number', this.nextKbNumber);
    return `KB${String(num).padStart(7, '0')}`;
  }

  private upsert(incident: Incident) {
    this.db
      .prepare(
        `INSERT INTO incidents (sys_id, correlation_id, sys_created_on, data)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(sys_id) DO UPDATE SET
           correlation_id = excluded.correlation_id,
           sys_created_on = excluded.sys_created_on,
           data = excluded.data`
      )
      .run(incident.sys_id, incident.correlation_id || null, incident.sys_created_on, JSON.stringify(incident));
  }

  private appendJournal(sysId: string, field: string, value: string, createdBy: string, createdOn: string) {
    const row = this.db
      .prepare('SELECT COALESCE(MAX(seq), -1) as maxSeq FROM journal_entries WHERE sys_id = ? AND field = ?')
      .get(sysId, field) as { maxSeq: number };
    this.db
      .prepare(
        'INSERT INTO journal_entries (sys_id, field, seq, value, created_on, created_by) VALUES (?, ?, ?, ?, ?, ?)'
      )
      .run(sysId, field, row.maxSeq + 1, value, createdOn, createdBy);
  }

  // Accepts an optional caller-supplied sys_id/number/timestamps (used by
  // the seed path, so seeded incidents keep stable, human-readable
  // identifiers like "INC0048213" and their original historical dates
  // instead of a random uuid + "now"). Falls back to upstream's original
  // auto-generated behavior when those aren't provided.
  create(fields: Partial<Incident>): Incident {
    const now = nowTimestamp();
    const sysId = fields.sys_id || uuidv4();
    const incident: Incident = {
      ...defaultIncident(),
      ...fields,
      sys_id: sysId,
      number: fields.number || this.generateNumber(),
      sys_created_on: fields.sys_created_on || now,
      sys_updated_on: fields.sys_updated_on || now,
      active: fields.active || 'true',
    };

    for (const field of JOURNAL_FIELDS) {
      if (incident[field]) {
        this.appendJournal(sysId, field, incident[field], incident.sys_created_by || 'system', incident.sys_created_on);
      }
    }

    this.upsert(incident);
    return incident;
  }

  update(sysId: string, fields: Partial<Incident>): Incident | null {
    const existing = this.get(sysId);
    if (!existing) return null;

    const now = nowTimestamp();

    // Handle journal fields: append rather than overwrite
    for (const field of JOURNAL_FIELDS) {
      const value = fields[field];
      if (value && value.trim()) {
        this.appendJournal(sysId, field, value, fields.sys_updated_by || existing.sys_updated_by || 'system', now);
      }
    }

    const updated: Incident = {
      ...existing,
      ...fields,
      sys_id: existing.sys_id,
      number: existing.number,
      sys_created_on: existing.sys_created_on,
      sys_updated_on: now,
    };

    if (updated.state === '7') {
      updated.active = 'false';
    }

    this.upsert(updated);
    return updated;
  }

  get(sysId: string): Incident | null {
    const row = this.db.prepare('SELECT data FROM incidents WHERE sys_id = ?').get(sysId) as IncidentRow | undefined;
    return row ? (JSON.parse(row.data) as Incident) : null;
  }

  getJournal(sysId: string, field: string): JournalEntry[] {
    return this.db
      .prepare('SELECT value, created_on, created_by FROM journal_entries WHERE sys_id = ? AND field = ? ORDER BY seq ASC')
      .all(sysId, field) as JournalEntry[];
  }

  findByCorrelationId(correlationId: string): Incident | null {
    const row = this.db
      .prepare('SELECT data FROM incidents WHERE correlation_id = ? ORDER BY sys_created_on DESC LIMIT 1')
      .get(correlationId) as IncidentRow | undefined;
    return row ? (JSON.parse(row.data) as Incident) : null;
  }

  findByQuery(query: string): Incident[] {
    if (query.includes('correlation_id=')) {
      const match = query.match(/correlation_id=([^&^]+)/);
      if (match) {
        const incident = this.findByCorrelationId(match[1]);
        return incident ? [incident] : [];
      }
    }
    return this.getAll();
  }

  getAll(): Incident[] {
    const rows = this.db.prepare('SELECT data FROM incidents ORDER BY sys_created_on DESC').all() as IncidentRow[];
    return rows.map((r) => JSON.parse(r.data) as Incident);
  }

  getStats() {
    const all = this.getAll();
    const open = all.filter((i) => i.active === 'true').length;
    const closed = all.filter((i) => i.active === 'false').length;
    return { total: all.length, open, closed };
  }

  // Idempotent: no-ops if the incidents table already has any rows, so a
  // retried demo-ready/setup script (or a pod restart after seeding already
  // happened) never duplicates data. Called via POST /_internal/seed by the
  // content-importer, which is the source of truth for the seed content
  // (kb-helpdesk-tickets.json) — snowem itself stays a dumb, content-agnostic
  // store.
  seedIfEmpty(records: SeedIncident[]): { seeded: boolean; count: number } {
    const { count } = this.db.prepare('SELECT COUNT(*) as count FROM incidents').get() as { count: number };
    if (count > 0) {
      return { seeded: false, count };
    }
    for (const record of records) {
      this.create(record);
    }
    return { seeded: true, count: records.length };
  }

  // --- kb_knowledge (Knowledge Base articles) ---
  // Deliberately separate from incidents: real ServiceNow keeps these in
  // their own table (see the KnowledgeArticle doc comment above), and the
  // ingest connector already walks `kb_knowledge` by default alongside
  // `incident` when configured with `services: "*"` — no connector
  // reconfiguration needed for this table to start syncing.

  private upsertKnowledge(article: KnowledgeArticle) {
    this.db
      .prepare(
        `INSERT INTO knowledge_articles (sys_id, sys_created_on, data)
         VALUES (?, ?, ?)
         ON CONFLICT(sys_id) DO UPDATE SET
           sys_created_on = excluded.sys_created_on,
           data = excluded.data`
      )
      .run(article.sys_id, article.sys_created_on, JSON.stringify(article));
  }

  createKnowledgeArticle(fields: Partial<KnowledgeArticle>): KnowledgeArticle {
    const now = nowTimestamp();
    const sysId = fields.sys_id || uuidv4();
    const article: KnowledgeArticle = {
      ...defaultKnowledgeArticle(),
      ...fields,
      sys_id: sysId,
      number: fields.number || this.generateKbNumber(),
      sys_created_on: fields.sys_created_on || now,
      sys_updated_on: fields.sys_updated_on || now,
    };
    this.upsertKnowledge(article);
    return article;
  }

  getKnowledgeArticle(sysId: string): KnowledgeArticle | null {
    const row = this.db
      .prepare('SELECT data FROM knowledge_articles WHERE sys_id = ?')
      .get(sysId) as KnowledgeRow | undefined;
    return row ? (JSON.parse(row.data) as KnowledgeArticle) : null;
  }

  getAllKnowledge(): KnowledgeArticle[] {
    const rows = this.db
      .prepare('SELECT data FROM knowledge_articles ORDER BY sys_created_on DESC')
      .all() as KnowledgeRow[];
    return rows.map((r) => JSON.parse(r.data) as KnowledgeArticle);
  }

  // Idempotent, same rationale as seedIfEmpty() above. Source content is
  // kb-outage-reports.json (post-incident reviews), converted to
  // KnowledgeArticle shape by the content-importer's servicenow.py.
  seedKnowledgeIfEmpty(records: SeedKnowledgeArticle[]): { seeded: boolean; count: number } {
    const { count } = this.db.prepare('SELECT COUNT(*) as count FROM knowledge_articles').get() as { count: number };
    if (count > 0) {
      return { seeded: false, count };
    }
    for (const record of records) {
      this.createKnowledgeArticle(record);
    }
    return { seeded: true, count: records.length };
  }

  logActivity(entry: Omit<ActivityEntry, 'id' | 'timestamp'>) {
    this.activityLog.unshift({
      ...entry,
      id: uuidv4(),
      timestamp: new Date().toISOString(),
    });
    if (this.activityLog.length > this.maxActivity) {
      this.activityLog = this.activityLog.slice(0, this.maxActivity);
    }
  }

  getActivity(limit = 50): ActivityEntry[] {
    return this.activityLog.slice(0, limit);
  }
}

export const store = new IncidentStore(DB_PATH);
