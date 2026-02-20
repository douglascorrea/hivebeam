defmodule Hivebeam.Gateway.PolicyGate do
  @moduledoc false

  alias Hivebeam.Gateway.Config
  alias Hivebeam.TerminalSandbox

  @email_regex ~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
  @ssn_regex ~r/\b\d{3}-\d{2}-\d{4}\b/

  @secret_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{16,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{24,}\b/,
    ~r/\b(?:api[_-]?key|secret|token|password)\b\s*[:=]\s*['\"][^'\"]+['\"]/i
  ]

  @spec evaluate_session_create(map()) :: {:ok, map()} | {:error, term()}
  def evaluate_session_create(attrs) when is_map(attrs) do
    requested_provider = normalize_provider(fetch(attrs, :provider) || "codex")
    raw_cwd = fetch(attrs, :cwd)
    approval_mode = normalize_approval_mode(fetch(attrs, :approval_mode))
    dangerously = normalize_dangerously(fetch(attrs, :dangerously))

    with {:ok, sandbox} <- Config.normalize_session_cwd(raw_cwd, dangerously: dangerously) do
      routed_provider = route_provider(requested_provider)

      {:ok,
       %{
         provider: routed_provider,
         approval_mode: approval_mode,
         sandbox: sandbox,
         audit:
           audit_payload("session_create", "allow", %{
             provider_requested: requested_provider,
             provider_selected: routed_provider,
             cwd: sandbox.cwd,
             dangerously: sandbox.dangerously
           })
       }}
    end
  end

  @spec evaluate_prompt(map(), String.t(), String.t()) ::
          {:ok, %{text: String.t(), provider: String.t(), audit: map(), classification: map()}}
          | {:error, {:policy_denied, map()}}
  def evaluate_prompt(session, request_id, text)
      when is_map(session) and is_binary(request_id) and is_binary(text) do
    requested_provider = normalize_provider(fetch(session, :provider) || "codex")
    classification = classify_prompt(text)
    {redacted_text, redacted?} = maybe_redact_prompt(text)

    routed_provider = route_provider(requested_provider)

    deny_reason =
      cond do
        Config.policy_deny_secret_prompts?() and classification.contains_secret ->
          "secret_prompt_denied"

        true ->
          nil
      end

    decision = if deny_reason, do: "deny", else: "allow"

    audit =
      audit_payload("prompt", decision, %{
        session_key: fetch(session, :gateway_session_key),
        request_id: request_id,
        provider_requested: requested_provider,
        provider_selected: routed_provider,
        classification: classification,
        redacted: redacted?,
        prompt_sha256: sha256(text),
        prompt_length: byte_size(text),
        redacted_prompt_length: byte_size(redacted_text)
      })

    if is_nil(deny_reason) do
      {:ok,
       %{
         text: redacted_text,
         provider: routed_provider,
         audit: audit,
         classification: classification
       }}
    else
      {:error,
       {:policy_denied,
        %{
          reason: deny_reason,
          classification: classification,
          audit: audit
        }}}
    end
  end

  @spec evaluate_tool_request(map(), map()) ::
          {:ok, %{operation: String.t(), audit: map(), classification: map()}}
          | {:error, {:policy_denied, map()}}
  def evaluate_tool_request(session, request) when is_map(session) and is_map(request) do
    operation = request |> fetch(:operation) |> normalize_operation()
    details = request |> fetch(:details) |> normalize_details()

    context = %{
      session_key: fetch(session, :gateway_session_key),
      sandbox_roots: normalize_roots(fetch(session, :sandbox_roots), fetch(session, :cwd)),
      dangerously: normalize_dangerously(fetch(session, :dangerously)),
      provider: fetch(session, :provider),
      terminal_sandbox_mode: Config.terminal_sandbox_mode(),
      terminal_sandbox_backend: :auto
    }

    evaluate_tool("tool_request", context, operation, details)
  end

  @spec evaluate_tool_operation(map(), String.t(), map()) ::
          {:ok, %{operation: String.t(), audit: map(), classification: map()}}
          | {:error, {:policy_denied, map()}}
  def evaluate_tool_operation(context, operation, details)
      when is_map(context) and is_binary(operation) and is_map(details) do
    normalized_context = %{
      session_key: fetch(context, :session_key),
      sandbox_roots: normalize_roots(fetch(context, :sandbox_roots), fetch(context, :tool_cwd)),
      dangerously: normalize_dangerously(fetch(context, :dangerously)),
      provider: fetch(context, :provider),
      terminal_sandbox_mode:
        normalize_terminal_sandbox_mode(
          fetch(context, :terminal_sandbox_mode) || Config.terminal_sandbox_mode()
        ),
      terminal_sandbox_backend: fetch(context, :terminal_sandbox_backend) || :auto
    }

    evaluate_tool("tool_operation", normalized_context, normalize_operation(operation), details)
  end

  defp evaluate_tool(stage, context, operation, details) do
    allowlist = Config.policy_tool_allowlist()
    extracted_path = extract_path(operation, details)

    deny_reason =
      cond do
        allowlist != [] and operation not in allowlist ->
          %{
            reason: "operation_not_allowed",
            operation: operation,
            allowlist: allowlist
          }

        operation == "terminal/create" and
            not TerminalSandbox.terminal_create_allowed?(
              dangerously: context.dangerously,
              mode: context.terminal_sandbox_mode,
              backend: context.terminal_sandbox_backend
            ) ->
          %{
            reason: "terminal_disabled_in_sandbox",
            operation: operation,
            mode: TerminalSandbox.mode_label(context.terminal_sandbox_mode),
            backend: TerminalSandbox.backend_label(context.terminal_sandbox_backend)
          }

        context.dangerously ->
          nil

        is_binary(extracted_path) ->
          case Config.ensure_path_allowed(extracted_path, context.sandbox_roots,
                 dangerously: false
               ) do
            :ok ->
              nil

            {:error, {:sandbox_violation, sandbox_details}} ->
              Map.put(sandbox_details, :reason, "sandbox_violation")

            {:error, reason} ->
              %{reason: "sandbox_check_failed", operation: operation, detail: inspect(reason)}
          end

        true ->
          nil
      end

    classification = %{
      operation: operation,
      has_path: is_binary(extracted_path),
      path: extracted_path,
      allowlist_active: allowlist != []
    }

    decision = if deny_reason, do: "deny", else: "allow"

    audit =
      audit_payload(stage, decision, %{
        session_key: context.session_key,
        provider: context.provider,
        operation: operation,
        classification: classification,
        reason: deny_reason
      })

    if is_nil(deny_reason) do
      {:ok, %{operation: operation, audit: audit, classification: classification}}
    else
      {:error,
       {:policy_denied, %{reason: deny_reason, audit: audit, classification: classification}}}
    end
  end

  defp classify_prompt(text) do
    secret_count = Enum.reduce(@secret_patterns, 0, &(&2 + count_matches(&1, text)))
    email_count = count_matches(@email_regex, text)
    ssn_count = count_matches(@ssn_regex, text)

    labels =
      []
      |> maybe_label(secret_count > 0, "secret")
      |> maybe_label(email_count > 0, "pii_email")
      |> maybe_label(ssn_count > 0, "pii_ssn")

    %{
      labels: labels,
      contains_secret: secret_count > 0,
      contains_pii: email_count > 0 or ssn_count > 0,
      secret_count: secret_count,
      email_count: email_count,
      ssn_count: ssn_count
    }
  end

  defp maybe_redact_prompt(text) do
    if Config.policy_redact_prompts?() do
      redacted =
        Enum.reduce(@secret_patterns, text, fn regex, acc ->
          Regex.replace(regex, acc, "[REDACTED_SECRET]")
        end)
        |> Regex.replace(@email_regex, "[REDACTED_EMAIL]")
        |> Regex.replace(@ssn_regex, "[REDACTED_SSN]")

      {redacted, redacted != text}
    else
      {text, false}
    end
  end

  defp count_matches(regex, text) do
    regex
    |> Regex.scan(text)
    |> length()
  end

  defp maybe_label(labels, true, label), do: [label | labels]
  defp maybe_label(labels, false, _label), do: labels

  defp route_provider(provider) do
    Map.get(Config.policy_provider_routes(), provider, provider)
  end

  defp audit_payload(stage, decision, payload) do
    base =
      payload
      |> Map.put(:stage, stage)
      |> Map.put(:decision, decision)
      |> Map.put(:ts, now_iso())

    if Config.policy_audit_enabled?() do
      Map.put(base, :audit_enabled, true)
    else
      Map.put(base, :audit_enabled, false)
    end
  end

  defp extract_path(operation, details) do
    case operation do
      "fs/read_text_file" -> fetch(details, :path)
      "fs/write_text_file" -> fetch(details, :path)
      "terminal/create" -> fetch(details, :cwd) || fetch(details, :path)
      _ -> fetch(details, :path) || fetch(details, :cwd)
    end
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp normalize_roots(roots, fallback) do
    fallback = if is_binary(fallback) and fallback != "", do: fallback, else: File.cwd!()

    roots
    |> List.wrap()
    |> Enum.reduce([], fn root, acc ->
      case Config.canonicalize_path(root) do
        {:ok, canonical_root} -> [canonical_root | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
    |> case do
      [] -> [fallback]
      values -> values
    end
  end

  defp normalize_details(value) when is_map(value), do: value
  defp normalize_details(_value), do: %{}

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "codex"
      value -> value
    end
  end

  defp normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  defp normalize_provider(_provider), do: "codex"

  defp normalize_approval_mode(mode) do
    case mode do
      :allow -> :allow
      :deny -> :deny
      "allow" -> :allow
      "deny" -> :deny
      _ -> :ask
    end
  end

  defp normalize_dangerously(value) when is_boolean(value), do: value

  defp normalize_dangerously(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      _ -> false
    end
  end

  defp normalize_dangerously(_value), do: false

  defp normalize_terminal_sandbox_mode(value) when value in [:required, :best_effort, :off],
    do: value

  defp normalize_terminal_sandbox_mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "required" -> :required
      "best_effort" -> :best_effort
      "best-effort" -> :best_effort
      "off" -> :off
      _ -> Config.terminal_sandbox_mode()
    end
  end

  defp normalize_terminal_sandbox_mode(_value), do: Config.terminal_sandbox_mode()

  defp normalize_operation(operation) when is_binary(operation) do
    case String.trim(operation) do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_operation(operation) when is_atom(operation) do
    operation
    |> Atom.to_string()
    |> normalize_operation()
  end

  defp normalize_operation(_operation), do: "unknown"

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
