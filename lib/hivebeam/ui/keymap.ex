defmodule Hivebeam.UI.Keymap do
  @moduledoc false

  alias TermUI.Event

  @shortcuts [
    {"Ctrl+B", :toggle_left_pane, "Toggle left pane"},
    {"Ctrl+G", :toggle_right_pane, "Toggle right pane"},
    {"Ctrl+L", :cycle_layout_mode, "Cycle layout mode"},
    {"Ctrl+K", :toggle_command_palette, "Command palette"},
    {"Ctrl+J", :toggle_target_switcher, "Target switcher"},
    {"Ctrl+R", :refresh_status, "Refresh target status"},
    {"Ctrl+X", :cancel_running_prompt, "Cancel running prompt"}
  ]

  @spec resolve(Event.Key.t()) :: {:ok, atom()} | :ignore
  def resolve(%Event.Key{key: key, modifiers: modifiers})
      when is_binary(key) and is_list(modifiers) do
    if :ctrl in modifiers do
      case String.downcase(key) do
        "b" -> {:ok, :toggle_left_pane}
        "g" -> {:ok, :toggle_right_pane}
        "l" -> {:ok, :cycle_layout_mode}
        "k" -> {:ok, :toggle_command_palette}
        "j" -> {:ok, :toggle_target_switcher}
        "r" -> {:ok, :refresh_status}
        "x" -> {:ok, :cancel_running_prompt}
        _ -> :ignore
      end
    else
      :ignore
    end
  end

  def resolve(_event), do: :ignore

  @spec shortcuts() :: [{String.t(), atom(), String.t()}]
  def shortcuts, do: @shortcuts

  @spec shortcuts_lines() :: [String.t()]
  def shortcuts_lines do
    Enum.map(@shortcuts, fn {combo, _event, description} ->
      "#{combo}: #{description}"
    end)
  end

  @spec footer_hint() :: String.t()
  def footer_hint do
    "Ctrl+B left pane | Ctrl+G right pane | Ctrl+L layout | Ctrl+K palette | Ctrl+J targets | Ctrl+R status | Ctrl+X cancel"
  end
end
