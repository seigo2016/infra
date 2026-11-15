-- Reconciliation dry-run on a restored Control Plane database (RFC-0001 §9:
-- bump the epoch, suspend dispatch, fence stale attempts, reconcile with the
-- Bridge journals before resuming). Everything here is rolled back.
--
-- The schema has no control-plane epoch yet, only attempts.lease_epoch, so
-- this previews the fencing of every non-terminal attempt by bumping its
-- lease_epoch, and counts the dispatch work that would be held. The Bridge
-- journal comparison needs the Bridge and is not part of this file.
\set ON_ERROR_STOP on
SELECT to_regclass('public.attempts') IS NOT NULL
   AND to_regclass('public.dispatch_intents') IS NOT NULL
   AND to_regclass('public.outbox') IS NOT NULL AS has_schema \gset
\if :has_schema
BEGIN;
WITH fenced AS (
  UPDATE attempts SET lease_epoch = lease_epoch + 1
  WHERE status IN ('created', 'dispatching', 'running', 'collecting', 'unknown', 'dispatch_uncertain')
  RETURNING status
)
SELECT jsonb_build_object(
  'schema', 'present',
  'control_plane_epoch', 'not in schema: NOT RUN',
  'attempts_fenced', (SELECT count(*) FROM fenced),
  'attempts_fenced_by_status', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                                FROM (SELECT status, count(*) AS n FROM fenced GROUP BY status) s),
  'dispatch_intents_held', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                            FROM (SELECT status, count(*) AS n FROM dispatch_intents
                                  WHERE status IN ('pending', 'sending', 'uncertain') GROUP BY status) s),
  'outbox_pending', (SELECT count(*) FROM outbox WHERE status = 'pending'),
  'committed', false
);
ROLLBACK;
\else
SELECT jsonb_build_object('schema', 'absent', 'committed', false);
\endif
