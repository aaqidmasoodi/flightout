# Usage: python3 tools/build_mask_sounds.py assets/audio/pilot
# Oxygen-mask breathing sounds for FlightOut, synthesized (no recordings): filtered noise through the mask's
# resonances, the demand valve's click and hiss on the inhale, the exhalation valve's flutter on the exhale,
# and a forceful straining exhale ("hick") for the anti-G straining manoeuvre.
import numpy as np, scipy.signal as sg, scipy.io.wavfile as wf, sys, os
SR = 44100
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(7)

def bp(x, lo, hi, order=2):
    sos = sg.butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return sg.sosfilt(sos, x)

def peak(x, f, q, gain):
    b, a = sg.iirpeak(f, q, fs=SR)
    return x + gain * sg.lfilter(b, a, x)

def pink(n):
    w = rng.standard_normal(n)
    b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
    a = [1, -2.494956002, 2.017265875, -0.522189400]
    return sg.lfilter(b, a, w)

def env(n, att, dec, shape=1.6):
    t = np.linspace(0, 1, n)
    a = np.clip(t / att, 0, 1) ** shape
    d = np.clip((1 - t) / dec, 0, 1) ** shape
    return a * d

def click(n_total, at, f=2400, ms=4, amp=0.5):
    x = np.zeros(n_total)
    n = int(SR * ms / 1000)
    c = rng.standard_normal(n) * np.exp(-np.linspace(0, 6, n))
    c = bp(c, f * 0.5, min(f * 2, 9000))
    x[at:at + n] += c * amp
    return x

def norm(x, peak_db=-6.0):
    x = x - np.mean(x)
    m = np.max(np.abs(x)) + 1e-9
    return x / m * 10 ** (peak_db / 20)

def save(name, x):
    fade = int(SR * 0.01)
    x[:fade] *= np.linspace(0, 1, fade); x[-fade:] *= np.linspace(1, 0, fade)
    wf.write(os.path.join(out, name), SR, (x * 32767).astype(np.int16))

for k in range(3):
    # inhale: the demand valve opens (click), air rushes through the regulator (hiss with a resonance)
    dur = 0.85 + 0.12 * k
    n = int(SR * dur)
    x = pink(n) * 0.7 + rng.standard_normal(n) * 0.3
    x = bp(x, 500, 5200)
    x = peak(x, 1150 + 90 * k, 6, 1.4)
    x = peak(x, 2600 - 120 * k, 5, 1.0)
    x = x * env(n, 0.35, 0.45)
    x += click(n, int(SR * 0.02), 2600, 5, 2.5 * np.max(np.abs(x)))
    save("mask_in_%d.wav" % k, norm(x, -9.0))
    # exhale: softer, lower, through the exhalation valve (a slight flutter), into the mask
    dur = 1.0 + 0.15 * k
    n = int(SR * dur)
    x = pink(n)
    x = bp(x, 220, 3000)
    x = peak(x, 520 + 60 * k, 4, 1.6)
    x = peak(x, 1500, 5, 0.8)
    t = np.arange(n) / SR
    flutter = 1.0 + 0.18 * np.sin(2 * np.pi * (23 + 4 * k) * t) * env(n, 0.2, 0.6)
    x = x * env(n, 0.12, 0.6) * flutter
    x += click(n, int(SR * 0.01), 1400, 6, 1.2 * np.max(np.abs(x)))
    save("mask_out_%d.wav" % k, norm(x, -12.0))
    # straining "hick": a short, forceful exhale against a closed glottis, then a quick release
    dur = 0.42 + 0.05 * k
    n = int(SR * dur)
    t = np.arange(n) / SR
    f0 = 105 + 12 * k
    voice = sum(np.sin(2 * np.pi * f0 * h * t + rng.uniform(0, 6.28)) / h ** 1.3 for h in range(1, 14))
    voice = bp(voice, 120, 2400)
    voice = peak(voice, 650, 4, 1.5)
    breath = bp(pink(n), 300, 4000)
    x = (0.45 * voice / np.max(np.abs(voice)) + 0.8 * breath / np.max(np.abs(breath))) * env(n, 0.06, 0.55, 1.2)
    x += click(n, int(SR * 0.005), 1800, 6, 0.4)
    save("mask_strain_%d.wav" % k, norm(x, -8.0))
print("ok")
