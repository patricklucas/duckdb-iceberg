#!/usr/bin/env bash

FILE=segfault-test.sql

if [ -x ./build/reldebug/duckdb ]; then
  echo >&2 "> using reldebug build"
  DUCKDB=./build/reldebug/duckdb
else
  echo >&2 "> reldebug build not found, Using duckdb from PATH"
  DUCKDB=duckdb
fi

for i in {1..1000}; do
  if ! "$DUCKDB" --init "$FILE" -c 'SELECT count(*) FROM root_clordids;' > /dev/null; then
    echo 'failed'
    exit 1
  fi

  echo -n .

  if [ $((i % 80)) -eq 0 ]; then
    echo
  fi
done

echo
echo 'passed'
