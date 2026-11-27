import Config

# Deployment settings come from the environment; the server's command loads them from `.env` (see .env.example).
need = fn key -> System.get_env(key) || raise "#{key} is not set (see .env.example)" end

config :air,
  port: String.to_integer(System.get_env("PORT", "5310")),
  api_port: String.to_integer(System.get_env("AIR_API_PORT", "5311")),
  data: need.("AIR_DATA"),
  region: System.get_env("AIR_REGION", "us-west-2"),
  model: System.get_env("AIR_MODEL", "us.anthropic.claude-sonnet-5-5"),
  thinking: System.get_env("AIR_THINKING", "adaptive"),
  effort: System.get_env("AIR_EFFORT", "low"),
  memory_model: System.get_env("AIR_MEMORY_MODEL", "us.anthropic.claude-opus-5-5"),
  gw_url: need.("AIR_GW_URL"),
  gw_model: System.get_env("AIR_GW_MODEL", "step-audio-editx"),
  gw_key_file: need.("AIR_GW_KEY_FILE"),
  app_secret_file: need.("AIR_APP_SECRET")
