defmodule Hivebeam.TomlLite do
  @moduledoc false

  @type decoded :: map()

  @spec decode(String.t()) :: {:ok, decoded()} | {:error, term()}
  def decode(content) when is_binary(content) do
    lines = String.split(content, "\n")

    state = %{root: %{}, context: {:root, nil}}

    Enum.reduce_while(Enum.with_index(lines, 1), {:ok, state}, fn {raw_line, line_no},
                                                                  {:ok, acc} ->
      case parse_line(raw_line, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:line, line_no, reason}}}
      end
    end)
    |> case do
      {:ok, %{root: root}} -> {:ok, root}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(decoded()) :: String.t()
  def encode(map) when is_map(map) do
    {root_scalars, root_structured} = split_root_entries(map)

    root_lines =
      root_scalars
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> "#{key}=#{encode_value(value)}" end)

    section_lines =
      root_structured
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.flat_map(fn {key, value} ->
        encode_section(to_string(key), value)
      end)

    (root_lines ++ section_lines)
    |> Enum.join("\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp parse_line(raw_line, state) do
    line = raw_line |> strip_comments() |> String.trim()

    cond do
      line == "" ->
        {:ok, state}

      Regex.match?(~r/^\[\[[^\]]+\]\]$/, line) ->
        section =
          line
          |> String.trim_leading("[[")
          |> String.trim_trailing("]]")
          |> String.trim()

        {:ok, start_array_table(state, section)}

      Regex.match?(~r/^\[[^\]]+\]$/, line) ->
        section =
          line
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.trim()

        {:ok, start_table(state, section)}

      String.contains?(line, "=") ->
        parse_key_value(line, state)

      true ->
        {:error, {:invalid_line, line}}
    end
  end

  defp parse_key_value(line, state) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        if key == "" do
          {:error, :empty_key}
        else
          case parse_value(String.trim(raw_value)) do
            {:ok, value} -> {:ok, put_value(state, key, value)}
            {:error, reason} -> {:error, reason}
          end
        end

      _ ->
        {:error, {:invalid_assignment, line}}
    end
  end

  defp parse_value(raw) do
    cond do
      raw == "true" -> {:ok, true}
      raw == "false" -> {:ok, false}
      Regex.match?(~r/^-?\d+$/, raw) -> {:ok, String.to_integer(raw)}
      Regex.match?(~r/^".*"$/, raw) -> {:ok, decode_string(raw)}
      String.starts_with?(raw, "[") and String.ends_with?(raw, "]") -> parse_array(raw)
      raw == "" -> {:ok, ""}
      true -> {:ok, raw}
    end
  end

  defp parse_array(raw) do
    inner =
      raw
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim()

    if inner == "" do
      {:ok, []}
    else
      values =
        split_array_values(inner)
        |> Enum.map(&String.trim/1)

      Enum.reduce_while(values, {:ok, []}, fn token, {:ok, acc} ->
        case parse_value(token) do
          {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp split_array_values(inner) do
    do_split_array_values(String.graphemes(inner), [], "", false)
  end

  defp do_split_array_values([], acc, current, _in_quotes),
    do: acc ++ [current]

  defp do_split_array_values(["\"" | rest], acc, current, in_quotes) do
    do_split_array_values(rest, acc, current <> "\"", not in_quotes)
  end

  defp do_split_array_values(["," | rest], acc, current, false) do
    do_split_array_values(rest, acc ++ [current], "", false)
  end

  defp do_split_array_values([char | rest], acc, current, in_quotes) do
    do_split_array_values(rest, acc, current <> char, in_quotes)
  end

  defp decode_string(raw) do
    raw
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\\", "\\")
  end

  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_boolean(value), do: to_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)

  defp encode_value(value) when is_list(value) do
    encoded = value |> Enum.map(&encode_value/1) |> Enum.join(",")
    "[#{encoded}]"
  end

  defp encode_value(value), do: encode_string(to_string(value))

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  defp split_root_entries(root) do
    Enum.split_with(root, fn {_key, value} ->
      not is_map(value) and not (is_list(value) and Enum.all?(value, &is_map/1))
    end)
  end

  defp encode_section(name, value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {key, item} -> "#{key}=#{encode_value(item)}" end)

    ["", "[#{name}]" | entries]
  end

  defp encode_section(name, value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      value
      |> Enum.flat_map(fn item ->
        entries =
          item
          |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
          |> Enum.map(fn {key, item_value} -> "#{key}=#{encode_value(item_value)}" end)

        ["", "[[#{name}]]" | entries]
      end)
    else
      ["", "#{name}=#{encode_value(value)}"]
    end
  end

  defp start_table(state, section) do
    current = Map.get(state.root, section, %{})

    root =
      if is_map(current) do
        Map.put(state.root, section, current)
      else
        Map.put(state.root, section, %{})
      end

    %{state | root: root, context: {:table, section}}
  end

  defp start_array_table(state, section) do
    list = Map.get(state.root, section, [])
    list = if is_list(list), do: list, else: []
    index = length(list)
    root = Map.put(state.root, section, list ++ [%{}])
    %{state | root: root, context: {:array_table, section, index}}
  end

  defp put_value(%{context: {:root, _}} = state, key, value) do
    %{state | root: Map.put(state.root, key, value)}
  end

  defp put_value(%{context: {:table, section}} = state, key, value) do
    section_map =
      state.root
      |> Map.get(section, %{})
      |> Map.put(key, value)

    %{state | root: Map.put(state.root, section, section_map)}
  end

  defp put_value(%{context: {:array_table, section, index}} = state, key, value) do
    list = Map.get(state.root, section, [])

    updated =
      List.update_at(list, index, fn item ->
        item
        |> Kernel.||(%{})
        |> Map.put(key, value)
      end)

    %{state | root: Map.put(state.root, section, updated)}
  end

  defp strip_comments(raw_line) do
    do_strip_comments(String.graphemes(raw_line), "", false)
  end

  defp do_strip_comments([], acc, _in_quotes), do: acc

  defp do_strip_comments(["\"" | rest], acc, in_quotes) do
    do_strip_comments(rest, acc <> "\"", not in_quotes)
  end

  defp do_strip_comments(["#" | _rest], acc, false), do: acc

  defp do_strip_comments([char | rest], acc, in_quotes) do
    do_strip_comments(rest, acc <> char, in_quotes)
  end
end
