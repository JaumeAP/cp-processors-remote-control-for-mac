#!/usr/bin/env python3
"""Mutation testing for the Swift sources.

Each mutant changes one operator or literal in one source line (== to !=,
< to <=, && to ||, + to -, true to false, a removed `!`). The script builds
the package and runs the tests: a mutant the tests fail on is killed, one they
pass on survived (the tests do not check that line), one that does not compile
is invalid and not counted. A mutant that hangs the tests counts as killed.

Usage, from the macos/ folder (needs swift; the tests must pass unmutated):
    scripts/mutate.py --list Sources/CPx50Comms/LineBuffer.swift
    scripts/mutate.py --max 40 --out /tmp/mutation Sources/CPx50Comms/LineBuffer.swift

The source file is restored after every mutant, also on Ctrl-C.
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # the macos/ folder

# (name, regex on the code of a line with strings and comments blanked,
#  replacement, group to replace). Spaced < > + - only, so generics and
# arrows are left alone.
OPERATORS = [
    ("eq-to-ne", re.compile(r"(?<![=!<>])==(?!=)"), "!="),
    ("ne-to-eq", re.compile(r"!=(?!=)"), "=="),
    ("le-to-lt", re.compile(r"<=(?!=)"), "<"),
    ("ge-to-gt", re.compile(r"(?<!=)>=(?!=)"), ">"),
    ("lt-to-le", re.compile(r" < "), " <= "),
    ("gt-to-ge", re.compile(r" > "), " >= "),
    ("and-to-or", re.compile(r"&&"), "||"),
    ("or-to-and", re.compile(r"\|\|"), "&&"),
    ("plus-to-minus", re.compile(r" \+ "), " - "),
    ("minus-to-plus", re.compile(r" - "), " + "),
    ("pluseq-to-minuseq", re.compile(r" \+= "), " -= "),
    ("minuseq-to-pluseq", re.compile(r" -= "), " += "),
    ("true-to-false", re.compile(r"\btrue\b"), "false"),
    ("false-to-true", re.compile(r"\bfalse\b"), "true"),
    ("drop-not", re.compile(r"(?<![=!\w)\]])!(?=[\w(])"), ""),
]

SKIP_LINE = re.compile(r"^\s*(//|/\*|\*|import\b|@|#)|\"\"\"|\bprint\(|\bassert|\bprecondition")


def blank_strings_and_comments(line: str) -> str:
    """The line with string contents and a trailing // comment replaced by
    spaces of the same length, so a match position is valid in the original."""
    out = []
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\" and i + 1 < len(line):
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_string = False
                out.append('"')
            else:
                out.append(" ")
        else:
            if ch == '"':
                in_string = True
                out.append('"')
            elif ch == "/" and line[i : i + 2] == "//":
                out.append(" " * (len(line) - i))
                break
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def mutants_of(path: Path):
    """All mutants of one file: (line number, operator name, original line,
    mutated line)."""
    found = []
    lines = path.read_text().split("\n")
    for number, line in enumerate(lines, start=1):
        if SKIP_LINE.search(line):
            continue
        code = blank_strings_and_comments(line)
        for name, pattern, replacement in OPERATORS:
            for match in pattern.finditer(code):
                mutated = line[: match.start()] + replacement + line[match.end() :]
                found.append((number, name, line, mutated))
    return found


def run(command, timeout):
    try:
        done = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def build(timeout):
    return run(["swift", "build", "--build-tests"], timeout)


def test(extra, timeout):
    return run(["swift", "test", "--skip-build"] + extra, timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", help="Swift sources to mutate, relative to macos/")
    parser.add_argument("--list", action="store_true", help="only count the mutants, run nothing")
    parser.add_argument("--max", type=int, default=40, help="mutants to run in total (a seeded sample)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--build-timeout", type=int, default=900)
    parser.add_argument("--test-timeout", type=int, default=240)
    parser.add_argument("--test-args", default="", help="extra arguments of `swift test`, space separated")
    parser.add_argument("--out", default="mutation-report", help="folder for report.json and report.md")
    args = parser.parse_args()

    files = [ROOT / f for f in args.files]
    for f in files:
        if not f.is_file():
            sys.exit(f"no such file: {f}")
    pool = []
    for f in files:
        for number, name, original, mutated in mutants_of(f):
            pool.append((f, number, name, original, mutated))
    print(f"{len(pool)} mutants in {len(files)} file(s)")
    if args.list:
        for f in files:
            print(f"  {f.relative_to(ROOT)}: {sum(1 for m in pool if m[0] == f)}")
        return
    random.Random(args.seed).shuffle(pool)
    chosen = sorted(pool[: args.max], key=lambda m: (str(m[0]), m[1], m[2]))
    extra = args.test_args.split()

    print("baseline: build and test the unmutated sources")
    code, output = build(args.build_timeout)
    if code != 0:
        sys.exit("baseline build failed:\n" + output[-3000:])
    code, output = test(extra, args.test_timeout * 4)
    if code != 0:
        sys.exit("baseline tests fail, nothing to measure:\n" + output[-3000:])

    results = []
    started = time.time()
    try:
        for index, (f, number, name, original, mutated) in enumerate(chosen, start=1):
            rel = str(f.relative_to(ROOT))
            text = f.read_text()
            lines = text.split("\n")
            lines[number - 1] = mutated
            f.write_text("\n".join(lines))
            try:
                code, output = build(args.build_timeout)
                if code != 0:
                    status = "invalid"
                else:
                    code, output = test(extra, args.test_timeout)
                    status = "survived" if code == 0 else "killed"
            finally:
                f.write_text(text)
            results.append({"file": rel, "line": number, "operator": name, "original": original.strip(),
                            "mutated": mutated.strip(), "status": status})
            print(f"[{index}/{len(chosen)}] {status:9} {rel}:{number} {name}", flush=True)
    finally:
        # The loop above restores each file; this covers an interrupt between
        # the write and the try.
        for f in files:
            subprocess.run(["git", "checkout", "--", str(f)], cwd=ROOT, capture_output=True)

    killed = sum(1 for r in results if r["status"] == "killed")
    survived = [r for r in results if r["status"] == "survived"]
    invalid = sum(1 for r in results if r["status"] == "invalid")
    counted = killed + len(survived)
    score = (100.0 * killed / counted) if counted else 0.0

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps({"killed": killed, "survived": len(survived), "invalid": invalid,
                                                 "score": score, "results": results}, indent=2))
    md = [f"Mutation score {score:.1f}%: {killed} killed, {len(survived)} survived, {invalid} did not compile "
          f"({time.time() - started:.0f} s)."]
    if survived:
        md += ["", "Survivors (the tests do not check these lines):", ""]
        for r in survived:
            md.append(f"- `{r['file']}:{r['line']}` {r['operator']}: `{r['original']}` became `{r['mutated']}`")
    (out / "report.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
