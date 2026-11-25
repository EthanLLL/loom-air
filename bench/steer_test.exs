# Two submits to one session, the second while the first turn runs (steered): each reply must come once.
for app <- [:finch, :jason, :aws_signature, :mint_web_socket], do: Application.ensure_all_started(app)
{:ok, _} = Finch.start_link(name: Air.Finch)
{:ok, _} = Registry.start_link(keys: :unique, name: Air.Registry)
{:ok, _} = DynamicSupervisor.start_link(name: Air.Sup, strategy: :one_for_one)
{:ok, t} = Air.Config.tenant(System.get_env("TENANT") || Air.Config.default_tenant())
t0 = System.monotonic_time(:millisecond)
log = fn x -> IO.puts("#{(System.monotonic_time(:millisecond) - t0) / 1000}s #{x}") end
{:ok, s} = Air.Loom.create(t, "Air 测试：steer 去重")
id = s["id"]
submit = fn text ->
  {:ok, list} = Air.LoomSocket.sessions(t)
  seq = (Enum.find(list, &(&1["id"] == id)) || %{})["seq"] || 0
  cmid = "air_test_" <> Integer.to_string(System.unique_integer([:positive]))
  :ok = Air.LoomSocket.subscribe(t, id, seq, self())
  {:ok, r} = Air.Loom.submit(t, id, text, cmid)
  log.("submitted #{cmid}: #{r["status"]}")
end
submit.("请用 Bash 运行 sleep 20，然后写一段大约三百字的短文介绍猫，最后以“甲”结尾。")
Process.sleep(String.to_integer(System.get_env("DELAY", "6000")))
submit.("再补一句：之后另外只回复一个字：乙。")
collect = fn collect, n ->
  receive do
    m -> log.(inspect(m, printable_limit: 80)); collect.(collect, n + 1)
  after 90_000 -> n
  end
end
log.("messages: #{collect.(collect, 0)}")
IO.puts("session #{id}")
