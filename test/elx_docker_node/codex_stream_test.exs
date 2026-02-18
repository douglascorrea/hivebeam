defmodule ElxDockerNode.CodexStreamTest do
  use ExUnit.Case, async: true

  alias ElxDockerNode.CodexStream

  test "extracts message chunks from nested content structures" do
    update = %{
      "type" => "agent_message_chunk",
      "content" => %{
        "parts" => [
          %{"type" => "text", "text" => "Hello "},
          %{"delta" => %{"text" => "world"}}
        ]
      }
    }

    assert CodexStream.message_chunks(update) == ["Hello ", "world"]
  end

  test "extracts thought chunks from reasoning and thought keys" do
    update = %{
      "type" => "agent_thought_chunk",
      "content" => %{"reasoning" => "step 1"},
      "delta" => %{"thought" => "step 2"}
    }

    assert CodexStream.thought_chunks(update) == ["step 1", "step 2"]
  end

  test "normalizes update kind from string and atom keys" do
    assert CodexStream.update_kind(%{"type" => "agent_message_chunk"}) == "agent_message_chunk"
    assert CodexStream.update_kind(%{sessionUpdate: "update-123"}) == "update-123"

    assert CodexStream.update_kind(%{"sessionUpdate" => "tool_call", "kind" => "execute"}) ==
             "tool_call"
  end

  test "builds compact tool summary" do
    summary =
      CodexStream.tool_summary(%{
        "toolCallId" => "tool-456",
        "title" => "Edit file",
        "kind" => "tool_call",
        "status" => "completed"
      })

    assert summary == "Edit file id=tool-456 kind=tool_call status=completed"
  end

  test "infers tool title from raw input command when title is absent" do
    summary =
      CodexStream.tool_summary(%{
        "toolCallId" => "tool-789",
        "kind" => "execute",
        "rawInput" => %{
          "command" => "/bin/sh",
          "args" => ["-lc", "ls -la"]
        },
        "status" => "pending"
      })

    assert summary == "/bin/sh -lc ls -la id=tool-789 kind=execute status=pending"
  end

  test "classifies search tool updates as exploring" do
    activity =
      CodexStream.tool_activity(%{
        "toolCallId" => "tool-111",
        "kind" => "search",
        "title" => "List /workspace",
        "status" => "in_progress"
      })

    assert activity == "Exploring"
  end

  test "classifies edit tool updates as writing" do
    activity =
      CodexStream.tool_activity(%{
        "toolCallId" => "tool-222",
        "kind" => "execute",
        "title" => "Edit lib/codex_bridge.ex",
        "status" => "in_progress"
      })

    assert activity == "Writing"
  end

  test "classifies test execution as verifying before generic execution" do
    activity =
      CodexStream.tool_activity(%{
        "toolCallId" => "tool-333",
        "kind" => "execute",
        "rawInput" => %{
          "command" => "/bin/sh",
          "args" => ["-lc", "mix test"]
        },
        "status" => "in_progress"
      })

    assert activity == "Verifying"
  end

  test "falls back to working when tool intent is unknown" do
    activity =
      CodexStream.tool_activity(%{
        "toolCallId" => "tool-444",
        "kind" => "misc",
        "status" => "in_progress"
      })

    assert activity == "Working"
  end
end
