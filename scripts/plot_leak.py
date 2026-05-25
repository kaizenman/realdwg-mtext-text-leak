#!/usr/bin/env python3
"""Generate a leak-vs-control chart from the two long-form measurement CSVs.

Usage:
    python scripts/plot_leak.py
"""

import csv
import pathlib

import matplotlib
matplotlib.use("Agg")  # no display
import matplotlib.pyplot as plt


REPO = pathlib.Path(__file__).resolve().parent.parent
LEAK_CSV = REPO / "evidence" / "run_leak_300iter.csv"
RTF_CSV  = REPO / "evidence" / "run_rtf_300iter.csv"
OUT_PNG  = REPO / "evidence" / "leak_vs_control.png"


def load(csv_path):
    ts, mb = [], []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                pb = float(row["private_mb"])
                if pb <= 0:
                    continue  # filter post-exit zeros
                ts.append(int(row["t_ms"]) / 1000.0)
                mb.append(pb)
            except (KeyError, ValueError):
                continue
    return ts, mb


def main():
    leak_t, leak_mb = load(LEAK_CSV)
    rtf_t,  rtf_mb  = load(RTF_CSV)

    fig, ax = plt.subplots(figsize=(10, 5.5), dpi=140)

    ax.plot(leak_t, leak_mb,
            color="#d62728", linewidth=1.7,
            label="AcDbMText::text()   (LEAKS)")
    ax.plot(rtf_t, rtf_mb,
            color="#2ca02c", linewidth=1.7,
            label="AcDbMText::contentsRTF()   (negative control)")

    ax.set_title(
        "RealDWG 25.1.72 — AcDbMText::text() vs contentsRTF()\n"
        "300 iterations of readDwgFile() + call + close on a 16 KB generated DWG with one MText",
        fontsize=11,
    )
    ax.set_xlabel("Wall time (seconds)")
    ax.set_ylabel("Process Private Bytes (MB)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", framealpha=0.95)

    # Annotate peak of leak line.
    if leak_t:
        peak_idx = max(range(len(leak_mb)), key=lambda i: leak_mb[i])
        ax.annotate(
            f"peak ≈ {leak_mb[peak_idx]:.0f} MB",
            xy=(leak_t[peak_idx], leak_mb[peak_idx]),
            xytext=(leak_t[peak_idx] - 220, leak_mb[peak_idx] - 80),
            fontsize=10, color="#7a0000",
            arrowprops=dict(arrowstyle="->", color="#7a0000"),
        )

    # Annotate the RTF line as flat at the right edge.
    if rtf_t:
        rtf_last = rtf_mb[-1]
        # Place the annotation on the wall-time scale of the leak run so the
        # contrast is visually obvious even though the RTF run finished in seconds.
        ax.annotate(
            f"flat ≈ {rtf_last:.0f} MB",
            xy=(rtf_t[-1], rtf_last),
            xytext=(60, rtf_last + 80),
            fontsize=10, color="#0a4a0a",
            arrowprops=dict(arrowstyle="->", color="#0a4a0a"),
        )

    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    fig.tight_layout()
    fig.savefig(OUT_PNG)
    print(f"Saved: {OUT_PNG}")
    print(f"  text() peak       = {max(leak_mb):.1f} MB over {leak_t[-1]:.0f} s")
    print(f"  contentsRTF peak  = {max(rtf_mb):.1f} MB over {rtf_t[-1]:.1f} s")


if __name__ == "__main__":
    main()
