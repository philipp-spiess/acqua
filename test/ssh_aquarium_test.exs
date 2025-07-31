defmodule SshAquariumTest do
  use ExUnit.Case
  doctest SshAquarium

  test "greets the world" do
    assert SshAquarium.hello() == :world
  end
end
