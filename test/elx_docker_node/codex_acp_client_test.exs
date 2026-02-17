defmodule ElxDockerNode.CodexAcpClientTest do
  use ExUnit.Case, async: true

  alias ACPex.Schema.Client.FsReadTextFileRequest
  alias ACPex.Schema.Client.FsReadTextFileResponse
  alias ACPex.Schema.Client.FsWriteTextFileRequest
  alias ACPex.Schema.Client.FsWriteTextFileResponse
  alias ACPex.Schema.Client.Terminal.CreateResponse
  alias ACPex.Schema.Client.Terminal.CreateRequest
  alias ACPex.Schema.Client.Terminal.KillRequest
  alias ACPex.Schema.Client.Terminal.OutputRequest
  alias ACPex.Schema.Client.Terminal.OutputResponse
  alias ACPex.Schema.Client.Terminal.ReleaseRequest
  alias ACPex.Schema.Client.Terminal.ReleaseResponse
  alias ACPex.Schema.Client.Terminal.WaitForExitResponse
  alias ACPex.Schema.Client.Terminal.WaitForExitRequest
  alias ACPex.Schema.Session.UpdateNotification
  alias ElxDockerNode.CodexAcpClient

  test "forwards session updates to the bridge process" do
    assert {:ok, state} = CodexAcpClient.init(bridge: self())

    notification = %UpdateNotification{
      session_id: "session-1",
      update: %{"type" => "agent_message_chunk", "content" => %{"text" => "hello"}}
    }

    assert {:noreply, ^state} = CodexAcpClient.handle_session_update(notification, state)
    assert_receive {:acp_session_update, ^notification}
  end

  test "reads and writes files when approved" do
    tmp_dir = unique_tmp_dir("codex_acp_files")
    file_path = Path.join(tmp_dir, "sample.txt")

    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:ok, %FsWriteTextFileResponse{}, state} =
             CodexAcpClient.handle_fs_write_text_file(
               %FsWriteTextFileRequest{
                 session_id: "s1",
                 path: "sample.txt",
                 content: "line1\nline2"
               },
               state
             )

    assert {:ok, %FsReadTextFileResponse{content: "line2"}, _state} =
             CodexAcpClient.handle_fs_read_text_file(
               %FsReadTextFileRequest{session_id: "s1", path: file_path, line: 2, limit: 1},
               state
             )

    assert File.read!(file_path) == "line1\nline2"
  end

  test "creates terminal commands, captures output, waits for exit, and releases" do
    tmp_dir = unique_tmp_dir("codex_acp_terminal")

    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    assert {:ok, %CreateResponse{terminal_id: terminal_id}, state} =
             CodexAcpClient.handle_terminal_create(
               %CreateRequest{
                 session_id: "s1",
                 command: "/bin/sh",
                 args: ["-lc", "printf hello"]
               },
               state
             )

    assert {:ok, %WaitForExitResponse{exit_code: 0}, state} =
             CodexAcpClient.handle_terminal_wait_for_exit(
               %WaitForExitRequest{session_id: "s1", terminal_id: terminal_id},
               state
             )

    assert {:ok, %OutputResponse{output: output, exit_status: %{"exitCode" => 0}}, state} =
             CodexAcpClient.handle_terminal_output(
               %OutputRequest{session_id: "s1", terminal_id: terminal_id},
               state
             )

    assert output =~ "hello"

    assert {:ok, %ReleaseResponse{}, _state} =
             CodexAcpClient.handle_terminal_release(
               %ReleaseRequest{session_id: "s1", terminal_id: terminal_id},
               state
             )
  end

  test "denies mutating operations when approval is rejected" do
    tmp_dir = unique_tmp_dir("codex_acp_deny")

    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               tool_cwd: tmp_dir,
               approval_fun: fn _request, _state -> {:ok, false} end
             )

    assert {:error, %{code: -32003}, state} =
             CodexAcpClient.handle_fs_write_text_file(
               %FsWriteTextFileRequest{session_id: "s1", path: "blocked.txt", content: "x"},
               state
             )

    assert {:error, %{code: -32003}, state} =
             CodexAcpClient.handle_terminal_create(
               %CreateRequest{session_id: "s1", command: "/bin/sh", args: ["-lc", "echo hi"]},
               state
             )

    assert {:error, %{code: -32001}, _state} =
             CodexAcpClient.handle_terminal_kill(
               %KillRequest{session_id: "s1", terminal_id: "missing"},
               state
             )
  end

  defp unique_tmp_dir(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf(path)
    end)

    path
  end
end
