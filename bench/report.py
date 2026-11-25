# Builds the model comparison page from replay.exs output: report.py <bench dir> <clips.json>
import html, json, statistics, sys
from pathlib import Path

d = Path(sys.argv[1])
R = json.loads((d / "results.json").read_text())
clips = {c["name"]: c["text"] for c in json.loads(Path(sys.argv[2]).read_text())}
asr = {}
for line in (d / "asr.txt").read_text().splitlines():
    f, _, t = line.partition(" | ")
    asr[f.strip()] = t.strip()
notes = json.loads((d / "notes.json").read_text())
e = html.escape

# The recorded call, grouped by turn.
orig, cur = [], None
for ev in R["original"]:
    if ev["type"] == "turn_in":
        cur = []
        orig.append(cur)
    elif cur is not None:
        cur.append(ev)


def heard(inp):
    import re
    m = re.search(r"<heard>(.*?)</heard>", inp, re.S)
    if m:
        return "🗣 " + m.group(1)
    return "📞 接通（<call_started/> + 会话列表）"


def first_sound(rounds):
    t = 0
    for r in rounds:
        t += r["ms"]
        if r.get("says"):
            a = r.get("audio") or []
            return t + (a[0]["first_ms"] if a else 0)
        if any(x["name"] == "play_clip" for x in r.get("tools") or []):
            return t
    return None


def tool_html(x):
    name, inp = x["name"], x["input"]
    if name == "play_clip":
        n = inp.get("name", "")
        return (f'<div class="tool"><b>play_clip</b> {e(n)} <span class="muted">「{e(clips.get(n, ""))}」</span>'
                f'<audio controls preload="none" src="audio/clips/{e(n)}.mp3"></audio></div>')
    body = e(x["result"])
    cls = "tool" if x["ok"] else "tool bad"
    return (f'<details class="{cls}"><summary><b>{e(name)}</b> {e(json.dumps(inp, ensure_ascii=False))}</summary>'
            f'<pre>{body}</pre></details>')


def cell(turn, key):
    out = []
    for r in turn["rounds"]:
        if "error" in r:
            out.append(f'<div class="round"><span class="chip bad">{r["ms"]} ms</span> <span class="err">{e(r["error"][:300])}</span></div>')
            continue
        u = r.get("usage") or {}
        chips = [f'<span class="chip {"slow" if r["ms"] > 2500 else ""}" title="墙钟（含新加坡→俄勒冈网络）/ Bedrock 服务端">{r["ms"]} ms</span>',
                 f'<span class="mini">srv {r.get("server_ms")} · out {u.get("outputTokens")} tok · cache {u.get("cacheReadInputTokens", 0)}</span>']
        if r.get("reasoning"):
            chips.append('<span class="chip warn">推理</span>')
        if r.get("stop") == "max_tokens":
            chips.append('<span class="chip bad">max_tokens 截断</span>')
        parts = [f'<div class="chips">{"".join(chips)}</div>']
        for i, s in enumerate(r.get("says") or []):
            a = (r.get("audio") or [None] * 9)[i]
            parts.append(f'<div class="say">{e(s)}</div>')
            if a:
                f = a["file"].split("/")[-1]
                parts.append(f'<audio controls preload="none" src="{e(a["file"])}"></audio>'
                             f'<div class="mini">TTS 首字节 {a["first_ms"]} ms · 合成 {a["total_ms"]} ms · 音频 {a["audio_s"]} s</div>'
                             f'<div class="asr" title="faster-whisper small 把合成音频转回文字（含 ASR 自身误差）">ASR 回听：{e(asr.get(a["file"], ""))}</div>')
        for x in r.get("tools") or []:
            parts.append(tool_html(x))
        if not r.get("says") and not r.get("tools"):
            parts.append('<div class="err">（什么都没说，也没调工具）</div>')
        out.append(f'<div class="round">{"".join(parts)}</div>')
    fs = first_sound(turn["rounds"])
    head = f'<div class="fs">首个声音 {"%.1f s" % (fs / 1000) if fs else "—（无声）"}</div>'
    return head + "".join(out)


def orig_cell(evs):
    out = []
    for ev in evs:
        t = ev["type"]
        if t == "say":
            out.append(f'<div class="say">{e(ev["text"])}</div>')
        elif t == "clip_log":
            out.append(f'<div class="tool"><b>clip</b> {e(ev["name"])} <span class="muted">「{e(ev["text"])}」</span></div>')
        elif t == "tool" and ev["name"] != "play_clip":
            out.append(f'<div class="tool"><b>{e(ev["name"])}</b> {e(json.dumps(ev["input"], ensure_ascii=False))}</div>')
    return "".join(out)


runs = R["runs"]
# Summary
rows, grades = [], []
for run in runs:
    rs = [r for t in run["turns"] for r in t["rounds"]]
    ms = [r["ms"] for r in rs]
    srv = [r["server_ms"] for r in rs if r.get("server_ms")]
    fss = [first_sound(t["rounds"]) for t in run["turns"]]
    fs_ok = [x for x in fss if x]
    out_tok = sum((r.get("usage") or {}).get("outputTokens", 0) for r in rs)
    n = notes["models"][run["key"]]
    rows.append(f"""<tr><td><b>{e(run["name"])}</b><div class="mini">{e(run["id"])}<br>{e(json.dumps(run["settings"]))}</div></td>
<td>{len(rs)}</td><td>{int(statistics.median(ms))} ms</td><td>{max(ms)} ms</td><td>{int(statistics.median(srv)) if srv else "—"} ms</td>
<td>{"%.1f s" % (statistics.mean(fs_ok) / 1000)}{f' <span class="bad-t">（{fss.count(None)} 轮无声）</span>' if None in fss else ""}</td>
<td>{out_tok}</td>{"".join(f'<td class="{"ok" if v.startswith("✓") else "no" if v.startswith("✗") else "mid"}">{e(v)}</td>' for v in n["checks"])}</tr>""")
    grades.append(f'<li><b>{e(run["name"])}</b>：{e(n["grade"])}</li>')

