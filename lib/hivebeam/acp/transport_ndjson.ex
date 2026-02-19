defmodule Hivebeam.Acp.TransportNdjson do
  @moduledoc false

  @spec open_port(String.t(), [String.t()]) :: {:ok, port()} | {:error, term()}
  def open_port(path, args) when is_binary(path) and is_list(args) do
    with {:ok, executable} <- resolve_executable(path) do
      try do
        port =
          Port.open(
            {:spawn_executable, executable},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              :hide,
              args: args
            ]
          )

        {:ok, port}
      rescue
        error ->
          {:error, {:port_open_failed, error}}
      catch
        :exit, reason ->
          {:error, {:port_open_failed, reason}}
      end
    end
  end

  def open_port(_path, _args), do: {:error, :invalid_command}

  @spec send_message(port(), map()) :: :ok | {:error, term()}
  def send_message(port, payload) when is_port(port) and is_map(payload) do
    with {:ok, encoded} <- Jason.encode(payload),
         true <- Port.command(port, encoded <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:encode_failed, reason}}
      false -> {:error, :port_send_failed}
    end
  end

  def send_message(_port, _payload), do: {:error, :invalid_payload}

  @spec decode_lines(binary(), binary()) :: {[map()], binary()}
  def decode_lines(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    data = buffer <> chunk
    lines = String.split(data, "\n", trim: false)

    {complete_lines, [rest]} = Enum.split(lines, max(length(lines) - 1, 0))

    decoded =
      complete_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> [map | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    {decoded, rest}
  end

  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_executable(path) when is_binary(path) do
    executable = String.trim(path)

    cond do
      executable == "" ->
        {:error, :invalid_command}

      String.starts_with?(executable, "~/") ->
        expanded = Path.expand(executable)

        if File.exists?(expanded) do
          {:ok, expanded}
        else
          {:error, {:executable_not_found, expanded}}
        end

      Path.type(executable) == :absolute ->
        if File.exists?(executable) do
          {:ok, executable}
        else
          {:error, {:executable_not_found, executable}}
        end

      String.starts_with?(executable, "./") or String.starts_with?(executable, "../") ->
        expanded = Path.expand(executable, File.cwd!())

        if File.exists?(expanded) do
          {:ok, expanded}
        else
          {:error, {:executable_not_found, expanded}}
        end

      true ->
        case System.find_executable(executable) do
          nil -> {:error, {:executable_not_found, executable}}
          resolved -> {:ok, resolved}
        end
    end
  end
end
