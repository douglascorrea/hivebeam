defmodule Hivebeam.UIKeymapTest do
  use ExUnit.Case, async: true

  alias Hivebeam.UI.Keymap
  alias TermUI.Event

  test "maps ctrl shortcuts" do
    assert {:ok, :toggle_left_pane} = Keymap.resolve(%Event.Key{key: "b", modifiers: [:ctrl]})
    assert {:ok, :refresh_status} = Keymap.resolve(%Event.Key{key: "r", modifiers: [:ctrl]})
    assert :ignore = Keymap.resolve(%Event.Key{key: "a", modifiers: [:ctrl]})
  end
end
