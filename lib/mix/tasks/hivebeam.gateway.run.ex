defmodule Mix.Tasks.Hivebeam.Gateway.Run do
  use Mix.Task

  alias Hivebeam.Gateway.Config

  @shortdoc "Starts Hivebeam gateway (HTTP + WebSocket) and blocks"

  @switches [
    bind: :string,
    token: :string,
    data_dir: :string,
    sandbox_root: :keep,
    sandbox_default_root: :string,
    dangerously: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
    end

    if value = Keyword.get(opts, :bind), do: System.put_env("HIVEBEAM_GATEWAY_BIND", value)
    if value = Keyword.get(opts, :token), do: System.put_env("HIVEBEAM_GATEWAY_TOKEN", value)

    if value = Keyword.get(opts, :data_dir),
      do: System.put_env("HIVEBEAM_GATEWAY_DATA_DIR", value)

    sandbox_roots =
      opts
      |> Keyword.get_values(:sandbox_root)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if sandbox_roots != [] do
      separator =
        case :os.type() do
          {:win32, _} -> ";"
          _ -> ":"
        end

      System.put_env(
        "HIVEBEAM_GATEWAY_SANDBOX_ALLOWED_ROOTS",
        Enum.join(sandbox_roots, separator)
      )
    end

    if value = Keyword.get(opts, :sandbox_default_root) do
      System.put_env("HIVEBEAM_GATEWAY_SANDBOX_DEFAULT_ROOT", value)
    end

    if Keyword.get(opts, :dangerously, false) do
      System.put_env("HIVEBEAM_GATEWAY_DANGEROUSLY", "true")
    end

    :ok = Config.require_token!()

    Mix.Task.run("app.start")

    Mix.shell().info("Gateway listening on #{Config.bind()}")
    Process.sleep(:infinity)
  end
end
