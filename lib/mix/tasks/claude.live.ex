defmodule Mix.Tasks.Claude.Live do
  use Mix.Task

  @shortdoc "Realtime local/remote Claude prompts and chat"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("codex.live", ensure_remote_name(args))
  end

  defp ensure_remote_name(args) do
    if has_remote_name?(args) do
      args
    else
      ["--remote-name", "claude" | args]
    end
  end

  defp has_remote_name?(args) do
    Enum.any?(args, fn
      "--remote-name" -> true
      "--remote-name=" <> _ -> true
      _ -> false
    end)
  end
end
