defmodule Hivebeam.AcpRequestPermissionResponse do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field(:outcome, :map)
    field(:meta, :map, source: :_meta)
  end
end
