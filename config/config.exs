import Config

config :penbot,
  container: "penbot-vm",
  planner_model: "claude-opus-4-20250514",
  executor_model: "claude-sonnet-4-20250514",
  planner_max_tokens: 16_000,
  executor_max_tokens: 16_000,
  thinking_budget: 10_000,
  max_steps: 200,
  command_timeout: 60_000,
  screenshot_dir: "screenshots",
  log_dir: "logs"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:step]

import_config "#{config_env()}.exs"
