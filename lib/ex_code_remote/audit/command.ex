defmodule ExCodeRemote.Audit.Command do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "commands" do
    field(:machine, :string)
    field(:type, :string)
    field(:status, :string)
    field(:command, :string)
    field(:path, :string)
    field(:working_dir, :string)
    field(:timeout, :integer)
    field(:output, :string)
    field(:error, :string)
    field(:exit_code, :integer)
    field(:duration_ms, :integer)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
  end
end
