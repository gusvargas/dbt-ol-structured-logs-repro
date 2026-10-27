#!/usr/bin/env bash
# minimal standalone repro for dbt-ol --consume-structured-logs exiting non-zero while dbt succeeds.
# usage: ./repro.sh [pip spec for openlineage-dbt, default openlineage-dbt==1.54.0]
set -u
spec=${1:-openlineage-dbt==1.54.0}
work=$(mktemp -d)
cd "$work"
uv venv -q -p 3.12 .venv
uv pip install -q -p .venv/bin/python "dbt-core~=1.12.0" dbt-duckdb $spec
export PATH="$work/.venv/bin:$PATH" OPENLINEAGE__TRANSPORT__TYPE=file OPENLINEAGE__TRANSPORT__APPEND=true
mkdir -p proj/models proj/macros
cat > proj/dbt_project.yml <<'YML'
name: repro
version: "1.0"
profile: repro
YML
cat > proj/profiles.yml <<'YML'
repro:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: "{{ env_var('DUCKDB_PATH') }}"
YML
echo "{% macro hello() %}{% do log('HELLO FROM RUN-OPERATION', info=true) %}{% endmacro %}" > proj/macros/hello.sql
for i in 1 2 3 4 5 6; do echo "select $i as id" > proj/models/m$i.sql; done
cd proj
dbt --version 2>&1 | grep installed
pip_ol=$(uv pip list -p ../.venv/bin/python 2>/dev/null | grep -i openlineage-dbt)
echo "installed: $pip_ol"

echo "== 1) six concurrent dbt-ol runs sharing target/ (what an orchestrator does with parallel 'dbt run --select X')"
for i in 1 2 3 4 5 6; do
  ( DUCKDB_PATH="../m$i.duckdb" OPENLINEAGE__TRANSPORT__LOG_FILE_PATH="../m$i.jsonl" \
      dbt-ol --consume-structured-logs run --select "m$i" > "../m$i.log" 2>&1
    echo $? > "../m$i.rc" ) &
done
wait
sleep 3  # let any orphaned dbt child finish writing its output
for i in 1 2 3 4 5 6; do
  echo "m$i: dbt-ol exit=$(cat ../m$i.rc)  dbt says: $(grep -o 'Done. PASS=[0-9]* WARN=[0-9]* ERROR=[0-9]*' ../m$i.log)  lineage for dbt run: $(python3 -c "import json,sys;print(' '.join(json.loads(l)['eventType'] for l in open(sys.argv[1]) if json.loads(l)['job']['name']=='dbt-run-repro'))" ../m$i.jsonl 2>/dev/null)  $(grep -m1 -o 'json.decoder.JSONDecodeError' ../m$i.log)"
done

echo "== 2) dbt-ol --consume-structured-logs run-operation hello"
DUCKDB_PATH=../ro.duckdb OPENLINEAGE__TRANSPORT__LOG_FILE_PATH=../ro.jsonl dbt-ol --consume-structured-logs run-operation hello > ../ro.log 2>&1
echo "dbt-ol exit=$? ; macro ran: $(grep -c 'HELLO FROM RUN-OPERATION' ../ro.log) time(s)"
grep -E "doesn't recognize|returned" ../ro.log | cut -c1-160
echo "work dir: $work"
