-- Reconciliation dry-run on a restored Control Plane database (RFC-0001 §9:
-- raise the epoch, suspend dispatch, refuse reports from earlier work, reconcile
-- with the Bridge journals before resuming). Everything here is rolled back.
--
-- Raising control_plane.epoch makes every attempt that has not finished unable
-- to report until it is reconciled; this counts them and the dispatch work that
-- would be held. The Bridge journal comparison needs the Bridge and is not part
-- of this file.
\set ON_ERROR_STOP on
SELECT to_regclass('public.attempts') IS NOT NULL
   AND to_regclass('public.dispatch_intents') IS NOT NULL
   AND to_regclass('public.outbox') IS NOT NULL AS has_schema,
       to_regclass('public.control_plane') IS NOT NULL AS has_epoch \gset
\if :has_schema
BEGIN;
\if :has_epoch
UPDATE control_plane SET epoch = epoch + 1 RETURNING to_jsonb(epoch) AS epoch_after \gset
\else
SELECT to_jsonb('not in schema: NOT RUN'::text) AS epoch_after \gset
\endif
SELECT jsonb_build_object(
  'schema', 'present',
  'control_plane_epoch_after_raise', :'epoch_after'::jsonb,
  'attempts_refused_until_reconciled', (SELECT count(*) FROM attempts
    WHERE status IN ('created', 'dispatching', 'running', 'collecting', 'unknown', 'dispatch_uncertain')),
  'attempts_refused_by_status', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
    FROM (SELECT status, count(*) AS n FROM attempts
          WHERE status IN ('created', 'dispatching', 'running', 'collecting', 'unknown', 'dispatch_uncertain')
          GROUP BY status) s),
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
