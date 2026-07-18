import { Router, Request, Response } from 'express';
import { store } from '../store.js';

const router = Router();

const TABLE_FETCH_SIZE = 50;

// Only `incident` and `kb_knowledge` are real, listable tables. Every other
// table name the ServiceNow ingest connector probes (sys_db_object, sys_user,
// sc_req_item, change_request, ...) legitimately gets an empty/zero response
// here — the connector treats a per-table fetch error or empty table as
// "nothing to sync from this service" and moves on (see
// connectors/sources/servicenow/datasource.py: `_table_data_producer` /
// `_table_data_generator` catch and log per-table exceptions rather than
// failing the whole sync), so we don't need to emulate the full ServiceNow
// schema. `kb_knowledge` is already one of the tables the connector walks by
// default with `services: "*"` — no connector reconfiguration was needed to
// add it here.
function tableRows(table: string): unknown[] {
  if (table === 'incident') return store.getAll();
  if (table === 'kb_knowledge') return store.getAllKnowledge();
  return [];
}

function tableRowCount(table: string): number {
  return tableRows(table).length;
}

function tableSlice(table: string, offset: number, limit: number): unknown[] {
  return tableRows(table).slice(offset, offset + limit);
}

// GET /api/now/table/{table} — the ingest connector's ONLY direct (non-
// batched) call against this path is ServiceNowClient.get_table_length(),
// which sends `sysparm_limit=1` and reads the row count from the
// `x-total-count` response header (defaulting to 0 if absent — so this
// header is mandatory, not optional). It's also the endpoint `ping()` uses
// against `sys_db_object` for the connector's startup connectivity check.
// We serve a best-effort direct slice too, for manual testing / resilience,
// even though real record fetches always go through the Batch API below.
router.get('/api/now/table/:table', (req: Request, res: Response) => {
  const table = req.params.table;
  const limit = parseInt((req.query.sysparm_limit as string) || String(TABLE_FETCH_SIZE), 10);
  const offset = parseInt((req.query.sysparm_offset as string) || '0', 10);

  res.set('x-total-count', String(tableRowCount(table)));
  res.json({ result: tableSlice(table, offset, limit) });
});

interface BatchRestRequest {
  id: string;
  method: string;
  url: string;
}

interface ServicedRequest {
  id: string;
  status_code: number;
  body: string;
}

// POST /api/now/v1/batch — the ServiceNow Batch API. This is how the ingest
// connector actually fetches record and attachment data: every paginated
// table GET (and every attachment-metadata GET) is embedded as
// {id, method, url} inside `rest_requests` and expected back as
// { serviced_requests: [{ status_code, body: base64(json) }, ...] }, in the
// same order, where each decoded body is itself `{ "result": [...] }`
// (see ServiceNowClient._batch_api_call upstream). Elastic's own connector
// test fixture (tests/sources/fixtures/servicenow/fixture.py) implements
// this exact contract against a bare Flask app — this mirrors that.
router.post('/api/now/v1/batch', (req: Request, res: Response) => {
  const restRequests = (req.body?.rest_requests ?? []) as BatchRestRequest[];

  const servicedRequests: ServicedRequest[] = restRequests.map((rr) => {
    const parsed = new URL(rr.url, 'http://snowem.internal');
    const segments = parsed.pathname.split('/').filter(Boolean);
    const lastSegment = segments[segments.length - 1] ?? '';

    let result: unknown[];
    if (lastSegment === 'attachment') {
      // No attachments are emulated — an empty result is tolerated (the
      // connector just skips downloading anything for these records).
      result = [];
    } else {
      const table = lastSegment;
      const offset = parseInt(parsed.searchParams.get('sysparm_offset') ?? '0', 10);
      const limit = parseInt(parsed.searchParams.get('sysparm_limit') ?? String(TABLE_FETCH_SIZE), 10);
      result = tableSlice(table, offset, limit);
    }

    const body = Buffer.from(JSON.stringify({ result })).toString('base64');
    return { id: rr.id, status_code: 200, body };
  });

  res.json({ serviced_requests: servicedRequests });
});

export default router;
