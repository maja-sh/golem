# Status block grows from 1 line to 5, then shrinks back to 1.
# Exercises append-tail and clear-tail diff paths.

[
  {:pin, ["one"]},
  {:mark, :start},
  {:sleep, 50},
  {:pin, ["one", "two"]},
  {:sleep, 50},
  {:pin, ["one", "two", "three"]},
  {:sleep, 50},
  {:pin, ["one", "two", "three", "four"]},
  {:sleep, 50},
  {:pin, ["one", "two", "three", "four", "five"]},
  {:mark, :peak},
  {:sleep, 50},
  {:pin, ["one", "two", "three", "four"]},
  {:sleep, 50},
  {:pin, ["one", "two", "three"]},
  {:sleep, 50},
  {:pin, ["one", "two"]},
  {:sleep, 50},
  {:pin, ["one"]}
]
