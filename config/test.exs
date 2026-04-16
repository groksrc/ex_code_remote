import Config

config :ex_code_remote,
  auth_token: "test-token-for-testing"

config :ex_code_remote, ExCodeRemote.Audit.Repo,
  database: "priv/data/test.db",
  pool_size: 5,
  journal_mode: :wal

config :logger, level: :warning
