# Records the operator's clips through infer-gw in one voice: data/clips/<voice>/<name>.wav + clips.json.
# Usage: make-clips.py <voice> [name ...]   (no names = all; existing ones are redone only when named)
import json, os, subprocess, sys, time, requests
VOICE = sys.argv[1]  # a voice registered on the workers; voices are private configuration, never a default here
ONLY = set(sys.argv[2:])
CLIPS = [
    ("greet_1", "喂？哈咯，我在喔。"),
    ("greet_2", "欸，你来啦，怎么了呀？"),
    ("greet_3", "喂，听得到吗？我在这边喔。"),
    ("ack_1", "好喔，没问题。"),
    ("ack_2", "好的呀，交给我。"),
    ("ack_3", "嗯嗯，我知道了。"),
    ("handoff_1", "好，我帮你转给 Loom 喔。"),
    ("handoff_2", "我丢给 Loom 去做啦，好了跟你说。"),
    ("wait_1", "等我一下下喔。"),
    ("wait_2", "欸，我这边还在开机，稍等我一下啦。"),
    ("done_1", "搞定了喔！"),
    ("done_2", "好啦好啦，弄好了。"),
    ("sorry_1", "欸，我刚刚没听清楚，你再说一次好不好？"),
    ("bye_1", "好喔，那先这样，拜拜啦。"),
    ("bye_2", "嗯，拜拜，有事再叫我喔。"),
]
D = os.path.expanduser(f"~/work/loom-air/data/clips/{VOICE}")
os.makedirs(D, exist_ok=True)
KEY = open(os.path.expanduser("~/work/infer-gw/infra/keys/loom-air")).read().strip()
for name, text in CLIPS:
    out = f"{D}/{name}.wav"
    if os.path.exists(out) and name not in ONLY: continue
    if ONLY and name not in ONLY: continue
    t = time.time()
    r = requests.post("http://172.31.59.210:8090/v1/audio/speech", timeout=400, headers={"Authorization": f"Bearer {KEY}"},
                      json={"model": "step-audio-editx", "input": text, "voice": VOICE, "response_format": "wav",
                            "extra_params": {"temperature": 0.85}})
    r.raise_for_status()
    open(out, "wb").write(r.content)
    vol = subprocess.run(["ffmpeg", "-hide_banner", "-i", out, "-af", "volumedetect", "-f", "null", "-"], capture_output=True, text=True).stderr
    mean = [l.split(":")[1].strip() for l in vol.splitlines() if "mean_volume" in l]
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out], capture_output=True, text=True).stdout.strip()
    print(f"{name}: {time.time()-t:.1f}s, {dur}s audio, mean {mean} — {text}", flush=True)
json.dump([{"name": n, "text": t} for n, t in CLIPS], open(f"{D}/clips.json", "w"), ensure_ascii=False, indent=1)
