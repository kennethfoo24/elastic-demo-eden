# SNOW ITSM Emulator (vendored + extended)

Vendored from `utils/snowem/` in
[`ty-elastic/instruqt_o11y--course--field--100-e2e--main`](https://github.com/ty-elastic/instruqt_o11y--course--field--100-e2e--main),
which built this purpose-built for demoing Elastic's **outbound** `.servicenow`
action connector (pushing Cases/alerts into ServiceNow as incidents). That
integration is unchanged here — see `src/server/routes/importSet.ts` and
`src/server/routes/table.ts` (the `/api/now/v2/table/incident...` routes).

## What's different from upstream

o11y-metrics also uses this emulator as a source for the **native Elastic
ServiceNow ingest connector** (self-managed `elastic-connectors`,
`service_type: servicenow`), which needs a different, additional API surface
than the outbound connector does. Two changes support that:

1. **Persistence** (`src/server/store.ts`) — upstream keeps incidents in an
   in-memory `Map` that resets on every restart. Here it's backed by
   `better-sqlite3` on a file (`SNOWEM_DB_PATH`, default `/data/snowem.db`),
   meant to be mounted on a PVC — so seeded tickets/articles and any incidents
   pushed in later by the outbound connector all survive pod restarts.
2. **Ingest API** (`src/server/routes/ingestTable.ts`, new file) —
   implements `GET /api/now/table/{table}` with an `x-total-count` response
   header, and `POST /api/now/v1/batch` (ServiceNow's Batch API), which is
   how the ingest connector actually fetches record data. See the comments
   in that file for the exact contract, reverse-engineered from
   `elastic/connectors`' `connectors/sources/servicenow/{client,datasource}.py`
   and cross-checked against that same repo's own fake-ServiceNow test
   fixture (`tests/sources/fixtures/servicenow/fixture.py`).
3. **A `kb_knowledge` table** (`src/server/store.ts`, `KnowledgeArticle`) —
   real ServiceNow keeps Knowledge Base articles (post-incident reviews,
   runbooks, ...) in a separate table from Incident, with a `text` body field
   instead of `description`. Modeling outage reports as another `incident`
   row was an earlier, less accurate simplification — they're seeded here
   instead. The ingest connector already walks `kb_knowledge` by default
   with `services: "*"`, so no connector config change was needed.

Only `incident` and `kb_knowledge` are populated; every other table the
connector probes (`sys_db_object`, `sys_user`, `sc_req_item`,
`change_request`, ...) returns an empty, well-formed response, which the
connector treats as "nothing to sync from this service" and skips — no need
to emulate ServiceNow's full schema.

A new `POST /_internal/seed` endpoint (in `src/server/routes/internal.ts`)
lets the content-importer push seed incidents and knowledge articles in at
demo-ready time, converted from `kb-helpdesk-tickets.json` (incidents) and
`kb-outage-reports.json` (knowledge articles) respectively
(`docker/content-importer/ecat/content/servicenow.py`). Each table seeds
idempotently — a no-op once it already has rows — so kb-*.json stays the
single source of truth for content and this image stays content-agnostic.

The portal UI (`src/client/`) gained a "Knowledge Base" nav section
(`pages/KnowledgeList.tsx`, `pages/KnowledgeDetail.tsx`) alongside the
existing Incidents section, so the two tables are visually distinguishable —
not just an internal `demo_category` field.

Everything else (the outbound connector's Import Set/health/sys_dictionary/
sys_choice routes, TLS cert generation) is unmodified from upstream.
