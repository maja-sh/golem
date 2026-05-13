# Scrolls tool-call results above a pinned 2-line status. Mimics the
# Golem TUI's typical pattern of tool invocation + ticker.

status = fn step ->
  [
    "[\e[33m→\e[0m] Investigate failure",
    " \e[36m⠋\e[0m Step #{step} · $0.0042"
  ]
end

[
  {:pin, status.(1)},
  {:mark, :start},
  {:sleep, 100},
  {:println, "  \e[2m$ ls /home/agent\e[0m \e[2m(8ms)\e[0m"},
  {:sleep, 100},
  {:println, "  \e[2m└ total 0\e[0m"},
  {:pin, status.(2)},
  {:sleep, 100},
  {:println, "  \e[2m↓ Read foo.ex\e[0m \e[2m(12ms)\e[0m"},
  {:pin, status.(3)},
  {:sleep, 100},
  {:println, "  \e[31m✗ shell\e[0m \e[2m(120ms)\e[0m"},
  {:pin, status.(4)}
]
