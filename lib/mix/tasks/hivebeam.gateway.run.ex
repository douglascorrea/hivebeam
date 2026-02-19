defmodule Mix.Tasks.Hivebeam.Gateway.Run do
  use Mix.Task

  alias Hivebeam.Gateway.Config

  @shortdoc "Starts Hivebeam gateway (HTTP + WebSocket) and blocks"

  @switches [bind: :string, token: :string, data_dir: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
    end

    System.put_env("HIVEBEAM_GATEWAY_ENABLED", "1")

    if value = Keyword.get(opts, :bind), do: System.put_env("HIVEBEAM_GATEWAY_BIND", value)
    if value = Keyword.get(opts, :token), do: System.put_env("HIVEBEAM_GATEWAY_TOKEN", value)

    if value = Keyword.get(opts, :data_dir), do: System.put_env("HIVEBEAM_GATEWAY_DATA_DIR", value)

    Mix.Task.run("app.start")

    if is_nil(Config.token()) do
      Mix.raise("HIVEBEAM_GATEWAY_TOKEN is required (pass --token or env var)")
    end

    Mix.shell().info("Gateway listening on #{Config.bind()}")
    Process.sleep(:infinity)
  end
end
