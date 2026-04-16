#!/bin/sh
set -e

echo "Running migrations..."
/app/bin/ex_code_remote eval "ExCodeRemote.Release.migrate()"

echo "Migrations complete. Starting server..."
exec /app/bin/ex_code_remote start
