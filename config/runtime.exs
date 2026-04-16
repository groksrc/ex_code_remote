import Config

port =
  case System.get_env("PORT") do
    nil ->
      4000

    "" ->
      4000

    value ->
      case Integer.parse(value) do
        {port, ""} ->
          port

        _ ->
          require Logger
          Logger.warning("Invalid PORT value #{inspect(value)}, falling back to 4000")
          4000
      end
  end

config :ex_code_remote, port: port

# Only override auth_token from env if it's actually set.
# In test, it comes from config/test.exs; in prod, from the environment.
if auth_token = System.get_env("AUTH_TOKEN") do
  config :ex_code_remote, auth_token: auth_token
end

if config_env() == :prod do
  config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, []}

  database_path = System.get_env("DATABASE_PATH", "/data/audit.db")

  config :ex_code_remote, ExCodeRemote.Audit.Repo,
    database: database_path,
    pool_size: 1,
    journal_mode: :wal
end
