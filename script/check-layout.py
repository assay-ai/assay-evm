#!/usr/bin/env python3
"""The upgrade-safety gate (D-7).

These contracts sit behind UUPS proxies (D-1), so an upgrade REUSES the live storage.
A layout change is therefore safe if and only if it is APPEND-ONLY:

  * every variable in the committed snapshot keeps its slot, its offset, its type and its
    label -- byte for byte;
  * the trailing `__gap` must stay a `uint256[N]` and may only SHRINK, and only by exactly the
    number of slots the newly appended variables consume;
  * new variables may appear only after the last old variable and BEFORE the gap -- the gap has
    to remain the last declaration, or the budget it represents has stopped being a budget;
  * a struct used in a mapping may gain members only at its END, and its numberOfBytes may
    only grow -- inserting a member in the middle relocates every member after it, silently,
    on live data. On the Solana side that left 41 devnet accounts unreadable; here the money
    would still be in the contract.

Anything else is a REDEPLOY decision, not an upgrade, and this script refuses it.

**What it compares, and what it deliberately ignores.** `forge inspect --json` stamps every
entry with an `astId`, and every struct's type KEY embeds one too (`t_struct(Escrow)1591_storage`).
Those numbers move when a comment is added three files away, so comparing them would make this a
gate on editing rather than a gate on layout. Slot, offset, the type's LABEL and the variable's
label are compared; astIds and type keys are not. A snapshot that differs only in astIds is
reported as byte-stale and still passes -- see `check-layout.sh`.

usage: check-layout.py <old-snapshot.json> <new-layout.json>
exit 0 = the layouts are identical;
exit 2 = they differ, and the difference is a legal append;
exit 1 = refused, with the reason on stdout.
"""

import json
import sys

GAP = "__gap"

IDENTICAL = 0
REFUSED = 1
APPENDED = 2


def entries(doc):
    """label -> (slot:int, offset:int, type-key) for the contract's own storage."""
    return {e["label"]: (int(e["slot"]), int(e["offset"]), e["type"]) for e in doc["storage"]}


def tlabel(doc, key):
    return doc["types"][key]["label"]


def tbytes(doc, key):
    return int(doc["types"][key]["numberOfBytes"])


def gap_slots(doc):
    for e in doc["storage"]:
        if e["label"] == GAP:
            return int(e["slot"]), tbytes(doc, e["type"]) // 32
    return None, 0


def check_structs(old, new, problems):
    """Members of a struct may only be appended, and only at the end."""
    old_structs = {
        tlabel(old, k): v for k, v in old["types"].items() if v.get("members") is not None
    }
    new_structs = {
        tlabel(new, k): v for k, v in new["types"].items() if v.get("members") is not None
    }
    for name, o in old_structs.items():
        n = new_structs.get(name)
        if n is None:
            problems.append(f"{name} was removed or renamed")
            continue
        om, nm = o["members"], n["members"]
        if len(nm) < len(om):
            problems.append(f"{name} lost members")
            continue
        for i, m in enumerate(om):
            k = nm[i]
            if (m["label"], m["slot"], m["offset"]) != (k["label"], k["slot"], k["offset"]):
                problems.append(
                    f"{name} member #{i} moved: "
                    f"{m['label']}@{m['slot']}+{m['offset']} -> "
                    f"{k['label']}@{k['slot']}+{k['offset']} "
                    "(a member may be added only at the END of a struct)"
                )
            elif tlabel(old, m["type"]) != tlabel(new, k["type"]):
                problems.append(
                    f"{name} member {m['label']} changed type: "
                    f"{tlabel(old, m['type'])} -> {tlabel(new, k['type'])}"
                )
        if int(n["numberOfBytes"]) < int(o["numberOfBytes"]):
            problems.append(f"{name} shrank")


def canonical(doc):
    """The layout with every volatile number stripped, so two runs of the same source compare
    equal. This is what `identical` means below, and it is why an astId churn is not a change."""
    return {
        "storage": [
            (e["label"], int(e["slot"]), int(e["offset"]), tlabel(doc, e["type"]))
            for e in doc["storage"]
        ],
        "structs": sorted(
            (
                tlabel(doc, k),
                int(v["numberOfBytes"]),
                tuple(
                    (m["label"], m["slot"], m["offset"], tlabel(doc, m["type"]))
                    for m in v["members"]
                ),
            )
            for k, v in doc["types"].items()
            if v.get("members") is not None
        ),
    }


def classify(old, new, problems):
    oe, ne = entries(old), entries(new)
    for label, (slot, off, typ) in oe.items():
        if label == GAP:
            continue
        if label not in ne:
            problems.append(f"variable {label} was removed or renamed")
            continue
        nslot, noff, ntyp = ne[label]
        if (slot, off) != (nslot, noff):
            problems.append(f"variable {label} moved: slot {slot}+{off} -> {nslot}+{noff}")
        if tlabel(old, typ) != tlabel(new, ntyp):
            problems.append(
                f"variable {label} changed type: {tlabel(old, typ)} -> {tlabel(new, ntyp)}"
            )

    old_gap_slot, old_gap_len = gap_slots(old)
    new_gap_slot, new_gap_len = gap_slots(new)
    if old_gap_slot is None or new_gap_slot is None:
        problems.append("every contract must end with a `uint256[N] private __gap;`")
    else:
        # The gap is skipped by the loop above (its slot is *supposed* to move), so its type is
        # checked here or nowhere. A retyped gap is not an append: it is a differently shaped
        # budget wearing the same name, and `uint256[N]` is the shape the whole rule is written
        # against -- `gap_slots` divides `numberOfBytes` by 32 to get a slot count.
        for doc, which in ((old, "the snapshot"), (new, "the new layout")):
            gap_type = next(e["type"] for e in doc["storage"] if e["label"] == GAP)
            if not tlabel(doc, gap_type).startswith("uint256["):
                problems.append(
                    f"__gap in {which} is {tlabel(doc, gap_type)}; it must stay uint256[N]"
                )

        added = [l for l in ne if l not in oe]
        for label in added:
            slot, _, _ = ne[label]
            if slot < old_gap_slot:
                problems.append(
                    f"new variable {label} sits at slot {slot}, before the old gap at "
                    f"{old_gap_slot} -- appends go at the END, never in the middle"
                )
            elif slot >= new_gap_slot:
                problems.append(
                    f"new variable {label} sits at slot {slot}, at or AFTER the new gap at "
                    f"{new_gap_slot} -- `__gap` must remain the LAST declaration, otherwise it "
                    "stops being an append budget and starts being dead storage in the middle"
                )
        consumed = new_gap_slot - old_gap_slot
        if consumed < 0:
            problems.append("the gap moved backwards")
        elif old_gap_len - new_gap_len != consumed:
            problems.append(
                f"the gap shrank by {old_gap_len - new_gap_len} slots but the new fields "
                f"consumed {consumed}; they must be equal"
            )

    check_structs(old, new, problems)


def main(old_path, new_path):
    old = json.load(open(old_path))
    new = json.load(open(new_path))
    problems = []

    classify(old, new, problems)

    if problems:
        print(f"REFUSED: {new_path} is not an append-only change to {old_path}")
        for p in problems:
            print(f"  - {p}")
        return REFUSED

    if canonical(old) == canonical(new):
        return IDENTICAL
    return APPENDED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
