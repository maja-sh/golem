defmodule PenbotTest do
  use ExUnit.Case
  doctest Penbot

  test "greets the world" do
    assert Penbot.hello() == :world
  end
end
