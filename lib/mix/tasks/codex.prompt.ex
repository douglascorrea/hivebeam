defmodule Mix.Tasks.Codex.Prompt do
  use Mix.Task

  alias ElxDockerNode.CodexCli

  @shortdoc "Sends a prompt to the local or remote Codex bridge (with live updates)"
  @switches [
    node: :string,
    message: :string,
    timeout: :integer,
    stream: :boolean,
    thoughts: :boolean,
    tools: :boolean,
    approve: :string
  ]
  @aliases [n: :node, m: :message, t: :timeout]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    message = required!(opts, :message, "--message")
    target_node = parse_target_node(opts)
    timeout = Keyword.get(opts, :timeout)
    stream? = Keyword.get(opts, :stream, true)
    show_thoughts? = Keyword.get(opts, :thoughts, true)
    show_tools? = Keyword.get(opts, :tools, true)
    approval_mode = CodexCli.parse_approval_mode!(Keyword.get(opts, :approve, "ask"))

    response =
      CodexCli.prompt(target_node, message,
        timeout: timeout,
        stream: stream?,
        show_thoughts: show_thoughts?,
        show_tools: show_tools?,
        approval_mode: approval_mode
      )

    case response do
      {:ok, result} ->
        Mix.shell().info("Prompt completed on node #{result.node}")
        Mix.shell().info("session_id: #{result.session_id}")
        Mix.shell().info("stop_reason: #{result.stop_reason}")

        if not stream? do
          print_chunks("thought_chunks", result.thought_chunks)
          print_chunks("message_chunks", result.message_chunks)
          print_tool_events(result.tool_events)
        end

      {:error, reason} ->
        Mix.raise("Prompt failed: #{inspect(reason)}")
    end
  end

  defp parse_target_node(opts) do
    case Keyword.get(opts, :node) do
      nil -> nil
      value -> String.to_atom(value)
    end
  end

  defp print_chunks(_label, []), do: :ok

  defp print_chunks(label, chunks) do
    Mix.shell().info("#{label}: #{Enum.join(chunks, "")}")
  end

  defp print_tool_events([]), do: :ok

  defp print_tool_events(events) do
    Mix.shell().info("tool_events: #{inspect(events, pretty: true, limit: :infinity)}")
  end

  defp required!(opts, key, flag) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("Missing required option #{flag}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
