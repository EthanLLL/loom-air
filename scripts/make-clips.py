# Records the clips through infer-gw in one voice: data/clips/<voice>/<name>.wav.
# Usage: make-clips.py <voice> [name ...]   (no names = all; existing ones are redone only when named)
import json, os, subprocess, sys, time, requests
import env  # noqa: F401  (.env → os.environ)
VOICE = sys.argv[1]  # a voice registered on the workers; voices are private configuration, never a default here
ONLY = set(sys.argv[2:])
CLIPS = [
    # Played when nobody answers (Air.Call); a network announcement, so it then goes down the line too:
    # scripts/phone-line.py no_answer-raw.wav no_answer.wav
    ("no_answer-raw", "您拨打的电话暂时无人接听，请稍后再拨。"),
]
D = os.path.join(os.environ["AIR_DATA"], "clips", VOICE)
os.makedirs(D, exist_ok=True)
KEY = open(os.environ["AIR_GW_KEY_FILE"]).read().strip()
for name, text in CLIPS:
    out = f"{D}/{name}.wav"
    if os.path.exists(out) and name not in ONLY: continue
    if ONLY and name not in ONLY: continue
    t = time.time()
    r = requests.post(os.environ["AIR_GW_URL"] + "/v1/audio/speech", timeout=400, headers={"Authorization": f"Bearer {KEY}"},
                      json={"model": os.environ.get("AIR_GW_MODEL", "step-audio-editx"), "input": text, "voice": VOICE, "response_format": "wav",
                            "extra_params": {"temperature": 0.85}})
    r.raise_for_status()
    open(out, "wb").write(r.content)
    vol = subprocess.run(["ffmpeg", "-hide_banner", "-i", out, "-af", "volumedetect", "-f", "null", "-"], capture_output=True, text=True).stderr
    mean = [l.split(":")[1].strip() for l in vol.splitlines() if "mean_volume" in l]
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out], capture_output=True, text=True).stdout.strip()
    print(f"{name}: {time.time()-t:.1f}s, {dur}s audio, mean {mean} — {text}", flush=True)
