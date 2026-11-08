"""Turn one benchmark result folder into results.csv and results.md (median of runs)."""
import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

UNIT = {"KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "B": 1 / 1024 / 1024}


def parse_stats(path):
    """docker stats lines like '153.21% 41.5MiB / 512MiB' -> (avg cpu %, max mem MiB)."""
    cpu, mem = [], []
    for line in path.read_text().splitlines() if path.exists() else []:
        m = re.match(r"([\d.]+)%\s+([\d.]+)(\w+)\s*/", line)
        if m:
            cpu.append(float(m[1]))
            mem.append(float(m[2]) * UNIT.get(m[3], 1))
    # First sample can predate the load; drop it when there are enough.
    cpu = cpu[1:] if len(cpu) > 2 else cpu
    return (statistics.mean(cpu) if cpu else 0.0, max(mem) if mem else 0.0)


def row(path):
    m = json.loads(path.read_text())["metrics"]
    d = m["http_req_duration"]["values"]
    cpu, mem = parse_stats(path.with_suffix(".stats"))
    redis_cpu, _ = parse_stats(path.with_suffix(".redis"))  # 0 when Redis was not running
    return {
        "achieved_rps": m["http_reqs"]["values"]["rate"],
        "p50_ms": d["p(50)"], "p95_ms": d["p(95)"], "p99_ms": d["p(99)"],
        "error_pct": m["http_req_failed"]["values"]["rate"] * 100,
        "dropped": m.get("dropped_iterations", {}).get("values", {}).get("count", 0),
        "cpu_pct": cpu, "mem_mib": mem, "redis_cpu_pct": redis_cpu,
    }


def main(folder):
    folder = Path(folder)
    groups = defaultdict(list)
    for f in sorted(folder.glob("*-run*.json")):
        target, rate, _ = f.stem.split("-")
        groups[(target, int(rate))].append(row(f))

    order = {"direct": 0, "rust": 1, "java": 2}
    keys = sorted(groups, key=lambda k: (k[1], order.get(k[0], 9)))
    fields = list(next(iter(groups.values()))[0])
    table = [{"target": t, "rate": r, "runs": len(groups[(t, r)]),
              **{f: statistics.median(x[f] for x in groups[(t, r)]) for f in fields}} for t, r in keys]

    with open(folder / "results.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(table[0]))
        w.writeheader()
        w.writerows(table)

    lines = ["| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB | redis cpu % |",
             "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in table:
        lines.append(f"| {r['target']} | {r['rate']} | {r['achieved_rps']:.0f} | {r['p50_ms']:.2f} | {r['p95_ms']:.2f} "
                     f"| {r['p99_ms']:.2f} | {r['error_pct']:.2f} | {r['dropped']:.0f} | {r['cpu_pct']:.0f} | {r['mem_mib']:.0f} | {r['redis_cpu_pct']:.0f} |")
    env = (folder / "env.txt").read_text() if (folder / "env.txt").exists() else ""
    (folder / "results.md").write_text(f"# S1 passthrough — median of runs\n\n```\n{env}```\n\n" + "\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    assert parse_stats(Path("/nonexistent")) == (0.0, 0.0)
    main(sys.argv[1])
