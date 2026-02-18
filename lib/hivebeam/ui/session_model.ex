defmodule Hivebeam.UI.SessionModel do
  @moduledoc false

  @typedoc "Common UI event shape shared by TUI and optional LiveView addon"
  @type event :: %{
          required(:kind) =>
            :message_chunk
            | :thought_chunk
            | :tool_update
            | :approval_request
            | :status_update
            | :layout_update
            | :target_update,
          optional(:node) => String.t() | nil,
          optional(:payload) => map()
        }

  @spec message_chunk(String.t() | nil, String.t()) :: event()
  def message_chunk(node, text), do: %{kind: :message_chunk, node: node, payload: %{text: text}}

  @spec thought_chunk(String.t() | nil, String.t()) :: event()
  def thought_chunk(node, text), do: %{kind: :thought_chunk, node: node, payload: %{text: text}}

  @spec tool_update(String.t() | nil, map()) :: event()
  def tool_update(node, payload), do: %{kind: :tool_update, node: node, payload: payload}

  @spec approval_request(String.t() | nil, map()) :: event()
  def approval_request(node, payload),
    do: %{kind: :approval_request, node: node, payload: payload}

  @spec status_update(String.t() | nil, map()) :: event()
  def status_update(node, payload), do: %{kind: :status_update, node: node, payload: payload}

  @spec layout_update(map()) :: event()
  def layout_update(payload), do: %{kind: :layout_update, payload: payload}

  @spec target_update(map()) :: event()
  def target_update(payload), do: %{kind: :target_update, payload: payload}
end
