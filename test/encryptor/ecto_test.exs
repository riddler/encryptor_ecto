defmodule Encryptor.EctoTest do
  use ExUnit.Case, async: true

  doctest Encryptor.Ecto

  test "the package scaffold compiles and the root module is loadable" do
    assert Code.ensure_loaded?(Encryptor.Ecto)
  end
end
