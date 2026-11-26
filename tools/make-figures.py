#!/usr/bin/env python3
# Generate the report figures from captured evidence (run on the HOST).
#   python3 tools/make-figures.py
# Reads evidence/*.csv|txt and writes report/figures/fig_*.svg
import csv, glob, json, os, re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EV = os.path.join(ROOT, "evidence")
FIG = os.path.join(ROOT, "report", "figures")
os.makedirs(FIG, exist_ok=True)

# restrained, colour-blind-safe palette
CAUSE, SYMPTOM, GOOD, BAD, NEU = "#2563eb", "#f59e0b", "#2563eb", "#dc2626", "#9ca3af"
plt.rcParams.update({"font.size": 11, "axes.spines.top": False, "axes.spines.right": False,
                     "figure.dpi": 110, "svg.fonttype": "none"})

def latest(pat):
    xs = sorted(glob.glob(os.path.join(EV, pat)))
    return xs[-1] if xs else None

# ---------- Fig 1: scalability ----------
def fig_scalability():
    f = latest("scalability-*.csv")
    if not f: return print("skip scalability (no csv)")
    rows = list(csv.DictReader(open(f)))
    N = [r["sensors"] for r in rows]
    tp = [float(r["throughput_rps"]) for r in rows]
    p95 = [float(r["p95_ms"]) for r in rows]
    x = range(len(N))
    fig, ax1 = plt.subplots(figsize=(6.2, 3.6))
    ax1.bar(x, tp, width=0.55, color=GOOD, label="throughput (req/s)")
    ax1.set_xticks(list(x)); ax1.set_xticklabels([f"{n} sensors" for n in N])
    ax1.set_ylabel("accepted throughput (req/s)", color=GOOD)
    ax1.tick_params(axis="y", labelcolor=GOOD)
    for xi, t in zip(x, tp): ax1.text(xi, t+2, f"{t:.0f}", ha="center", color=GOOD, fontsize=10)
    ax2 = ax1.twinx(); ax2.spines["top"].set_visible(False)
    ax2.plot(x, p95, "o-", color=BAD, label="p95 latency (ms)")
    ax2.set_ylabel("client p95 latency (ms)", color=BAD); ax2.tick_params(axis="y", labelcolor=BAD)
    for xi, p in zip(x, p95): ax2.text(xi, p+80, f"{p:.0f}", ha="center", color=BAD, fontsize=10)
    ax1.set_title("Pipeline scalability: throughput saturates,\nthen collapses at the HTTP-concurrency wall", fontsize=10.5)
    ax2.annotate("accept-queue collapse\n(≈3 s timeout)", xy=(2, p95[-1]), xytext=(1.05, p95[-1]*0.72),
                 color=BAD, fontsize=9, arrowprops=dict(arrowstyle="->", color=BAD))
    fig.tight_layout(); out=os.path.join(FIG,"fig_scalability.svg"); fig.savefig(out, bbox_inches='tight'); plt.close(fig)
    print("wrote", out)

# ---------- Fig 2: root-cause correlation ----------
def fig_correlation():
    f = latest("correlation-*.txt")
    if not f: return print("skip correlation (no evidence)")
    t = open(f).read()
    shown = int(re.search(r"SHOWN\s*\(root causes\)\s*:\s*(\d+)", t).group(1))
    inhib = int(re.search(r"INHIBITED \(symptoms\)\s*:\s*(\d+)", t).group(1))
    fig, ax = plt.subplots(figsize=(6.2, 2.5))
    ax.barh(["Alerts fired"], [shown], color=CAUSE, label="root causes (shown)")
    ax.barh(["Alerts fired"], [inhib], left=[shown], color=SYMPTOM, label="symptoms (inhibited)")
    ax.barh(["Shown to operator"], [shown], color=CAUSE)
    ax.set_xlabel("number of alerts"); ax.set_xlim(0, shown+inhib+0.6)
    ax.text(shown/2, 1, str(shown), ha="center", va="center", color="white", fontsize=11, fontweight="bold")
    ax.text(shown+inhib/2, 1, str(inhib), ha="center", va="center", color="white", fontsize=11, fontweight="bold")
    ax.text(shown/2, 0, str(shown), ha="center", va="center", color="white", fontsize=11, fontweight="bold")
    ax.set_title(f"Root-cause correlation: a {shown+inhib}-alert cascade,\n"
                 f"inhibition leaves the {shown} root causes to fix", fontsize=10.5)
    ax.legend(loc="lower right", fontsize=9, frameon=False)
    fig.tight_layout(); out=os.path.join(FIG,"fig_correlation.svg"); fig.savefig(out, bbox_inches='tight'); plt.close(fig)
    print("wrote", out)

