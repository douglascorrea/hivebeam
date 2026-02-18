defmodule Hivebeam.FileCompletionTest do
  use ExUnit.Case, async: true

  alias Hivebeam.FileCompletion

  test "complete_local_default_cwd uses the current working directory" do
    tmp_dir = temp_dir("file_completion_default_cwd")
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.cd!(tmp_dir, fn ->
      assert "lib/" in FileCompletion.complete_local_default_cwd("li")
    end)
  end

  test "complete/3 honors explicit cwd for local target" do
    tmp_dir = temp_dir("file_completion_explicit_cwd")
    File.mkdir_p!(Path.join(tmp_dir, "assets"))

    assert "assets/" in FileCompletion.complete(nil, "as", cwd: tmp_dir)
  end

  defp temp_dir(label) do
    path =
      Path.join(System.tmp_dir!(), "#{label}-#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
