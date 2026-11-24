# Independent synthetic load, 2026-11-24

Disposable local PostgreSQL16, migrations through0113, no live requests.50synthetic hotels×30branches, plus bootstrap hotel/branch.3,142,232reservations,30,010rooms. Fixture business row triggers bypassed for bulk generation as documented; derived data populated, index/check constraints retained.

After ANALYZE:3owner-session contexts×10read variants,2warmups then15measured calls per cell.450samples,30cells complete. Every cell and named pooled variant p95<500ms. Worst pooled p95:175.6ms (finance full year). Maximum observed call:216.3ms. EXPLAIN ANALYZE/BUFFERS captured for measured functions.

Pooled percentile_cont interpolates the ordered45samples, not the three cell percentiles. A pooled percentile can exceed all small-sample interpolated cell percentiles. No network latency, browser concurrency, sustained mixed writes or production-hardware claim.

Evidence packet: roomai-load-independent1544.tgz, delivered to coordinator. Durable local evidence: /tmp/roomai-load-final-independent, database airec_load_final50, server127.0.0.1:55432. No rerun/reseed needed unless source changes affect workload.
