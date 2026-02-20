defmodule Hivebeam.TerminalSandbox do
  @moduledoc false

  alias Hivebeam.Gateway.Config

  @restricted_read_prefixes ["/Users", "/Volumes", "/home"]

  @type mode :: :required | :best_effort | :off
  @type backend :: :sandbox_exec | :none

  @spec terminal_capability_enabled?(keyword()) :: boolean()
  def terminal_capability_enabled?(opts \\ []) do
    dangerously = normalize_dangerously(Keyword.get(opts, :dangerously, false))
    mode = normalize_mode(Keyword.get(opts, :mode, Config.terminal_sandbox_mode()))
    backend = resolve_backend(Keyword.get(opts, :backend, :auto))

    cond do
      dangerously ->
        true

      mode == :off ->
        false

      backend == :none ->
        mode == :best_effort

      true ->
        true
    end
  end

  @spec terminal_create_allowed?(keyword()) :: boolean()
  def terminal_create_allowed?(opts \\ []), do: terminal_capability_enabled?(opts)

  @spec wrap_command(String.t(), [term()], keyword()) ::
          {:ok, String.t(), [String.t()]} | {:error, map()}
  def wrap_command(command, args, opts \\ [])

  def wrap_command(command, args, opts) when is_binary(command) do
    args = Enum.map(List.wrap(args), &to_string/1)
    dangerously = normalize_dangerously(Keyword.get(opts, :dangerously, false))
    mode = normalize_mode(Keyword.get(opts, :mode, Config.terminal_sandbox_mode()))
    backend = resolve_backend(Keyword.get(opts, :backend, :auto))
    sandbox_roots = normalize_roots(Keyword.get(opts, :sandbox_roots, []))

    cond do
      dangerously ->
        {:ok, command, args}

      mode == :off ->
        {:error, disabled_reason(mode, backend)}

      backend == :none and mode == :required ->
        {:error, disabled_reason(mode, backend)}

      backend == :none and mode == :best_effort ->
        {:ok, command, args}

      backend == :sandbox_exec ->
        case System.find_executable("sandbox-exec") do
          nil ->
            case mode do
              :best_effort -> {:ok, command, args}
              _ -> {:error, disabled_reason(mode, :none)}
            end

          sandbox_exec ->
            profile = sandbox_exec_profile(sandbox_roots)
            {:ok, sandbox_exec, ["-p", profile, command | args]}
        end
    end
  end

  def wrap_command(_command, _args, _opts) do
    {:error, %{reason: "terminal_invalid_command"}}
  end

  @spec mode_label(mode()) :: String.t()
  def mode_label(mode), do: Atom.to_string(normalize_mode(mode))

  @spec backend_label(backend() | atom()) :: String.t()
  def backend_label(backend), do: backend |> normalize_backend() |> Atom.to_string()

  defp disabled_reason(mode, backend) do
    %{
      reason: "terminal_disabled_in_sandbox",
      mode: mode_label(mode),
      backend: backend_label(backend)
    }
  end

  defp resolve_backend(:auto), do: detect_backend()
  defp resolve_backend(value), do: normalize_backend(value)

  defp detect_backend do
    case :os.type() do
      {:unix, :darwin} ->
        if System.find_executable("sandbox-exec"), do: :sandbox_exec, else: :none

      _ ->
        :none
    end
  end

  defp normalize_backend(value) when value in [:sandbox_exec, :none], do: value

  defp normalize_backend(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "sandbox_exec" -> :sandbox_exec
      "sandbox-exec" -> :sandbox_exec
      "none" -> :none
      "auto" -> resolve_backend(:auto)
      _ -> :none
    end
  end

  defp normalize_backend(_value), do: :none

  defp normalize_mode(mode) when mode in [:required, :best_effort, :off], do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "required" -> :required
      "best_effort" -> :best_effort
      "best-effort" -> :best_effort
      "off" -> :off
      _ -> Config.terminal_sandbox_mode()
    end
  end

  defp normalize_mode(_mode), do: Config.terminal_sandbox_mode()

  defp normalize_roots(roots) do
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
      [] -> [File.cwd!()]
      values -> values
    end
  end

  defp sandbox_exec_profile(sandbox_roots) do
    [
      "(version 1)",
      "(allow default)",
      "(deny file-write* (regex \"^/\"))"
      | read_deny_rules() ++ read_allow_rules(sandbox_roots) ++ write_allow_rules(sandbox_roots)
    ]
    |> Enum.join("\n")
  end

  defp read_deny_rules do
    Enum.map(@restricted_read_prefixes, fn prefix ->
      "(deny file-read* (subpath \"#{escape_profile_path(prefix)}\"))"
    end)
  end

  defp read_allow_rules(sandbox_roots) do
    Enum.map(sandbox_roots, fn root ->
      "(allow file-read* (subpath \"#{escape_profile_path(root)}\"))"
    end)
  end

  defp write_allow_rules(sandbox_roots) do
    Enum.map(sandbox_roots, fn root ->
      "(allow file-write* (subpath \"#{escape_profile_path(root)}\"))"
    end)
  end

  defp escape_profile_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
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
end
