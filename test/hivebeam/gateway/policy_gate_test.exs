defmodule Hivebeam.Gateway.PolicyGateTest do
  use ExUnit.Case, async: true

  alias Hivebeam.Gateway.PolicyGate

  test "routes provider during session creation when mapping is configured" do
    previous = System.get_env("HIVEBEAM_GATEWAY_POLICY_PROVIDER_ROUTES")
    System.put_env("HIVEBEAM_GATEWAY_POLICY_PROVIDER_ROUTES", "codex=claude")

    on_exit(fn ->
      if previous do
        System.put_env("HIVEBEAM_GATEWAY_POLICY_PROVIDER_ROUTES", previous)
      else
        System.delete_env("HIVEBEAM_GATEWAY_POLICY_PROVIDER_ROUTES")
      end
    end)

    assert {:ok, decision} =
             PolicyGate.evaluate_session_create(%{
               "provider" => "codex",
               "cwd" => File.cwd!()
             })

    assert decision.provider == "claude"
    assert decision.audit.provider_requested == "codex"
    assert decision.audit.provider_selected == "claude"
  end

  test "denies prompts with secret-like content when configured" do
    previous = System.get_env("HIVEBEAM_GATEWAY_POLICY_DENY_SECRET_PROMPTS")
    System.put_env("HIVEBEAM_GATEWAY_POLICY_DENY_SECRET_PROMPTS", "true")

    on_exit(fn ->
      if previous do
        System.put_env("HIVEBEAM_GATEWAY_POLICY_DENY_SECRET_PROMPTS", previous)
      else
        System.delete_env("HIVEBEAM_GATEWAY_POLICY_DENY_SECRET_PROMPTS")
      end
    end)

    session = %{gateway_session_key: "hbs_test", provider: "codex"}

    assert {:error, {:policy_denied, details}} =
             PolicyGate.evaluate_prompt(session, "req-1", "api_key='super-secret'")

    assert details.reason == "secret_prompt_denied"
    assert details.classification.contains_secret
  end

  test "tool request policy enforces sandbox roots" do
    sandbox_root = unique_tmp_dir("policy_gate_root")
    outside_root = unique_tmp_dir("policy_gate_outside")

    session = %{
      gateway_session_key: "hbs_policy_tool",
      provider: "codex",
      cwd: sandbox_root,
      sandbox_roots: [sandbox_root],
      dangerously: false
    }

    request = %{
      operation: "fs/write_text_file",
      details: %{path: Path.join(outside_root, "blocked.txt")}
    }

    assert {:error, {:policy_denied, details}} =
             PolicyGate.evaluate_tool_request(session, request)

    assert get_in(details, [:reason, :reason]) == "sandbox_violation"
  end

  defp unique_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
