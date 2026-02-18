defmodule Hivebeam.CodexChatUiTest do
  use ExUnit.Case, async: true

  alias Hivebeam.CodexChatUi

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

    assert Enum.map(last_entries, & &1.role) == [:assistant, :activity, :assistant]
    assert Enum.at(last_entries, 0).text == "first"
    assert Enum.at(last_entries, 1).latest_activity == "Exploring"
    assert map_size(Enum.at(last_entries, 1).tool_rows) == 1
    assert Enum.at(last_entries, 2).text == "second"
  end

  test "shows thinking activity card when prompt stream starts" do
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
             role: :activity,
             node: "codex@192.168.50.234",
             running: true,
             latest_activity: "Thinking",
             latest_summary: nil,
             thought_text: "",
             tool_rows: %{},
             tool_order: []
           }
  end

  test "does not duplicate thinking activity cards for repeated start events" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} = push_stream_event(state, :start, nil)
    {:ok, state} = push_stream_event(state, :start, nil)

    activity_entries =
      Enum.filter(state.entries, fn
        %{role: :activity, node: "codex@192.168.50.234"} -> true
        _ -> false
      end)

    assert length(activity_entries) == 1
  end

  test "preserves scroll position while new output streams when user is scrolled up" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    large_chunk =
      1..40
      |> Enum.map_join("\n", fn n -> "line-#{n}" end)

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => large_chunk}}
      )

    {state, []} = CodexChatUi.update(:scroll_up_page, state)
    assert state.scroll_offset > 0
    assert state.follow_output? == false

    old_offset = state.scroll_offset

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "\nnew-tail-line"}}
      )

    assert state.scroll_offset > old_offset
    assert state.follow_output? == false

    {state, []} = CodexChatUi.update(:scroll_bottom, state)
    assert state.scroll_offset == 0
    assert state.follow_output? == true
  end

  test "toggles latest activity expansion with ctrl+o message" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
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

    assert MapSet.size(state.expanded_entries) == 0

    {state, []} = CodexChatUi.update(:toggle_activity_expand, state)
    assert MapSet.size(state.expanded_entries) == 1

    {state, []} = CodexChatUi.update(:toggle_activity_expand, state)
    assert MapSet.size(state.expanded_entries) == 0
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
