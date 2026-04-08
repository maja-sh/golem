import Config

config :penbot,
  # Container to exec into
  container: "penbot-vm",

  # Claude models
  planner_model: "claude-opus-4-20250514",
  executor_model: "claude-sonnet-4-20250514",

  # Token limits
  planner_max_tokens: 4096,
  executor_max_tokens: 4096,

  # Thinking budget for extended thinking
  thinking_budget: 10_000,

  # Max steps before the runner gives up
  max_steps: 200,

  # Command timeout in the sandbox (ms)
  command_timeout: 60_000,

  # Directory to save screenshots (on host)
  screenshot_dir: "screenshots"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:step]

import_config "#{config_env()}.exs"
