# End-to-end tests that actually hit the Anthropic API (and run
# Claude inside the container) are tagged `:e2e`. They are excluded
# by default because they cost money and can be slow.
#
# Run the e2e suite explicitly with:
#
#     mix test.e2e             # alias — runs only :e2e tests
#     mix test --only e2e      # equivalent
#     mix test --include e2e   # default tests + e2e
ExUnit.start(exclude: [:e2e])
