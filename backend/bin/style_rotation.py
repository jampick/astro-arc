#!/usr/bin/env python3
"""Style rotation: which style a scheduled generation uses next.

With config.rotateStyles on, every scheduled run (astro-arc-generate
--if-due) moves to the next style before it renders. A manual Regenerate
never does: it renders whatever the Style dropdown says, which is also the
style the last scheduled run picked, because `next` writes its pick there.

The order is a shuffle bag. Every style in the rotation plays once, in random
order, before any of them plays again, and a fresh bag never opens with the
style that closed the last one. The bag lives in style-bag.json in the state
directory as the list of styles still to play this round.

A style leaves the bag only when its run succeeds (`done`, called after the
image exists). A refused or failed render leaves it at the head, so the next
due run tries the same style again rather than skipping it.

The rotation is every style in pipeline/styles.toml minus config.hiddenStyles,
the same styles the Style dropdown offers. The config lists what is left out,
so a style added in a plugin update joins both without anyone having to opt it
in. Hidden keys that styles.toml no longer has are ignored.

Usage (the config JSON, as astro-arc-config prints it, on stdin):
    style_rotation.py next          # prints the style to use, or nothing
    style_rotation.py done <key>    # the run with <key> succeeded
"""

import json
import random
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from paths import STATE_DIR  # noqa: E402

STYLES_FILE = HERE.parent / "pipeline" / "styles.toml"
BAG_FILE = STATE_DIR / "style-bag.json"


def style_keys():
    """Every top-level table with a label is a style; the rest of a style's
    charter lives in subtables like [symbolist.world]."""
    with STYLES_FILE.open("rb") as f:
        styles = tomllib.load(f)
    return [k for k, v in styles.items() if isinstance(v, dict) and "label" in v]


def rotation(config):
    hidden = set(config.get("hiddenStyles") or [])
    return [k for k in style_keys() if k not in hidden]


def load_bag():
    try:
        remaining = json.loads(BAG_FILE.read_text()).get("remaining")
    except (OSError, ValueError, AttributeError):
        return []
    return [k for k in remaining if isinstance(k, str)] if isinstance(remaining, list) else []


def save_bag(remaining):
    BAG_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = BAG_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"remaining": remaining}) + "\n")
    tmp.replace(BAG_FILE)


def next_style(config):
    pool = rotation(config)
    if not pool:
        return ""
    remaining = [k for k in load_bag() if k in pool]
    if not remaining:
        remaining = pool[:]
        random.shuffle(remaining)
        current = config.get("artStyle")
        if len(remaining) > 1 and remaining[0] == current:
            remaining.append(remaining.pop(0))
    save_bag(remaining)
    return remaining[0]


def mark_done(key):
    remaining = load_bag()
    if key in remaining:
        remaining.remove(key)
        save_bag(remaining)


def main():
    args = sys.argv[1:]
    if args == ["next"]:
        try:
            config = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            config = {}
        print(next_style(config if isinstance(config, dict) else {}))
    elif len(args) == 2 and args[0] == "done":
        mark_done(args[1])
    else:
        print(__doc__.split("Usage", 1)[1], file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
