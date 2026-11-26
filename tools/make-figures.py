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

# ---------- Fig 5: Threat B (Spam) defense outcomes ----------
def fig_spam():
    # values documented in threats/02-spam/evidence/poc-run.md
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.2, 3.4))

    # Panel A: quarantine — messages reaching the mailbox (16 sent)
    labs = ["no control", "quarantine on"]
    delivered = [16, 0]
    ax1.bar(range(2), delivered, color=[BAD, GOOD])
    ax1.set_xticks(range(2)); ax1.set_xticklabels(labs)
    ax1.set_ylabel("spam delivered to mailbox"); ax1.set_title("Quarantine (16 spam sent)")
    ax1.set_ylim(0, 18)
    for i, v in enumerate(delivered):
        ax1.text(i, v + 0.4, str(v), ha="center", fontsize=10)
    ax1.text(1, 1.2, "16 held\nin queue", ha="center", va="bottom", fontsize=8.5, color=NEU)

    # Panel B: SMTP per-client rate limit — accepted vs rejected (15 sent)
    groups = ["no limit", "limit on"]
    accepted = [15, 10]; rejected = [0, 5]
    x = [0, 1]; w = 0.38
    ax2.bar([xi - w/2 for xi in x], accepted, w, label="accepted", color=GOOD)
    ax2.bar([xi + w/2 for xi in x], rejected, w, label="rejected", color=BAD)
    ax2.set_xticks(x); ax2.set_xticklabels(groups)
    ax2.set_ylabel("messages"); ax2.set_title("SMTP rate limit (15 sent)")
    ax2.set_ylim(0, 17); ax2.legend(frameon=False, fontsize=9, loc="upper right")
    for xi, v in zip(x, accepted): ax2.text(xi - w/2, v + 0.3, str(v), ha="center", fontsize=9)
    for xi, v in zip(x, rejected): ax2.text(xi + w/2, v + 0.3, str(v), ha="center", fontsize=9)

    fig.suptitle("Threat 2 (Spam): quarantine holds every flagged message; the per-client "
                 "rate limit sheds volume", fontsize=10.5)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out = os.path.join(FIG, "fig_spam.svg"); fig.savefig(out, bbox_inches="tight"); plt.close(fig)
    print("wrote", out)

# ---------- Fig 6: Threat C (C2) detect -> contain timeline + before/after ----------
def fig_c2():
    # values documented in threats/03-c2/evidence/poc-run.md
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.4, 3.4),
                                   gridspec_kw={"width_ratios": [1.8, 1]})

    # Panel A: timeline (seconds since payload execution)
    events = [  # (t, label, colour, label_x, label_y)
        (0,  "payload dropped\n(FIM rule 100301)", BAD,     0.0,  1.05),
        (2,  "reverse shell\nopened", BAD,                  2.5, -1.05),
        (15, "C2CHECK -> rule 100300\n(<=15 s poll)", SYMPTOM, 12.0, 1.05),
        (16, "c2-contain:\nkill + block egress", GOOD,     16.0, -1.05),
        (18, "conn_after_block\n= 0", GOOD,                19.5,  0.9),
    ]
    ax1.axhline(0, color=NEU, lw=1.2, zorder=1)
    for t, lab, col, lx, ly in events:
        ax1.scatter([t], [0], s=70, color=col, zorder=3)
        va = "bottom" if ly > 0 else "top"
        ax1.annotate(lab, (t, 0), (lx, ly), ha="center", va=va, fontsize=8,
                     color=col, arrowprops=dict(arrowstyle="-", color=col, lw=0.8))
    ax1.axvspan(0, 15, color=BAD, alpha=0.06, zorder=0)
    ax1.axvspan(16, 20, color=GOOD, alpha=0.07, zorder=0)
    ax1.set_xlim(-2, 22); ax1.set_ylim(-1.6, 1.6)
    ax1.set_yticks([]); ax1.set_xlabel("seconds since payload execution")
    ax1.set_title("Attack -> detection -> containment", fontsize=10)
    ax1.spines["left"].set_visible(False)

    # Panel B: C2 connections before/after containment
    ax2.bar(range(2), [1, 0], color=[BAD, GOOD])
    ax2.set_xticks(range(2)); ax2.set_xticklabels(["C2 live", "after\ncontainment"])
    ax2.set_ylabel("active C2 connections"); ax2.set_ylim(0, 1.4)
    ax2.set_title("Containment", fontsize=10)
    for i, v in enumerate([1, 0]): ax2.text(i, v + 0.05, str(v), ha="center", fontsize=10)

    fig.suptitle("Threat 3 (C2): FIM + egress monitoring catch the reverse shell within one "
                 "15 s cycle; containment cuts it (1->0)", fontsize=10.5)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out = os.path.join(FIG, "fig_c2.svg"); fig.savefig(out, bbox_inches="tight"); plt.close(fig)
    print("wrote", out)

# ---------- Fig 7: Threat D (MitM) detection signal + integrity break ----------
def fig_mitm():
    # values documented in threats/04-mitm/evidence/{poc-run,poc-active}.md
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.4, 3.4),
                                   gridspec_kw={"width_ratios": [1, 1.25]})

    # Panel A: TTL decrement = inserted hop
    ttl = [64, 63]
    ax1.bar(range(2), ttl, color=[GOOD, BAD])
    ax1.set_xticks(range(2)); ax1.set_xticklabels(["direct\n(0 hops)", "via interceptor\n(1 hop)"])
    ax1.set_ylabel("reply TTL"); ax1.set_ylim(60, 65); ax1.set_title("Route-hijack signal", fontsize=10)
    for i, v in enumerate(ttl): ax1.text(i, v + 0.08, str(v), ha="center", fontsize=10)

    # Panel B: integrity — what Apache served vs what the client received
    ax2.axis("off")
    ax2.set_title("Integrity (active on-path)", fontsize=10)
    ax2.text(0.5, 0.80, "Apache served:\n\"...It works\"", ha="center", va="center", fontsize=9,
             bbox=dict(boxstyle="round,pad=0.4", facecolor=GOOD, alpha=0.15, edgecolor=GOOD))
    ax2.annotate("", (0.5, 0.52), (0.5, 0.66), arrowprops=dict(arrowstyle="->", color=NEU, lw=1.4))
    ax2.text(0.5, 0.30,
             "Client received:\n\"...It works (TAMPERED)\"\n+ injected banner  (10834 B)",
             ha="center", va="center", fontsize=9,
             bbox=dict(boxstyle="round,pad=0.4", facecolor=BAD, alpha=0.15, edgecolor=BAD))

    fig.suptitle("Threat 4 (MitM): an inserted hop drops the TTL (64->63); on-path, the page is "
                 "rewritten before the client sees it", fontsize=10.5)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out = os.path.join(FIG, "fig_mitm.svg"); fig.savefig(out, bbox_inches="tight"); plt.close(fig)
    print("wrote", out)

for fn in (fig_scalability, fig_correlation, fig_identity_vs_ip, fig_dos,
           fig_spam, fig_c2, fig_mitm):
    try: fn()
    except Exception as e: print("ERROR", fn.__name__, e)
