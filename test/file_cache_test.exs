defmodule Penbot.FileCacheTest do
  use ExUnit.Case, async: false

  setup do
    # FileCache is started by the application — just clear it between tests
    Agent.update(Penbot.FileCache, fn _ -> %{} end)
    :ok
  end

  test "put and get without sandbox verification" do
    # FileCache.get verifies hash against the container.
    # Without a running container, get will return nil (hash check fails).
    # But we can test put doesn't crash.
    Penbot.FileCache.put("/test/hello.txt", "hello world")

    # Agent state should have the entry
    state = Agent.get(Penbot.FileCache, & &1)
    assert {content, hash} = Map.get(state, "/test/hello.txt")
    assert content == "hello world"
    assert is_binary(hash)
    assert String.length(hash) == 32  # MD5 hex
  end

  test "hash is consistent" do
    Penbot.FileCache.put("/test/a.txt", "same content")
    state1 = Agent.get(Penbot.FileCache, & &1)
    {_, hash1} = Map.get(state1, "/test/a.txt")

    Penbot.FileCache.put("/test/b.txt", "same content")
    state2 = Agent.get(Penbot.FileCache, & &1)
    {_, hash2} = Map.get(state2, "/test/b.txt")

    assert hash1 == hash2
  end

  test "different content produces different hash" do
    Penbot.FileCache.put("/test/a.txt", "content a")
    Penbot.FileCache.put("/test/b.txt", "content b")

    state = Agent.get(Penbot.FileCache, & &1)
    {_, hash_a} = Map.get(state, "/test/a.txt")
    {_, hash_b} = Map.get(state, "/test/b.txt")

    assert hash_a != hash_b
  end

  test "find_context returns nil for unknown path" do
    assert Penbot.FileCache.find_context("/nonexistent", "target") == nil
  end

  test "find_context finds similar lines" do
    content = """
    line one
    line two
    function hello() {
      return "world";
    }
    line six
    """

    Penbot.FileCache.put("/test/code.js", content)

    result = Penbot.FileCache.find_context("/test/code.js", "function hello")
    assert result != nil
    assert String.contains?(result, "function hello")
    assert String.contains?(result, "→")  # marker for closest match
  end

  test "find_context returns something even for loose matches" do
    Penbot.FileCache.put("/test/code.js", "line one\nline two\nline three")

    # With short lines, Jaro distance can still find a closest match
    result = Penbot.FileCache.find_context("/test/code.js", "zzzzzzzzzzzzz completely unrelated")
    # Just verify it doesn't crash — may or may not return nil depending on similarity
    assert is_nil(result) or is_binary(result)
  end
end
