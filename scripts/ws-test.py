# Drives a call through the app like the web page: dial, say each argv line (waiting until things go quiet),
# print every message, save each speech's PCM as a wav in /tmp/air-test/.
import asyncio, base64, hashlib, hmac, json, os, secrets, sys, time, wave
import websockets
key = bytes.fromhex(open(os.path.expanduser("~/.config/app-auth/secret")).read().strip())
body = f"{int(time.time()) + 1200}.{secrets.token_urlsafe(9)}"
mac = base64.urlsafe_b64encode(hmac.new(key, body.encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
URL = os.environ.get("AIR_WS", "ws://localhost:5000/apps/loom-air/ws")
QUIET = float(os.environ.get("QUIET", "12"))
os.makedirs("/tmp/air-test", exist_ok=True)
T0 = time.time()

async def main():
    async with websockets.connect(URL, additional_headers={"Cookie": f"app_session={body}.{mac}"}, max_size=None) as ws:
        pcm, sid = bytearray(), None
        async def drain(quiet):
            nonlocal pcm, sid
            while True:
                try: m = await asyncio.wait_for(ws.recv(), quiet)
                except asyncio.TimeoutError: return
                if isinstance(m, bytes): pcm += m; continue
                d = json.loads(m)
                if d["type"] == "speech": sid, pcm = d["id"], bytearray()
                if d["type"] == "speech_end":
                    w = wave.open(f"/tmp/air-test/speech-{d['id']}.wav", "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(bytes(pcm)); w.close()
                    d["audio_s"] = round(len(pcm) / 48000, 2)
                if d["type"] == "hello": d["clips"] = len(d["clips"])
                print(f"{time.time()-T0:6.1f}", json.dumps(d, ensure_ascii=False)[:600], flush=True)
                if d["type"] == "ended": return
        await ws.send(json.dumps({"type": "dial"}))
        await drain(QUIET)
        for line in sys.argv[1:]:
            if line.startswith("wait:"): await drain(float(line[5:])); continue
            print(f"{time.time()-T0:6.1f} >>> {line}", flush=True)
            await ws.send(json.dumps({"type": "heard", "text": line}))
            await drain(QUIET)
        await ws.send(json.dumps({"type": "hangup"})); await drain(3)
asyncio.run(main())
