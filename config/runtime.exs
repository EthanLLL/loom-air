import Config

config :air,
  port: String.to_integer(System.get_env("PORT", "5310")),
  data: System.get_env("AIR_DATA", Path.expand("~/work/loom-air/data")),
  region: System.get_env("AIR_REGION", "us-west-2"),
  model: System.get_env("AIR_MODEL", "us.anthropic.claude-haiku-5-5"),
  thinking: System.get_env("AIR_THINKING", "disabled"),
  gw_url: System.get_env("AIR_GW_URL", "http://172.31.59.210:8090"),
  gw_model: System.get_env("AIR_GW_MODEL", "step-audio-editx"),
  gw_key_file: System.get_env("AIR_GW_KEY_FILE", Path.expand("~/work/infer-gw/infra/keys/loom-air")),
  app_secret_file: System.get_env("AIR_APP_SECRET", Path.expand("~/.config/app-auth/secret"))
