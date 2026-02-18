defmodule Hivebeam.CodexAcpClientTest do
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
  alias Hivebeam.AcpRequestPermissionResponse
  alias Hivebeam.CodexAcpClient

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

  test "maps session/request_permission approval to selected allow option" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Read file", "status" => "pending"},
      "options" => [
        %{"optionId" => "approved", "name" => "Yes", "kind" => "allow_once"},
        %{"optionId" => "abort", "name" => "No", "kind" => "reject_once"}
      ]
    }

    assert {:ok,
            %AcpRequestPermissionResponse{
              outcome: %{"outcome" => "selected", "optionId" => "approved"}
            }, _state} = CodexAcpClient.handle_session_request_permission(request, state)
  end

  test "does not consume unrelated mailbox messages while handling permissions" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Read file", "status" => "pending"},
      "options" => [
        %{"optionId" => "approved", "name" => "Yes", "kind" => "allow_once"},
        %{"optionId" => "abort", "name" => "No", "kind" => "reject_once"}
      ]
    }

    send(self(), {:unrelated_message, :preserve_me})

    assert {:ok,
            %AcpRequestPermissionResponse{
              outcome: %{"outcome" => "selected", "optionId" => "approved"}
            }, _state} = CodexAcpClient.handle_session_request_permission(request, state)

    assert_receive {:unrelated_message, :preserve_me}
  end

  test "maps session/request_permission denial to selected reject option" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, false} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Run command", "status" => "pending"},
      "options" => [
        %{"optionId" => "approved", "name" => "Yes", "kind" => "allow_once"},
        %{"optionId" => "abort", "name" => "No", "kind" => "reject_once"}
      ]
    }

    assert {:ok,
            %AcpRequestPermissionResponse{
              outcome: %{"outcome" => "selected", "optionId" => "abort"}
            }, _state} = CodexAcpClient.handle_session_request_permission(request, state)
  end

  test "returns cancelled permission outcome when no reject option exists" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, false} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "Run command", "status" => "pending"},
      "options" => [
        %{"optionId" => "approved", "name" => "Yes", "kind" => "allow_once"}
      ]
    }

    assert {:ok, %AcpRequestPermissionResponse{outcome: %{"outcome" => "cancelled"}}, _state} =
             CodexAcpClient.handle_session_request_permission(request, state)
  end

  test "prefers one-time approval option over session-wide option when both are available" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, true} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "List files", "status" => "pending"},
      "options" => [
        %{
          "optionId" => "approved-for-session",
          "name" => "Always",
          "kind" => "approved-for-session"
        },
        %{"optionId" => "approved", "name" => "Yes", "kind" => "approved"},
        %{"optionId" => "abort", "name" => "No", "kind" => "abort"}
      ]
    }

    assert {:ok,
            %AcpRequestPermissionResponse{
              outcome: %{"outcome" => "selected", "optionId" => "approved"}
            }, _state} = CodexAcpClient.handle_session_request_permission(request, state)
  end

  test "maps denial to abort option when reject kind is not provided" do
    assert {:ok, state} =
             CodexAcpClient.init(
               bridge: self(),
               approval_fun: fn _request, _state -> {:ok, false} end
             )

    request = %{
      "sessionId" => "s1",
      "toolCall" => %{"toolCallId" => "tool-1", "title" => "List files", "status" => "pending"},
      "options" => [
        %{"optionId" => "approved", "name" => "Yes"},
        %{"optionId" => "abort", "name" => "No, provide feedback"}
      ]
    }

    assert {:ok,
            %AcpRequestPermissionResponse{
              outcome: %{"outcome" => "selected", "optionId" => "abort"}
            }, _state} = CodexAcpClient.handle_session_request_permission(request, state)
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
