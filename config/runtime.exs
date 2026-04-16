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
