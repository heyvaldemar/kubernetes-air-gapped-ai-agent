#!/usr/bin/env python3
"""Every static check, shown the violation it exists for, has to fail.

    tests/static/plant_violations.py
        every plant, one after another (make check)
    tests/static/plant_violations.py --shard 2/4 --result out/plants-2.json
        the plants of one shard, and a record of what it showed
    tests/static/plant_violations.py --total out/
        the shards' records held to plants.tsv
    tests/static/plant_violations.py --prove-total
        the total, shown the sets of records it must refuse

A check that cannot fail is not a check. Each line of tests/static/plants.tsv
names a file, a piece of it, its replacement, and the check in
scripts/validate.sh that must catch it: a tag where a digest was, a
misspelled field, an agent that does not compile. Each plant goes
into its own copy of the repository; the run fails if the named check stays
green, or if the text a plant breaks is no longer in the file (a stale plant
would prove nothing while looking like a pass).

Run scripts/validate.sh first: the untouched tree has to pass every check,
and its .cache/ is copied so the plants do not re-download schemas.

In CI the plants run in shards, side by side (.github/workflows/verify.yml):
on one runner 206 of them took 18 min 4 s of a job allowed 25 (run
43629124506). A shard takes the rows whose place in the file, counted from
zero, leaves the shard's own remainder when divided by the number of
shards, so the plants of one check are spread over all of them. A shard
that showed nothing ends green, so each one writes down the rows it showed
and what became of them, and the total holds those records to the file as
it stands in the checkout: every shard there once, every row shown by the
shard it belongs to and by no other, and as many caught as the file has
rows.
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The checks that run Terraform's tests. Once validate.sh has run, each
# cloud directory holds its providers under .terraform, 770 MB for aws/
# alone; a plant for any other check is copied without them. With them in
# every copy, the static job took 15 min 52 s for main's 142 plants (run
# 42918384643) and 20 min 33 s of its 25 for 159 (branch run 43094612785).
TERRAFORM_CHECKS = {"aws", "gke", "aks"}


def read_plants():
    plants = []
    with open(os.path.join(ROOT, "tests", "static", "plants.tsv"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            plants.append([json.loads(x) for x in line.rstrip("\n").split("\t")])
    return plants


def rows_of(shard, of, rows):
    """The places in the file, from zero, that shard `shard` of `of` shows."""
    return [k for k in range(rows) if k % of == shard - 1]


def show(plants, rows):
    """Plant each of `rows` in its own copy; the places caught, missed and stale."""
    caught, missed, stale = [], [], []
    for k in rows:
        fname, old, new, check, what = plants[k]
        work = tempfile.mkdtemp(prefix="plant-")
        try:
            skip = [".git", "out"] + ([] if check in TERRAFORM_CHECKS else [".terraform"])
            shutil.copytree(ROOT, work, dirs_exist_ok=True, symlinks=True,
                            ignore=shutil.ignore_patterns(*skip))
            path = os.path.join(work, fname)
            text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if old not in text:
                print("  STALE   %-12s %s: the text it breaks is no longer in %s" % (check, what, fname))
                stale.append(k)
                continue
            # An empty `old` plants a new file, in a new directory if need be.
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
            checks = [check]
            r = subprocess.run([os.path.join(work, "scripts", "validate.sh")] + checks,
                               capture_output=True, text=True, cwd=work)
            if "-- %s: FAILED" % check in r.stdout:
                print("  caught  %-12s %s" % (check, what))
                caught.append(k)
            else:
                print("  MISSED  %-12s %s" % (check, what))
                print("\n".join("          " + l for l in r.stdout.splitlines()[-15:]))
                missed.append(k)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return caught, missed, stale


def total(directory, rows):
    """Hold the shards' records under `directory` to a file of `rows` rows.

    Returns the lines to print and what is wrong; nothing wrong means every
    row was shown once, by the shard it belongs to, and caught.
    """
    lines, wrong, records = [], [], []
    for base, _, names in sorted(os.walk(directory)):
        for name in sorted(names):
            if not name.endswith(".json"):
                continue
            path = os.path.join(base, name)
            try:
                rec = json.load(open(path, encoding="utf-8"))
                for key in ("shard", "of", "rows"):
                    if type(rec[key]) is not int:
                        raise ValueError(key)
                for key in ("ran", "caught", "missed", "stale"):
                    if type(rec[key]) is not list or any(type(k) is not int for k in rec[key]):
                        raise ValueError(key)
            except (OSError, ValueError, KeyError, TypeError) as e:
                wrong.append("%s is not a shard's record (%s)" % (name, e))
                continue
            records.append(rec)
    if not records:
        return lines, wrong + ["no shard left a record under %s" % directory]
    counts = sorted({rec["of"] for rec in records})
    if len(counts) != 1 or counts[0] < 1:
        return lines, wrong + ["the records disagree on the number of shards: %s" % counts]
    of = counts[0]
    seen = collections.Counter(rec["shard"] for rec in records)
    for shard in range(1, of + 1):
        if seen[shard] != 1:
            wrong.append("shard %d of %d left %d records, not one" % (shard, of, seen[shard]))
    for shard in sorted(set(seen) - set(range(1, of + 1))):
        wrong.append("a record says it is shard %d of %d" % (shard, of))
    shown = collections.Counter()
    caught = 0
    for rec in sorted(records, key=lambda r: r["shard"]):
        lines.append("  shard %d of %d: %d plants: %d caught, %d missed, %d stale" % (
            rec["shard"], of, len(rec["ran"]), len(rec["caught"]), len(rec["missed"]), len(rec["stale"])))
        if rec["rows"] != rows:
            wrong.append("shard %d read a plants.tsv of %d rows; this one has %d" % (rec["shard"], rec["rows"], rows))
        if sorted(rec["ran"]) != rows_of(rec["shard"], of, rows):
            wrong.append("shard %d showed %d rows; %d of the file's are its own" % (
                rec["shard"], len(rec["ran"]), len(rows_of(rec["shard"], of, rows))))
        if sorted(rec["caught"] + rec["missed"] + rec["stale"]) != sorted(rec["ran"]):
            wrong.append("shard %d does not say what became of each row it showed" % rec["shard"])
        shown.update(rec["ran"])
        caught += len(set(rec["caught"]))
    once = sum(1 for k in range(rows) if shown[k] == 1)
    if once != rows:
        wrong.append("%d of %d rows were shown exactly once" % (once, rows))
    if caught != rows:
        wrong.append("%d caught, and plants.tsv has %d rows" % (caught, rows))
    if not wrong:
        lines.append("%d rows in tests/static/plants.tsv: %d shown once, %d caught, in %d shards" % (rows, once, caught, of))
    return lines, wrong


def prove_total():
    """The total takes a whole set of records and refuses each broken one."""
    rows, of = 10, 3

    def whole():
        return {s: {"shard": s, "of": of, "rows": rows, "ran": rows_of(s, of, rows),
                    "caught": rows_of(s, of, rows), "missed": [], "stale": []} for s in range(1, of + 1)}

    def nothing_ran(recs):
        recs[2].update(ran=[], caught=[])

    def one_missed(recs):
        recs[3]["missed"] = [recs[3]["caught"].pop()]

    def one_stale(recs):
        recs[1]["stale"] = [recs[1]["caught"].pop()]

    def a_row_twice(recs):
        recs[1]["ran"].append(1)
        recs[1]["caught"].append(1)

    def another_file(recs):
        recs[2]["rows"] = rows + 1

    def other_count(recs):
        recs[3]["of"] = of + 1

    def claims_more_than_it_ran(recs):
        recs[2].update(ran=[], caught=rows_of(2, of, rows))

    def same_shard_twice(recs):
        recs["again"] = dict(recs[2])

    def not_a_record(recs):
        recs[1] = {"shard": 1}

    cases = [
        ("a shard with no record", lambda recs: recs.pop(2)),
        ("a shard that showed nothing", nothing_ran),
        ("a plant missed", one_missed),
        ("a plant gone stale", one_stale),
        ("a row shown twice", a_row_twice),
        ("a record of another plants.tsv", another_file),
        ("a record of another number of shards", other_count),
        ("a shard that says caught of rows it did not show", claims_more_than_it_ran),
        ("one shard's record there twice", same_shard_twice),
        ("a record with no rows in it", not_a_record),
        ("no record at all", lambda recs: recs.clear()),
    ]
    bad = []
    for name, breaks in [("the whole set", None)] + cases:
        recs = whole()
        if breaks:
            breaks(recs)
        work = tempfile.mkdtemp(prefix="plants-total-")
        try:
            for key, rec in recs.items():
                json.dump(rec, open(os.path.join(work, "plants-%s.json" % key), "w", encoding="utf-8"))
            _, wrong = total(work, rows)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        if breaks is None and wrong:
            bad.append("the whole set was refused: " + "; ".join(wrong))
        elif breaks is not None and not wrong:
            bad.append("taken as whole: " + name)
        else:
            print("  %s  %s" % ("taken  " if breaks is None else "refused", name))
    if bad:
        print("\n".join("  WRONG   " + b for b in bad))
        return 1
    print("the total takes the whole set and refuses %d broken ones" % len(cases))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--shard", metavar="I/N", help="show the plants of shard I of N only")
    ap.add_argument("--result", metavar="FILE", help="write down the rows shown and what became of them")
    ap.add_argument("--total", metavar="DIR", help="hold the shards' records under DIR to plants.tsv")
    ap.add_argument("--prove-total", action="store_true", help="show the total the records it must refuse")
    args = ap.parse_args()
    if args.prove_total:
        sys.exit(prove_total())
    plants = read_plants()
    if args.total:
        lines, wrong = total(args.total, len(plants))
        print("\n".join(lines + ["  WRONG   " + w for w in wrong]))
        sys.exit(1 if wrong else 0)
    shard, of, label = 1, 1, ""
    if args.shard:
        m = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", args.shard)
        if not m or int(m.group(1)) > int(m.group(2)):
            sys.exit("--shard takes I/N, with I from 1 to N")
        shard, of = int(m.group(1)), int(m.group(2))
        label = "shard %d of %d: " % (shard, of)
    rows = rows_of(shard, of, len(plants))
    if not rows:
        sys.exit("%sno plant to show: tests/static/plants.tsv has %d rows" % (label, len(plants)))
    caught, missed, stale = show(plants, rows)
    if args.result:
        os.makedirs(os.path.dirname(os.path.abspath(args.result)), exist_ok=True)
        with open(args.result, "w", encoding="utf-8") as f:
            json.dump({"shard": shard, "of": of, "rows": len(plants), "ran": rows,
                       "caught": caught, "missed": missed, "stale": stale}, f)
    print("%s%d plants: %d caught, %d missed, %d stale" % (label, len(rows), len(caught), len(missed), len(stale)))
    sys.exit(1 if (missed or stale) else 0)


if __name__ == "__main__":
    main()