grid = []
for i, inp in enumerate(R["inputs"]):
    cells = "".join(f'<td>{cell(run["turns"][i], run["key"])}</td>' for run in runs)
    grid.append(f"""<tr class="turnhead"><td colspan="{len(runs) + 1}"><b>第 {i + 1} 轮</b> {e(heard(inp))}
<details class="inline"><summary>完整输入</summary><pre>{e(inp)}</pre></details></td></tr>
<tr><td class="orig">{orig_cell(orig[i]) if i < len(orig) else ""}</td>{cells}</tr>""")

page = f"""<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Loom Air 接线员模型对比</title><style>
:root{{--bg:#0f1115;--card:#171a21;--line:#2a2f3a;--fg:#e6e8ee;--mut:#8b93a5;--ok:#3fb950;--bad:#f85149;--warn:#d29922;--acc:#58a6ff}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,"PingFang SC","Noto Sans CJK SC",sans-serif}}
main{{max-width:1700px;margin:0 auto;padding:24px}}h1{{font-size:22px;margin:0 0 4px}}h2{{font-size:17px;margin:28px 0 10px}}
.muted,.mini{{color:var(--mut)}}.mini{{font-size:12px}}table{{border-collapse:collapse;width:100%}}
th{{white-space:nowrap}}th,td{{border:1px solid var(--line);padding:8px;vertical-align:top;text-align:left}}th{{background:#1d212a;font-weight:600}}
.sum td{{min-width:64px}}.ok{{color:var(--ok)}}.no{{color:var(--bad)}}.mid{{color:var(--warn)}}
.grade{{white-space:normal!important;min-width:260px}}.bad-t{{color:var(--bad)}}
.grid td{{min-width:220px}}.turnhead td{{background:#1b2030}}.orig{{background:#14171d;color:#c9cdd6}}
.round{{border-left:2px solid var(--line);padding:2px 0 8px 8px;margin-bottom:6px}}.say{{background:#1f2633;border-radius:8px;padding:6px 8px;margin:4px 0}}
.chip{{display:inline-block;border-radius:10px;padding:0 7px;margin-right:4px;background:#24324a;color:#9cc3ff;font-size:12px}}
.chip.slow{{background:#4a2a24;color:#ffb3a8}}.chip.warn{{background:#3d3218;color:#f0c674}}.chip.bad{{background:#4a1e1e;color:#ff9d97}}
.fs{{font-weight:600;color:var(--acc);margin-bottom:6px}}.tool{{font-size:12.5px;background:#191e27;border:1px solid var(--line);border-radius:6px;padding:4px 6px;margin:4px 0}}
.tool.bad{{border-color:var(--bad)}}.err{{color:var(--bad);font-size:12.5px}}.asr{{font-size:12px;color:#a7b0c0;margin-top:2px}}
audio{{width:100%;height:30px;margin-top:4px}}pre{{white-space:pre-wrap;font-size:12px;margin:4px 0;max-height:260px;overflow:auto}}
details.inline{{display:inline-block;margin-left:10px}}summary{{cursor:pointer;color:var(--mut)}}
.box{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 18px}}.box li{{margin:4px 0}}
.scroll{{overflow-x:auto}}
</style></head><body><main>
<h1>Loom Air 接线员：五个模型回放对比</h1>
<div class="muted">脚本：最新一通真实通话 {e(R["call"])}（6 轮输入，原样回放）· 2026-11-25 · 每个模型跑一次</div>

<h2>结论</h2><div class="box">{notes["verdict"]}</div>

<h2>汇总</h2><div class="scroll"><table class="sum"><tr><th>模型 / 设置</th><th>模型调用</th><th>中位延迟</th><th>最慢</th><th>服务端中位</th><th>平均首个声音</th><th>输出 token</th>
{"".join(f"<th>{e(c)}</th>" for c in notes["check_names"])}</tr>{"".join(rows)}</table></div>
<div class="box" style="margin-top:10px"><ul>{"".join(grades)}</ul></div>
<div class="mini" style="margin-top:6px">延迟 = Loom Air（新加坡）发出 Converse 到收到完整响应的墙钟时间，含约 0.2–0.35 s 跨区网络；服务端 = Bedrock 返回的 latencyMs。
首个声音 = 从这一轮输入到用户听到第一个声音：录音片段立刻播放，TTS 再加首字节时间（约 0.8 s）。</div>

<h2>方法</h2><div class="box">{notes["method"]}</div>

<h2>逐轮对比</h2><div class="scroll"><table class="grid"><tr><th>原通话（生产 Haiku）</th>{"".join(f"<th>{e(r['name'])}</th>" for r in runs)}</tr>
{"".join(grid)}</table></div>

<h2>回放暴露的 Loom Air 问题（与模型无关）</h2><div class="box">{notes["bugs"]}</div>
</main></body></html>"""
(d / "index.html").write_text(page)
print("ok", d / "index.html")
