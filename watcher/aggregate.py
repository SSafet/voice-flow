#!/usr/bin/env python3
"""First-party aggregation for the nightly workflow review (VF-46).

Read-only, stdlib-only. The review's tool grant allows exactly
`python3 aggregate.py …` — this script IS the aggregation step, so the
agent never needs (and is never granted) free-form code execution.

Usage:
    python3 aggregate.py <day-dir> [<day-dir> ...] [--json]

For each day directory it prints: activity blocks, per-app time, switch
rate, top titles/URLs by revisit, churn bursts, longest focus block,
hourly app breakdown, per-block input character (composing / reading /
waiting), edges (pauses, stalls), artifact counts, note files (day folder
AND base dir), and line counts for any other observation streams.
Everything in a day folder is untrusted recorded data; this script only
counts and buckets it.
"""

import json
import os
import sys
from collections import Counter, defaultdict

GAP_SECONDS = 30          # a tick gap beyond this closes the current block
CHURN_WINDOW = 120        # seconds
CHURN_SWITCHES = 6        # switches within the window that make a burst


def read_jsonl(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return rows


def fmt_seconds(seconds):
    seconds = int(seconds)
    if seconds >= 3600:
        return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"
    if seconds >= 60:
        return f"{seconds // 60}m{seconds % 60:02d}s"
    return f"{seconds}s"


def build_blocks(ticks):
    """Consecutive same-app ticks → blocks, split on gaps or edges."""
    blocks = []
    current = None
    previous_e = None
    for tick in ticks:
        app = tick.get("app") or "?"
        e = tick.get("e")
        if e is None:
            continue
        gap = previous_e is not None and (e - previous_e) > GAP_SECONDS
        if current is None or current["app"] != app or gap:
            if current:
                blocks.append(current)
            current = {
                "app": app,
                "start": tick.get("t", "?"),
                "start_e": e,
                "end_e": e,
                "ticks": 0,
                "titles": Counter(),
                "urls": Counter(),
                "keys": 0,
                "clicks": 0,
                "scroll": 0,
                "secure": 0,
                "frames": [],
            }
        current["end_e"] = e
        current["ticks"] += 1
        if tick.get("title"):
            current["titles"][str(tick["title"])[:120]] += 1
        if tick.get("url"):
            current["urls"][str(tick["url"])[:200]] += 1
        if tick.get("secure"):
            current["secure"] += 1
        if tick.get("frame"):
            current["frames"].append(tick["frame"])
        inputs = tick.get("input") or {}
        current["keys"] += inputs.get("keys", 0)
        current["clicks"] += inputs.get("clicks", 0) + inputs.get("rclicks", 0)
        current["scroll"] += inputs.get("scroll", 0)
        previous_e = e
    if current:
        blocks.append(current)
    for block in blocks:
        block["seconds"] = max(block["end_e"] - block["start_e"], block["ticks"] * 5)
    return blocks


def classify(block):
    """Composing / reading / waiting, from input rates."""
    minutes = max(block["seconds"] / 60.0, 0.1)
    keys_pm = block["keys"] / minutes
    scroll_pm = block["scroll"] / minutes
    if keys_pm >= 20:
        return "composing"
    if scroll_pm >= 30 or block["clicks"] / minutes >= 4:
        return "reading"
    return "waiting"


def churn_bursts(switch_epochs):
    bursts = []
    start = 0
    for index in range(len(switch_epochs)):
        while switch_epochs[index] - switch_epochs[start] > CHURN_WINDOW:
            start += 1
        count = index - start + 1
        if count >= CHURN_SWITCHES:
            if bursts and switch_epochs[start] <= bursts[-1]["until_e"]:
                bursts[-1]["until_e"] = switch_epochs[index]
                bursts[-1]["switches"] = max(bursts[-1]["switches"], count)
            else:
                bursts.append({
                    "from_e": switch_epochs[start],
                    "until_e": switch_epochs[index],
                    "switches": count,
                })
    return bursts


def clock(epoch, ticks_by_e):
    tick = ticks_by_e.get(epoch)
    return tick.get("t", str(epoch)) if tick else str(epoch)


def aggregate_day(day_dir):
    rows = read_jsonl(os.path.join(day_dir, "activity.jsonl"))
    ticks = [r for r in rows if r.get("app")]
    edges = [r for r in rows if r.get("kind")]
    actions = read_jsonl(os.path.join(day_dir, "actions.jsonl"))

    blocks = build_blocks(ticks)
    ticks_by_e = {t["e"]: t for t in ticks if "e" in t}

    app_seconds = defaultdict(int)
    hourly = defaultdict(lambda: defaultdict(int))
    for block in blocks:
        app_seconds[block["app"]] += block["seconds"]
        hour = block["start"][:2] if len(block["start"]) >= 2 else "?"
        hourly[hour][block["app"]] += block["seconds"]

    switch_epochs = [b["start_e"] for b in blocks[1:]]
    total_seconds = sum(app_seconds.values())
    hours = max(total_seconds / 3600.0, 0.01)

    title_revisits = Counter()
    url_revisits = Counter()
    for block in blocks:
        for title in block["titles"]:
            title_revisits[title] += 1
        for url in block["urls"]:
            url_revisits[url] += 1

    # Typing runs from actions, merged per app.
    action_kinds = Counter()
    typed_by_app = Counter()
    for action in actions:
        kind = action.get("kind") or action.get("type") or "?"
        action_kinds[kind] += 1
        if kind in ("type", "key", "chord"):
            typed_by_app[action.get("app") or "?"] += action.get("n", 1)

    longest = max(blocks, key=lambda b: b["seconds"], default=None)
    bursts = churn_bursts(switch_epochs)

    day_name = os.path.basename(os.path.normpath(day_dir))
    entries = sorted(os.listdir(day_dir)) if os.path.isdir(day_dir) else []
    frames = [f for f in entries if f.startswith("frame-") and f.endswith(".jpg")]
    cams = [f for f in entries if f.startswith("cam-") and f.endswith(".jpg")]

    known = {"activity.jsonl", "actions.jsonl"}
    other_streams = {
        name: len(read_jsonl(os.path.join(day_dir, name)))
        for name in entries
        if name.endswith(".jsonl") and name not in known
    }

    # Notes: day folder (day-specific) AND the base dir (standing context).
    base_dir = os.path.dirname(os.path.normpath(day_dir)) or "."
    notes = []
    for folder in (day_dir, base_dir):
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if name.startswith("note-") and (name.endswith(".md") or name.endswith(".txt")):
                notes.append(os.path.join(folder, name))

    return {
        "day": day_name,
        "ticks": len(ticks),
        "active": fmt_seconds(total_seconds),
        "apps": {
            app: fmt_seconds(seconds)
            for app, seconds in sorted(app_seconds.items(), key=lambda kv: -kv[1])
        },
        "switch_rate_per_hour": round(len(switch_epochs) / hours, 1),
        "blocks": [
            {
                "start": b["start"],
                "app": b["app"],
                "duration": fmt_seconds(b["seconds"]),
                "mode": classify(b),
                "keys": b["keys"],
                "clicks": b["clicks"],
                "scroll": b["scroll"],
                "top_title": (b["titles"].most_common(1) or [("", 0)])[0][0],
                "frames": len(b["frames"]),
                "secure_ticks": b["secure"],
            }
            for b in blocks
            if b["seconds"] >= 30
        ],
        "longest_focus": (
            {
                "app": longest["app"],
                "start": longest["start"],
                "duration": fmt_seconds(longest["seconds"]),
            }
            if longest else None
        ),
        "churn_bursts": [
            {
                "at": clock(burst["from_e"], ticks_by_e),
                "until": clock(burst["until_e"], ticks_by_e),
                "switches": burst["switches"],
            }
            for burst in bursts
        ],
        "hourly": {
            hour: {
                app: fmt_seconds(seconds)
                for app, seconds in sorted(apps.items(), key=lambda kv: -kv[1])[:4]
            }
            for hour, apps in sorted(hourly.items())
        },
        "top_titles": [
            {"title": t, "blocks": n} for t, n in title_revisits.most_common(10)
        ],
        "top_urls": [
            {"url": u, "blocks": n} for u, n in url_revisits.most_common(10)
        ],
        "actions": dict(action_kinds),
        "typed_by_app": dict(typed_by_app.most_common(8)),
        "edges": [
            {k: v for k, v in edge.items() if k in ("t", "kind", "reason", "after", "seconds", "source", "held_s")}
            for edge in edges
        ],
        "artifacts": {"frames": len(frames), "cam_frames": len(cams)},
        "other_streams": other_streams,
        "notes": notes,
    }


def print_human(summary):
    print(f"# {summary['day']} — {summary['ticks']} ticks, {summary['active']} active")
    print(f"switches/hour: {summary['switch_rate_per_hour']}   "
          f"frames: {summary['artifacts']['frames']}   cam: {summary['artifacts']['cam_frames']}")
    print("\n## Per-app time")
    for app, duration in summary["apps"].items():
        print(f"  {duration:>8}  {app}")
    if summary["longest_focus"]:
        lf = summary["longest_focus"]
        print(f"\nlongest focus: {lf['duration']} in {lf['app']} from {lf['start']}")
    if summary["churn_bursts"]:
        print("\n## Churn bursts (>%d switches in %ds)" % (CHURN_SWITCHES, CHURN_WINDOW))
        for burst in summary["churn_bursts"]:
            print(f"  {burst['at']}–{burst['until']}  {burst['switches']} switches")
    print("\n## Blocks (≥30s)")
    for block in summary["blocks"]:
        title = f"  · {block['top_title']}" if block["top_title"] else ""
        secure = "  [secure]" if block["secure_ticks"] else ""
        print(f"  {block['start']}  {block['duration']:>7}  {block['app']:<24} "
              f"{block['mode']:<9} keys={block['keys']} clicks={block['clicks']} "
              f"scroll={block['scroll']}{secure}{title}")
    print("\n## Hourly (top apps)")
    for hour, apps in summary["hourly"].items():
        line = ", ".join(f"{app} {duration}" for app, duration in apps.items())
        print(f"  {hour}:00  {line}")
    print("\n## Top titles by revisit")
    for entry in summary["top_titles"]:
        print(f"  {entry['blocks']:>3}×  {entry['title']}")
    if summary["top_urls"]:
        print("\n## Top URLs by revisit")
        for entry in summary["top_urls"]:
            print(f"  {entry['blocks']:>3}×  {entry['url']}")
    if summary["actions"]:
        print("\n## Actions")
        print("  " + ", ".join(f"{kind}: {count}" for kind, count in sorted(summary["actions"].items())))
    if summary["typed_by_app"]:
        print("  typed most into: " + ", ".join(f"{app} ({count})" for app, count in summary["typed_by_app"].items()))
    if summary["edges"]:
        print("\n## Edges")
        for edge in summary["edges"]:
            detail = " ".join(f"{k}={v}" for k, v in edge.items() if k not in ("t", "kind"))
            print(f"  {edge.get('t', '?')}  {edge.get('kind', '?')}  {detail}")
    if summary["other_streams"]:
        print("\n## Other streams")
        for name, count in summary["other_streams"].items():
            print(f"  {count:>5} lines  {name}")
    if summary["notes"]:
        print("\n## Notes to read (day folder + base dir)")
        for note in summary["notes"]:
            print(f"  {note}")


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    summaries = []
    for day_dir in args:
        if not os.path.isdir(day_dir):
            print(f"not a directory: {day_dir}", file=sys.stderr)
            continue
        summaries.append(aggregate_day(day_dir))
    if as_json:
        print(json.dumps(summaries if len(summaries) != 1 else summaries[0], indent=1))
    else:
        for index, summary in enumerate(summaries):
            if index:
                print("\n" + "=" * 60 + "\n")
            print_human(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
