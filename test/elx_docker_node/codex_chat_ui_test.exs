defmodule ElxDockerNode.CodexChatUiTest do
  use ExUnit.Case, async: true

  alias ElxDockerNode.CodexChatUi

  test "keeps stream order when tool updates interleave with assistant chunks" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "first"}}
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-1",
          "title" => "Read mix.exs",
          "kind" => "read",
          "status" => "in_progress"
        }
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "second"}}
      )

    last_entries = Enum.take(state.entries, -3)

    assert Enum.map(last_entries, & &1.role) == [:assistant, :tool, :assistant]
    assert Enum.at(last_entries, 0).text == "first"
    assert String.contains?(Enum.at(last_entries, 1).text, "Read mix.exs")
    assert Enum.at(last_entries, 2).text == "second"
  end

  test "shows thinking status when prompt stream starts" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} =
      push_stream_event(
        state,
        :start,
        nil
      )

    assert List.last(state.entries) == %{
             role: :status,
             node: "codex@192.168.50.234",
             text: "Thinking..."
           }
  end

  test "does not duplicate identical thinking status lines" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} = push_stream_event(state, :start, nil)
    {:ok, state} = push_stream_event(state, :start, nil)

    thinking_lines =
      Enum.filter(state.entries, fn
        %{role: :status, node: "codex@192.168.50.234", text: "Thinking..."} -> true
        _ -> false
      end)

    assert length(thinking_lines) == 1
  end

  defp push_stream_update(state, update) do
    push_stream_event(state, :update, update)
  end

  defp push_stream_event(state, event, update) do
    payload =
      %{event: event, node: :"codex@192.168.50.234"}
      |> maybe_put_update(update)

    case CodexChatUi.handle_info({:codex_prompt_stream, payload}, state) do
      {next_state, []} -> {:ok, next_state}
      other -> {:error, other}
    end
  end

  defp maybe_put_update(payload, nil), do: payload
  defp maybe_put_update(payload, update), do: Map.put(payload, :update, update)
end
