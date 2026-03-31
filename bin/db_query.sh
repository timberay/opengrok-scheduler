#!/bin/bash

# bin/db_query.sh
# SQLite3 query execution utility

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure the database is initialized
if [ ! -f "$DB_PATH" ]; then
    echo "[Error] Database not found at $DB_PATH" >&2
    exit 1
fi

# Execute Query
# Execute Query with Concurrency Optimizations
# Use heredoc and skip PRAGMA output lines
set -o pipefail
STDERR_FILE=$(mktemp)

# Execute commands: PRAGMAs set up the connection, then run the query
# Skip first 2 lines (10000 from busy_timeout, wal from journal_mode)
sqlite3 -batch "$DB_PATH" <<EOSQL 2>"$STDERR_FILE" | tail -n +3
PRAGMA busy_timeout=10000;
PRAGMA journal_mode=WAL;
$1
EOSQL

# Capture sqlite3 exit code (first element of PIPESTATUS)
QUERY_EXIT=${PIPESTATUS[0]}

# Output errors to stderr (filter init noise)
if [ -s "$STDERR_FILE" ]; then
    grep -vE "^(-- Loading resources)$" "$STDERR_FILE" >&2
fi

rm -f "$STDERR_FILE"
set +o pipefail
exit $QUERY_EXIT
