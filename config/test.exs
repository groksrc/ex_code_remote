import Config

config :ex_code_remote,
  auth_token: "test-token-for-testing"

config :ex_code_remote, ExCodeRemote.Audit.Repo,
  database: "priv/data/test.db",
  pool_size: 5,
  journal_mode: :wal

# Keep logger at debug so CaptureLog can capture telemetry handler output.
# Test noise is controlled by ExUnit's --trace/--quiet, not logger level.
config :logger, level: :debug
