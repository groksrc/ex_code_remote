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

# In dev, allow AUTH_TOKEN from environment to override config.
# In test, it comes from config/test.exs.
# In prod, it's required — see the prod block below.
if config_env() != :prod do
  if auth_token = System.get_env("AUTH_TOKEN") do
    config :ex_code_remote, auth_token: auth_token
  end
end

if config_env() == :prod do
  auth_token = System.get_env("AUTH_TOKEN") || ""

  if String.trim(auth_token) == "" do
    raise """
    AUTH_TOKEN environment variable is required in production but is missing or empty.
    Set it via: fly secrets set AUTH_TOKEN=$(openssl rand -hex 32)
    """
  end

  config :ex_code_remote, auth_token: auth_token

  config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, []}

  database_path = System.get_env("DATABASE_PATH", "/data/audit.db")

  config :ex_code_remote, ExCodeRemote.Audit.Repo,
    database: database_path,
    pool_size: 1,
    journal_mode: :wal
end
