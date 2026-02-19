ExUnit.start()

case Application.stop(:hivebeam) do
  :ok -> :ok
  {:error, {:not_started, :hivebeam}} -> :ok
  {:error, _reason} -> :ok
end
