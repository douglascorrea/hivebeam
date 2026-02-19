defmodule Hivebeam.AcpClientTest do
  use ExUnit.Case, async: true

  alias Hivebeam.AcpClient

  test "forwards session updates to the bridge process" do
    assert {:ok, state} = AcpClient.init(bridge: self())

    assert {:noreply, ^state} =
             AcpClient.handle_notification(
               "session/update",
               %{"sessionId" => "session-1", "update" => %{"type" => "agent_message_chunk"}},
               state
             )

    assert_receive {:acp_session_update,
                    %{session_id: "session-1", update: %{"type" => "agent_message_chunk"}}}
  end

  test "writes and reads files when approvals are allowed" do
    tmp_dir = unique_tmp_dir("codex_acp_files")
    file_path = Path.join(tmp_dir, "sample.txt")

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:ok, %{}, state} =
             AcpClient.handle_request(
               "fs/write_text_file",
               %{"sessionId" => "s1", "path" => file_path, "content" => "line1\nline2"},
               state
             )

    assert {:ok, %{"content" => "line2"}, _state} =
             AcpClient.handle_request(
               "fs/read_text_file",
               %{"sessionId" => "s1", "path" => file_path, "line" => 2, "limit" => 1},
               state
             )
  end

  test "supports terminal create, wait_for_exit, output, and release" do
    tmp_dir = unique_tmp_dir("codex_acp_terminal")

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:ok, %{"terminalId" => terminal_id}, state} =
             AcpClient.handle_request(
               "terminal/create",
               %{
                 "sessionId" => "s1",
                 "command" => "/bin/sh",
                 "args" => ["-lc", "printf 'ok'"]
               },
               state
             )

    assert {:ok, %{"exitCode" => 0}, state} =
             AcpClient.handle_request(
               "terminal/wait_for_exit",
               %{"sessionId" => "s1", "terminalId" => terminal_id},
               state
             )

    assert {:ok, %{"output" => output, "exitStatus" => %{"exitCode" => 0}}, state} =
             AcpClient.handle_request(
               "terminal/output",
               %{"sessionId" => "s1", "terminalId" => terminal_id},
               state
             )

    assert output == "ok"

    assert {:ok, %{}, _state} =
             AcpClient.handle_request(
               "terminal/release",
               %{"sessionId" => "s1", "terminalId" => terminal_id},
               state
             )
  end

  test "denies filesystem and terminal operations when approvals are denied" do
    tmp_dir = unique_tmp_dir("codex_acp_deny")

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, false} end
             )

    assert {:error, %{code: -32_003}, state} =
             AcpClient.handle_request(
               "fs/write_text_file",
               %{"sessionId" => "s1", "path" => "blocked.txt", "content" => "x"},
               state
             )

    assert {:error, %{code: -32_003}, _state} =
             AcpClient.handle_request(
               "terminal/create",
               %{"sessionId" => "s1", "command" => "/bin/sh", "args" => ["-lc", "echo hi"]},
               state
             )
  end

  test "blocks operations outside sandbox roots even when approvals are allowed" do
    sandbox_root = unique_tmp_dir("codex_acp_sandbox")
    outside_root = unique_tmp_dir("codex_acp_outside")
    outside_file = Path.join(outside_root, "blocked.txt")

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               tool_cwd: sandbox_root,
               sandbox_roots: [sandbox_root],
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:error, %{code: -32_004}, state} =
             AcpClient.handle_request(
               "fs/write_text_file",
               %{"sessionId" => "s1", "path" => outside_file, "content" => "x"},
               state
             )

    assert {:error, %{code: -32_004}, _state} =
             AcpClient.handle_request(
               "terminal/create",
               %{
                 "sessionId" => "s1",
                 "command" => "/bin/sh",
                 "args" => ["-lc", "echo hi"],
                 "cwd" => outside_root
               },
               state
             )
  end

  test "permission request chooses approval option on allow" do
    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"title" => "Write file"},
      "options" => [
        %{"optionId" => "deny", "name" => "Reject", "kind" => "reject_once"},
        %{"optionId" => "allow", "name" => "Allow once", "kind" => "allow_once"}
      ]
    }

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}, _state} =
             AcpClient.handle_request("session/request_permission", request, state)
  end

  test "permission request can return cancelled when approval function errors" do
    request = %{"sessionId" => "s1", "options" => [%{"optionId" => "allow", "name" => "Allow"}]}

    assert {:ok, state} =
             AcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:error, :approval_service_down} end
             )

    assert {:ok, %{"outcome" => %{"outcome" => "cancelled"}}, _state} =
             AcpClient.handle_request("session/request_permission", request, state)
  end

  defp unique_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
