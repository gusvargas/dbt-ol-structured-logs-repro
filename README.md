# dbt-ol structured-logs repro

A minimal, self-contained reproduction of two bugs in `dbt-ol --consume-structured-logs` (openlineage-dbt 1.54.0, and `main` as of October 2026).

1. **A lineage parsing error changes dbt's outcome.** If dbt-ol fails to interpret a dbt log event, it stops waiting for dbt and exits `-1` (exit status 255), even when dbt succeeds. It emits only the dbt run's `START` event, so the run never closes in the lineage backend. It logs "This does not make dbt execution fail" while doing so.
2. **Unsupported commands exit 0 without running dbt.** `dbt-ol --consume-structured-logs run-operation ...` never starts dbt and still exits 0.

The trigger for bug 1 needs no code changes: several `dbt-ol --consume-structured-logs run --select X` invocations running concurrently from one project directory. dbt rewrites the shared `target/manifest.json` in place, so a concurrent dbt-ol reads a truncated file and `json.load` raises `JSONDecodeError`.

## Run it

Requires [uv](https://docs.astral.sh/uv/) and Python 3.12. No orchestrator, warehouse or credentials: dbt-duckdb and a file transport.

```bash
./repro.sh                                   # openlineage-dbt==1.54.0 from PyPI
./repro.sh "/path/to/OpenLineage/integration/common /path/to/OpenLineage/integration/dbt"   # a local build
```

The script builds a throwaway venv and a 6-model dbt project in a temp directory, then:

1. runs 6 concurrent `dbt-ol --consume-structured-logs run --select mN` sharing `target/`, and prints dbt-ol's exit code, dbt's own summary, and the lineage events emitted for each run;
2. runs `dbt-ol --consume-structured-logs run-operation hello` and prints whether the macro ran.

## What you'll see on 1.54.0

- Several of the 6 runs: `dbt-ol exit=255`, `dbt says: Done. PASS=1 WARN=0 ERROR=0`, lineage `START` only, `json.decoder.JSONDecodeError` in the log. In our runs, 21 of 30 runs hit this.
- `run-operation`: `dbt-ol exit=0 ; macro ran: 0 time(s)`.

The race is timing-dependent; rerun if all 6 happen to pass.

## Workaround on released versions

Give each concurrent invocation its own target directory, for example `--target-path target/$RUN_ID`. That avoids the shared `manifest.json` race (18 of 18 runs clean), but not the underlying exit-code handling.
