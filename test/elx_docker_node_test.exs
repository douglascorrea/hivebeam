defmodule ElxDockerNodeTest do
  use ExUnit.Case

  test "can send a message to a running node listener" do
    port = random_port()
    parent = self()

    assert {:ok, pid} =
             ElxDockerNode.start_node(
               name: "receiver",
               port: port,
               on_message: fn payload ->
                 send(parent, {:received, payload})
                 :ok
               end
             )

    on_exit(fn -> Process.exit(pid, :kill) end)

    assert {:ok, "receiver"} =
             ElxDockerNode.send_message("127.0.0.1", port,
               from: "sender",
               message: "hello from test"
             )

    assert_receive {:received, %{from: "sender", message: "hello from test"}}
  end

  test "returns an error when required send options are missing" do
    assert {:error, :missing_required_options} =
             ElxDockerNode.send_message("127.0.0.1", 9_999, from: "sender")
  end

  defp random_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
