import Config

config :ex_code_remote, ExCodeRemote.Audit.Repo,
  database: "priv/data/audit.db",
  pool_size: 1,
  journal_mode: :wal
