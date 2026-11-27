"""Make a recording sound like it came down a 2000s mobile line, for the ringback.

    python scripts/phone-line.py in.(wav|mp3|m4a) out.wav [--start S] [--length S]

A 2000s ringback was played from the network, so it was clean and loud:
band-limited to the phone's 300-3400 Hz, a little bright, squashed, and coded
to 8 kHz G.711 (--codec mulaw, the default) or GSM full rate, the harsher 2G
handset sound (--codec gsm); a faint hiss, no crackle unless asked for.
Written as 24 kHz s16le mono, what the client already plays.
"""
import argparse, subprocess, tempfile, os
import numpy as np

def ff(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)

def read(path, rate):
    out = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "s16le", "-ac", "1",
                          "-ar", str(rate), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(out, np.int16).astype(np.float32) / 32768

p = argparse.ArgumentParser()
p.add_argument("src"); p.add_argument("dst")
p.add_argument("--start", type=float, default=0); p.add_argument("--length", type=float, default=0)
p.add_argument("--noise", type=float, default=-62, help="hiss level, dBFS")
p.add_argument("--crackle", type=float, default=0, help="crackles per 10 s")
p.add_argument("--codec", choices=["mulaw", "gsm"], default="mulaw")
a = p.parse_args()

with tempfile.TemporaryDirectory() as d:
    cut = ["-ss", str(a.start)] + (["-t", str(a.length)] if a.length else [])
    # The handset: narrow band, loud and flat, faded in and out.
    fade = f",afade=t=in:d=0.3,areverse,afade=t=in:d=1.5,areverse"
    ff(*cut, "-i", a.src, "-ac", "1", "-af",
       "highpass=f=280:poles=2,highpass=f=280:poles=2,lowpass=f=3500:poles=2,lowpass=f=3500:poles=2,"
       "equalizer=f=2500:t=q:w=1:g=3,"
       "acompressor=threshold=-20dB:ratio=3:attack=10:release=150:makeup=4,alimiter=limit=0.7" + fade,
       "-ar", "8000", f"{d}/band.wav")
    # The codec: G.711 mu-law (64 kbit/s, the network's) or GSM full rate (13 kbit/s).
    coded = f"{d}/line.wav" if a.codec == "mulaw" else f"{d}/line.gsm"
    ff("-i", f"{d}/band.wav", "-c:a", "pcm_mulaw" if a.codec == "mulaw" else "libgsm", coded)
    x = read(coded, 8000)
    x = x / max(1e-6, float(np.abs(x).max())) * 0.8  # loud, as a ringback was, with room for the hiss

    # The line: a faint hiss, and crackles if asked for.
    rng = np.random.default_rng(7)
    hiss = rng.standard_normal(len(x)).astype(np.float32)
    hiss = np.convolve(hiss, np.ones(3) / 3, "same") * 10 ** (a.noise / 20) / 0.6
    crackle = np.zeros_like(x)
    for i in rng.integers(0, len(x), size=int(len(x) / 8000 / 10 * a.crackle)):
        n = int(rng.integers(20, 120))
        crackle[i:i + n] += rng.standard_normal(len(crackle[i:i + n])) * 0.02
    y = np.clip(x + hiss + crackle, -1, 1)

    pcm = (y * 32767).astype(np.int16).tobytes()
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", "8000", "-ac", "1",
                    "-i", "-", "-ar", "24000", "-c:a", "pcm_s16le", a.dst], input=pcm, check=True)
print(a.dst)