# ---------- Fig 3: identity vs IP ----------
def fig_identity_vs_ip():
    f = latest("identity-vs-ip-*.txt")
    if not f: return print("skip identity (no evidence)")
    dicts = [json.loads(m) for m in re.findall(r"\{.*\}", open(f).read())]
    perip, perid = dicts[0], dicts[1]
    fig, (axa, axb) = plt.subplots(1, 2, figsize=(7.2, 3.4), gridspec_kw={"width_ratios":[1.1,1]})
    # left: legitimate node served %
    vals = [perip["legit_served_pct"], perid["legit_served_pct"]]
    cols = [BAD, GOOD]
    axa.bar([0,1], vals, width=0.6, color=cols)
    axa.set_xticks([0,1]); axa.set_xticklabels(["per-IP\n(iptables)", "per-identity\n(token bucket)"])
    axa.set_ylabel("legitimate sensors served (%)"); axa.set_ylim(0,105)
    for xi,v in zip([0,1],vals): axa.text(xi, v+2, f"{v:.0f}%", ha="center", fontsize=11, fontweight="bold")
    axa.set_title("One node, 50 identities, one IP")
    # right: what happens to a flood that reuses ONE identity, under per-identity
    shed, got = perid["flood_429"], perid["flood_ok"]
    axb.bar([0], [shed], width=0.5, color=GOOD, label="shed (429)")
    axb.bar([0], [got], bottom=[shed], width=0.5, color=NEU, label="passed")
    axb.set_xticks([0]); axb.set_xticklabels(["flood reusing\none identity"])
    axb.set_ylabel("requests"); axb.set_title("Per-identity still sheds abuse")
    axb.text(0, shed/2, f"{shed}\nshed", ha="center", va="center", color="white", fontweight="bold", fontsize=10)
    axb.legend(fontsize=9, frameon=False, loc="upper right")
    fig.suptitle("A per-IP control throttles a legitimate multi-sensor node; keying on identity does not",
                 fontsize=11)
    fig.tight_layout(rect=[0,0,1,0.95]); out=os.path.join(FIG,"fig_identity_vs_ip.svg"); fig.savefig(out, bbox_inches='tight'); plt.close(fig)
    print("wrote", out)

# ---------- Fig 4: DoS before/after (from the existing threat-1 evidence) ----------
def fig_dos():
    # values documented in threats/01-ddos/evidence/poc-run.md
    scen = ["baseline", "attack", "mitigated\n(per-IP)"]
    p95  = [33, 488, 3]          # /health latency ms: 5, 202, 3  -> use server p95 for attack; health for others
    health = [5, 202, 3]
    cpu  = [0.04, 1.64, 0.25]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.2, 3.3))
    ax1.bar(range(3), health, color=[NEU, BAD, GOOD]); ax1.set_xticks(range(3)); ax1.set_xticklabels(scen)
    ax1.set_ylabel("/health latency (ms)"); ax1.set_title("Availability signal")
    for i,v in enumerate(health): ax1.text(i, v+4, str(v), ha="center", fontsize=10)
    ax2.bar(range(3), cpu, color=[NEU, BAD, GOOD]); ax2.set_xticks(range(3)); ax2.set_xticklabels(scen)
    ax2.set_ylabel("soa-container CPU (cores)"); ax2.set_title("Resource saturation")
    for i,v in enumerate(cpu): ax2.text(i, v+0.03, str(v), ha="center", fontsize=10)
    fig.suptitle("Threat 1 (DoS): the attack saturates latency and CPU; the per-IP limiter restores both", fontsize=11)
    fig.tight_layout(rect=[0,0,1,0.95]); out=os.path.join(FIG,"fig_dos.svg"); fig.savefig(out, bbox_inches='tight'); plt.close(fig)
    print("wrote", out)

for fn in (fig_scalability, fig_correlation, fig_identity_vs_ip, fig_dos):
    try: fn()
    except Exception as e: print("ERROR", fn.__name__, e)
