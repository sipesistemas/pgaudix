-- pgaudix benchmark: per-operation cost of auditing.
--
-- Measures INSERT / UPDATE / DELETE of 200k rows on a 6-column table with
-- and without auditing, three rounds each, and reports the best time.
-- This is a measurement tool, not a pass/fail test: absolute numbers depend
-- on the machine, so compare runs on the same host before and after a change.
--
-- Usage (extension installed):  make USE_PGXS=1 bench
-- Creates and drops a database named pgaudix_bench.

\set ON_ERROR_STOP on
\set QUIET on
SELECT format('DROP DATABASE IF EXISTS pgaudix_bench') \gexec
CREATE DATABASE pgaudix_bench;
\c pgaudix_bench
CREATE EXTENSION pgaudix;

CREATE TABLE public.plain   (id int, a text, b numeric(12,2), c timestamptz, d int, e int);
CREATE TABLE public.audited (id int, a text, b numeric(12,2), c timestamptz, d int, e int);
SELECT pgaudix.enable('public.audited');

CREATE TABLE public.timings (round int, op text, audited boolean, ms numeric);

CREATE FUNCTION public.bench_round(r int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz;
    ops text[] := ARRAY['INSERT', 'UPDATE', 'DELETE'];
    tabs text[] := ARRAY['plain', 'audited'];
    op text; tab text; sql text;
BEGIN
    FOREACH op IN ARRAY ops LOOP
        FOREACH tab IN ARRAY tabs LOOP
            sql := CASE op
                WHEN 'INSERT' THEN format('INSERT INTO public.%I SELECT g, ''row '' || g, g * 1.5, now(), g, g FROM generate_series(1, 200000) g', tab)
                WHEN 'UPDATE' THEN format('UPDATE public.%I SET d = d + 1', tab)
                WHEN 'DELETE' THEN format('DELETE FROM public.%I', tab)
            END;
            t0 := clock_timestamp();
            EXECUTE sql;
            INSERT INTO public.timings VALUES (r, op, tab = 'audited',
                round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1));
        END LOOP;
    END LOOP;
    TRUNCATE public.audited_audit;
END $$;

SELECT public.bench_round(1);
SELECT public.bench_round(2);
SELECT public.bench_round(3);

\set QUIET off
\echo
\echo pgaudix benchmark: 200k rows x 6 columns, best of 3 rounds (ms)
SELECT p.op,
       p.ms  AS plain_ms,
       a.ms  AS audited_ms,
       round(a.ms / p.ms, 1) AS ratio,
       round((a.ms - p.ms) * 1000 / 200000, 2) AS audit_cost_us_per_row
FROM (SELECT op, min(ms) AS ms FROM public.timings WHERE NOT audited GROUP BY op) p
JOIN (SELECT op, min(ms) AS ms FROM public.timings WHERE audited GROUP BY op) a USING (op)
ORDER BY array_position(ARRAY['INSERT', 'UPDATE', 'DELETE'], p.op);

\set QUIET on
\c postgres
DROP DATABASE pgaudix_bench;
