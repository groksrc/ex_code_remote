defmodule ExCodeRemote.Audit.Repo do
  use Ecto.Repo,
    otp_app: :ex_code_remote,
    adapter: Ecto.Adapters.SQLite3
end
