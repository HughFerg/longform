#!/usr/bin/env python3
"""Checks the voice prompt against realistic spoken turns.

Deterministic: reply length and a banned-phrase scan. No judge model, so it is fast and free
apart from the eight replies it generates. The prompt is read from ClaudeClient.swift, so this
always grades what the app ships.
"""
import json
import pathlib
import re
import statistics
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODEL = "claude-sonnet-5-5"
MAX_CHARS = 320          # ~23 seconds spoken
MAX_SENTENCE_WORDS = 20

FLATTERY = [
    "great question", "good question", "great point", "that makes sense", "makes a lot of sense",
    "you're right", "you're absolutely right", "i love that", "interesting idea", "smart",
    "happy to help", "i'd be happy to", "absolutely",
]
AI_ISMS = [
    "dive into", "unpack", "landscape", "journey", "at the end of the day", "game changer",
    "double-edged sword", "low-hanging fruit", "move the needle", "circle back", "it's worth noting",
    "that said", "delve",
]


def api_key():
    match = re.search(r'"(sk-ant-[^"]+)"', (ROOT / "Longform" / "Secrets.swift").read_text())
    return match.group(1) if match else sys.exit("No API key in Longform/Secrets.swift")


def system_prompt():
    source = (ROOT / "Longform" / "ClaudeClient.swift").read_text()
    match = re.search(r'private let systemPrompt = """\n(.*?)\n"""', source, re.S)
    return match.group(1).replace("\\\n", "") if match else sys.exit("No systemPrompt found")


def ask(key, system, turn):
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({"model": MODEL, "max_tokens": 1024, "system": system,
                         "messages": [{"role": "user", "content": turn}]}).encode(),
        headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        return "".join(b.get("text", "") for b in json.load(response)["content"])


def problems(reply, allow_long):
    found = []
    lower = reply.lower()
    found += [f"flattery:{p}" for p in FLATTERY if p in lower]
    found += [f"ai-ism:{p}" for p in AI_ISMS if p in lower]
    if not allow_long and len(reply) > MAX_CHARS:
        found.append(f"long:{len(reply)}")
    if re.search(r"^\s*[-*•\d]+[.)]?\s", reply, re.M):
        found.append("list")
    longest = max((len(s.split()) for s in re.split(r"[.!?]", reply) if s.strip()), default=0)
    if longest > MAX_SENTENCE_WORDS:
        found.append(f"sentence:{longest}w")
    return found


def main():
    key, system = api_key(), system_prompt()
    cases = json.loads((pathlib.Path(__file__).parent / "turns.json").read_text())
    verbose = "--verbose" in sys.argv
    rows = []

    for case in cases:
        reply = ask(key, system, case["turn"])
        found = problems(reply, allow_long=case.get("allow_long", False))
        rows.append((case["id"], len(reply), found))
        if verbose:
            print(f"\n--- {case['id']}\n{reply}")

    print(f"\n{'case':<20} {'chars':>6}  issues")
    print("-" * 78)
    for name, length, found in rows:
        print(f"{name:<20} {length:>6}  {', '.join(found) if found else 'ok'}")
    print("-" * 78)
    clean = sum(1 for _, _, f in rows if not f)
    print(f"{'mean chars':<20} {statistics.mean(r[1] for r in rows):>6.0f}")
    print(f"{'clean':<20} {clean:>6}/{len(rows)}")


if __name__ == "__main__":
    main()
