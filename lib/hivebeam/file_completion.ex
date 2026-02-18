defmodule Hivebeam.FileCompletion do
  @moduledoc false

  @default_timeout_ms 1_500
  @max_results 100

  @spec complete(node() | nil, String.t(), keyword()) :: [String.t()]
  def complete(node, prefix, opts \\ [])
      when (is_atom(node) or is_nil(node)) and is_binary(prefix) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_ms)

    cond do
      is_nil(node) or node == Node.self() ->
        complete_local(prefix, cwd)

      true ->
        :erpc.call(node, __MODULE__, :complete_local, [prefix, cwd], timeout_ms)
    end
  catch
    :exit, _reason ->
      []
  end

  @spec complete_local(String.t(), String.t()) :: [String.t()]
  def complete_local(prefix, cwd) when is_binary(prefix) and is_binary(cwd) do
    {directory, partial} = split_prefix(prefix)
    absolute_dir = Path.expand(directory, cwd)

    with {:ok, entries} <- File.ls(absolute_dir) do
      entries
      |> Enum.reject(&skip_hidden?(&1, partial))
      |> Enum.filter(&String.starts_with?(&1, partial))
      |> Enum.map(fn entry ->
        relative =
          if directory in [".", ""], do: entry, else: Path.join(directory, entry)

        case File.dir?(Path.join(absolute_dir, entry)) do
          true -> relative <> "/"
          false -> relative
        end
      end)
      |> Enum.sort()
      |> Enum.take(@max_results)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp split_prefix(prefix) do
    normalized =
      prefix
      |> String.trim()
      |> String.replace("\\", "/")

    cond do
      normalized == "" ->
        {".", ""}

      String.ends_with?(normalized, "/") ->
        {trim_trailing_slash(normalized), ""}

      true ->
        {Path.dirname(normalized), Path.basename(normalized)}
    end
  end

  defp trim_trailing_slash(path) do
    trimmed = String.trim_trailing(path, "/")
    if trimmed == "", do: ".", else: trimmed
  end

  defp skip_hidden?(entry, partial) do
    String.starts_with?(entry, ".") and not String.starts_with?(partial, ".")
  end
end
