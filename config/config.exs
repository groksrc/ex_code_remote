import Config

config :ex_code_remote,
  ecto_repos: [ExCodeRemote.Audit.Repo]

config :ex_code_remote, ExCodeRemote.Audit.Repo, priv: "priv/audit"

import_config "#{config_env()}.exs"
