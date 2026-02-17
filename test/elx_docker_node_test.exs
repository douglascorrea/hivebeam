defmodule ElxDockerNodeTest do
  use ExUnit.Case
  doctest ElxDockerNode

  test "greets the world" do
    assert ElxDockerNode.hello() == :world
  end
end
