defmodule Hivebeam.TerminalSandboxTest do
  use ExUnit.Case, async: true

  alias Hivebeam.TerminalSandbox

  test "terminal capability stays enabled when session is dangerous" do
    assert TerminalSandbox.terminal_capability_enabled?(
             dangerously: true,
             mode: :off,
             backend: :none
           )
  end

  test "terminal capability is disabled when mode is off" do
    refute TerminalSandbox.terminal_capability_enabled?(
             dangerously: false,
             mode: :off,
             backend: :sandbox_exec
           )
  end

  test "terminal capability is disabled in required mode without backend" do
    refute TerminalSandbox.terminal_capability_enabled?(
             dangerously: false,
             mode: :required,
             backend: :none
           )
  end

  test "wrap command returns explicit denial when required mode has no backend" do
    assert {:error, reason} =
             TerminalSandbox.wrap_command("/bin/sh", ["-lc", "echo hi"],
               dangerously: false,
               mode: :required,
               backend: :none
             )

    assert reason[:reason] == "terminal_disabled_in_sandbox"
  end

  test "wrap command falls back to raw command in best effort mode without backend" do
    assert {:ok, "/bin/sh", ["-lc", "echo hi"]} =
             TerminalSandbox.wrap_command("/bin/sh", ["-lc", "echo hi"],
               dangerously: false,
               mode: :best_effort,
               backend: :none
             )
  end
end
