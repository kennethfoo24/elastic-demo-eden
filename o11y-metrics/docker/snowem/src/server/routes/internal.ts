import { Router } from 'express';
import { store, SeedIncident, SeedKnowledgeArticle } from '../store.js';

const router = Router();

router.get('/_internal/incidents', (_req, res) => {
  res.json(store.getAll());
});

router.get('/_internal/incidents/:sysId', (req, res) => {
  const incident = store.get(req.params.sysId);
  if (!incident) {
    res.status(404).json({ error: 'Not found' });
    return;
  }
  res.json(incident);
});

router.get('/_internal/incidents/:sysId/journal/:field', (req, res) => {
  const { sysId, field } = req.params;
  const incident = store.get(sysId);
  if (!incident) {
    res.status(404).json({ error: 'Not found' });
    return;
  }
  res.json(store.getJournal(sysId, field));
});

router.get('/_internal/knowledge', (_req, res) => {
  res.json(store.getAllKnowledge());
});

router.get('/_internal/knowledge/:sysId', (req, res) => {
  const article = store.getKnowledgeArticle(req.params.sysId);
  if (!article) {
    res.status(404).json({ error: 'Not found' });
    return;
  }
  res.json(article);
});

router.get('/_internal/stats', (_req, res) => {
  res.json(store.getStats());
});

router.get('/_internal/activity', (req, res) => {
  const limit = parseInt(req.query.limit as string) || 50;
  res.json(store.getActivity(limit));
});

// Demo-only seed endpoint. The content-importer calls this once during
// demo-ready with the helpdesk-ticket docs (converted to Incident shape) and
// the outage-report docs (converted to KnowledgeArticle shape), so kb-*.json
// stays the single source of truth for content rather than duplicating it
// inside this image. Each array is seeded independently and idempotently —
// a no-op if that table already has rows (e.g. re-run after a restart where
// the PVC-backed data survived).
router.post('/_internal/seed', (req, res) => {
  const incidents = (req.body?.incidents ?? []) as SeedIncident[];
  const knowledgeArticles = (req.body?.knowledge_articles ?? []) as SeedKnowledgeArticle[];
  if (
    (!Array.isArray(incidents) || incidents.length === 0) &&
    (!Array.isArray(knowledgeArticles) || knowledgeArticles.length === 0)
  ) {
    res.status(400).json({ error: 'Expected a non-empty "incidents" and/or "knowledge_articles" array' });
    return;
  }
  const result: Record<string, unknown> = {};
  if (incidents.length > 0) {
    result.incidents = store.seedIfEmpty(incidents);
  }
  if (knowledgeArticles.length > 0) {
    result.knowledge_articles = store.seedKnowledgeIfEmpty(knowledgeArticles);
  }
  res.json(result);
});

export default router;
