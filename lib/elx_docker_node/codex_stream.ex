defmodule ElxDockerNode.CodexStream do
  @moduledoc false

  @max_depth 8

  @message_direct_paths [
    [:content, :text],
    [:content, :delta, :text],
    [:delta, :text],
    [:text],
    [:content, :content],
    [:content, :parts],
    [:parts],
    [:message, :text],
    [:output, :text]
  ]

  @thought_direct_paths [
    [:content, :thought],
    [:content, :reasoning],
    [:delta, :thought],
    [:delta, :reasoning],
    [:thought],
    [:reasoning],
    [:analysis],
    [:content, :text],
    [:text]
  ]

  @message_keys ~w(text value output_text message delta)a
  @thought_keys ~w(thought reasoning analysis text value delta)a
  @container_keys ~w(content contents delta part parts item items chunk chunks input output message messages result payload)a
  @explore_tokens [
    "search",
    "find",
    "list",
    "read",
    "open",
    "inspect",
    "glob",
    "grep",
    "ls",
    "pwd"
  ]
  @write_tokens [
    "write",
    "edit",
    "patch",
    "apply_patch",
    "create",
    "update",
    "delete",
    "rename",
    "move",
    "mkdir",
    "touch"
  ]
  @verify_tokens ["test", "lint", "build", "compile", "check", "validate", "verify"]
  @execute_tokens ["execute", "run", "terminal", "bash", "sh", "python", "node"]

  @spec update_kind(map()) :: String.t()
  def update_kind(update) when is_map(update) do
    fetch(update, :type) ||
      fetch(update, :sessionUpdate) ||
      fetch(update, :session_update) ||
      fetch(update, :kind) ||
      "unknown"
  end

  def update_kind(_), do: "unknown"

  @spec message_chunks(map()) :: [String.t()]
  def message_chunks(update) when is_map(update) do
    chunks = collect_direct_paths(update, @message_direct_paths, :message)
    if chunks == [], do: deep_scan(update, :message, 0), else: chunks
  end

  def message_chunks(_), do: []

  @spec thought_chunks(map()) :: [String.t()]
  def thought_chunks(update) when is_map(update) do
    chunks = collect_direct_paths(update, @thought_direct_paths, :thought)
    if chunks == [], do: deep_scan(update, :thought, 0), else: chunks
  end

  def thought_chunks(_), do: []

  @spec tool_call_id(map()) :: String.t() | nil
  def tool_call_id(update) when is_map(update) do
    fetch(update, :tool_call_id) || fetch(update, :toolCallId)
  end

  def tool_call_id(_), do: nil

  @spec tool_title(map()) :: String.t() | nil
  def tool_title(update) when is_map(update) do
    fetch(update, :title) || infer_tool_title(update)
  end

  def tool_title(_), do: nil

  @spec tool_kind(map()) :: String.t() | nil
  def tool_kind(update) when is_map(update) do
    fetch(update, :kind)
  end

  def tool_kind(_), do: nil

  @spec tool_status(map()) :: String.t() | nil
  def tool_status(update) when is_map(update) do
    fetch(update, :status)
  end

  def tool_status(_), do: nil

  @spec tool_summary(map()) :: String.t()
  def tool_summary(update) when is_map(update) do
    tool_id = tool_call_id(update)
    title = tool_title(update)
    kind = tool_kind(update)
    status = tool_status(update)

    primary =
      cond do
        is_binary(title) and title != "" ->
          title

        is_binary(kind) and kind != "" ->
          "tool kind=#{kind}"

        is_binary(tool_id) and tool_id != "" ->
          "tool id=#{tool_id}"

        true ->
          "tool"
      end

    [
      primary,
      if(is_binary(title) and is_binary(tool_id), do: "id=#{tool_id}", else: nil),
      if(is_binary(title), do: maybe_tag("kind", kind), else: nil),
      maybe_tag("status", status)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def tool_summary(_), do: "tool"

  @spec tool_activity(map()) :: String.t()
  def tool_activity(update) when is_map(update) do
    blob = tool_activity_blob(update)

    cond do
      blob == "" -> "Working"
      includes_any?(blob, @explore_tokens) -> "Exploring"
      includes_any?(blob, @write_tokens) -> "Writing"
      includes_any?(blob, @verify_tokens) -> "Verifying"
      includes_any?(blob, @execute_tokens) -> "Executing"
      true -> "Working"
    end
  end

  def tool_activity(_), do: "Working"

  defp maybe_tag(_label, value) when not is_binary(value), do: nil
  defp maybe_tag(label, value), do: "#{label}=#{value}"

  defp tool_activity_blob(update) do
    raw_input = fetch(update, :raw_input) || fetch(update, :rawInput) || %{}

    args =
      raw_input
      |> fetch(:args)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    [
      tool_kind(update),
      tool_title(update),
      fetch(raw_input, :command),
      args,
      tool_content_title(update)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp includes_any?(value, tokens) do
    Enum.any?(tokens, &String.contains?(value, &1))
  end

  defp infer_tool_title(update) do
    with raw_input when is_map(raw_input) <- fetch(update, :raw_input) || fetch(update, :rawInput),
         command when is_binary(command) and command != "" <- fetch(raw_input, :command) do
      args =
        raw_input
        |> fetch(:args)
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      ([command] ++ args)
      |> Enum.join(" ")
      |> String.trim()
      |> case do
        "" -> nil
        title -> title
      end
    else
      _ ->
        tool_content_title(update)
    end
  end

  defp tool_content_title(update) do
    update
    |> fetch(:content)
    |> List.wrap()
    |> Enum.find_value(fn
      value when is_binary(value) and value != "" ->
        value

      value when is_map(value) ->
        text = fetch(value, :text)
        if is_binary(text) and text != "", do: text, else: nil

      _ ->
        nil
    end)
  end

  defp collect_direct_paths(update, paths, channel) do
    paths
    |> Enum.flat_map(fn path ->
      update
      |> fetch_path(path)
      |> extract_text_values(channel, 0)
    end)
    |> normalize_chunks()
  end

  defp fetch_path(value, []), do: value

  defp fetch_path(map, [key | rest]) when is_map(map) do
    map
    |> fetch(key)
    |> fetch_path(rest)
  end

  defp fetch_path(_value, _path), do: nil

  defp deep_scan(value, channel, depth) when depth > @max_depth do
    _ = value
    _ = channel
    []
  end

  defp deep_scan(value, channel, depth) do
    value
    |> extract_text_values(channel, depth)
    |> normalize_chunks()
  end

  defp extract_text_values(nil, _channel, _depth), do: []

  defp extract_text_values(value, _channel, _depth) when is_binary(value) do
    [value]
  end

  defp extract_text_values(value, channel, depth) when is_list(value) do
    Enum.flat_map(value, &extract_text_values(&1, channel, depth + 1))
  end

  defp extract_text_values(value, channel, depth) when is_map(value) do
    keys = preferred_keys(channel)

    direct_values =
      keys
      |> Enum.flat_map(fn key ->
        value
        |> fetch(key)
        |> extract_text_values(channel, depth + 1)
      end)

    nested_values =
      @container_keys
      |> Enum.flat_map(fn key ->
        value
        |> fetch(key)
        |> extract_text_values(channel, depth + 1)
      end)

    direct_values ++ nested_values
  end

  defp extract_text_values(_value, _channel, _depth), do: []

  defp preferred_keys(:thought), do: @thought_keys
  defp preferred_keys(:message), do: @message_keys

  defp normalize_chunks(chunks) do
    chunks
    |> Enum.map(&normalize_chunk/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> dedupe_preserving_order()
  end

  defp normalize_chunk(chunk) do
    chunk
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(<<0>>, "")
  end

  defp dedupe_preserving_order(values) do
    {result, _seen} =
      Enum.reduce(values, {[], MapSet.new()}, fn value, {acc, seen} ->
        if MapSet.member?(seen, value) do
          {acc, seen}
        else
          {[value | acc], MapSet.put(seen, value)}
        end
      end)

    Enum.reverse(result)
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil
end
