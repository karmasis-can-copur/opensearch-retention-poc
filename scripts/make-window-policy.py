#!/usr/bin/env python3
import argparse
import copy
import datetime as dt
import json
from pathlib import Path


def parse_day(value):
    return dt.date.fromisoformat(value)


def parse_now(value):
    if not value:
        return dt.datetime.now(dt.timezone.utc)
    normalized = value.replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def day_count(start, end):
    return (end - start).days + 1


def age_floor_days(now, day):
    midnight = dt.datetime(day.year, day.month, day.day, tzinfo=dt.timezone.utc)
    return int((now - midnight).total_seconds() // 86400)


def replace_transition(policy, state_name, target_state, min_age):
    states = policy["policy"]["states"]
    for state in states:
        if state.get("name") != state_name:
            continue
        for transition in state.get("transitions", []):
            if transition.get("state_name") == target_state:
                transition.setdefault("conditions", {})["min_index_age"] = f"{min_age}d"
                return
    raise ValueError(f"Transition not found: {state_name} -> {target_state}")


def set_hot_transitions(policy, hot_after, snapshot_after):
    states = policy["policy"]["states"]
    for state in states:
        if state.get("name") == "hot":
            state["transitions"] = [
                {
                    "state_name": "snapshot_ready",
                    "conditions": {"min_index_age": f"{snapshot_after}d"},
                },
                {
                    "state_name": "cold",
                    "conditions": {"min_index_age": f"{hot_after}d"},
                },
            ]
            return
    raise ValueError("Hot state not found.")


def normalize_remote_conversion(policy):
    for state in policy["policy"]["states"]:
        for action in state.get("actions", []):
            convert = action.get("convert_index_to_remote")
            if convert is None:
                continue
            for unsupported in ["ignore_index_settings", "number_of_replicas"]:
                convert.pop(unsupported, None)


def configure_force_merge(policy, mode):
    keep_by_state = {
        "both": {"cold", "snapshot_ready"},
        "cold": {"cold"},
        "snapshot": {"snapshot_ready"},
        "none": set(),
    }[mode]

    for state in policy["policy"]["states"]:
        state_name = state.get("name")
        state["actions"] = [
            action
            for action in state.get("actions", [])
            if "force_merge" not in action or state_name in keep_by_state
        ]


def build_window_policy(base_policy, from_day, to_day, hot_days, cold_days, now, force_merge_mode):
    total_days = day_count(from_day, to_day)
    if total_days <= hot_days + cold_days:
        raise ValueError("Date window must contain at least one searchable-snapshot day.")

    hot_start = to_day - dt.timedelta(days=hot_days - 1)
    cold_start = hot_start - dt.timedelta(days=cold_days)
    snapshot_end = cold_start - dt.timedelta(days=1)

    hot_after = age_floor_days(now, hot_start) + 1
    snapshot_after = age_floor_days(now, cold_start) + 1
    if hot_after <= 0 or snapshot_after <= hot_after:
        raise ValueError("Computed thresholds are invalid. Check date window and current time.")

    policy = copy.deepcopy(base_policy)
    set_hot_transitions(policy, hot_after, snapshot_after)
    replace_transition(policy, "cold", "snapshot_ready", snapshot_after)
    normalize_remote_conversion(policy)
    configure_force_merge(policy, force_merge_mode)
    policy["policy"]["description"] = (
        "Dataskope windowed real-data retention PoC: "
        f"{from_day}..{to_day}, last {hot_days}d hot, previous {cold_days}d cold, "
        "older days searchable snapshot. Thresholds are calculated from index.creation_date. "
        f"force_merge={force_merge_mode}."
    )

    return policy, {
        "from": from_day,
        "to": to_day,
        "snapshot": (from_day, snapshot_end),
        "cold": (cold_start, hot_start - dt.timedelta(days=1)),
        "hot": (hot_start, to_day),
        "hot_after_days": hot_after,
        "snapshot_after_days": snapshot_after,
        "cold_age_window_days": snapshot_after - hot_after,
        "force_merge": force_merge_mode,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Create an ISM policy whose min_index_age thresholds fit a real-date PoC window."
    )
    parser.add_argument("--from-date", required=True)
    parser.add_argument("--to-date", required=True)
    parser.add_argument("--hot-days", type=int, default=3)
    parser.add_argument("--cold-days", type=int, default=3)
    parser.add_argument(
        "--base-policy",
        default="opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json",
    )
    parser.add_argument(
        "--out",
        default="opensearch/lifecycle/dataskope-ism-policy.window.poc.json",
    )
    parser.add_argument("--now-utc", help="Override current UTC time for repeatable tests.")
    parser.add_argument(
        "--force-merge",
        choices=["both", "cold", "snapshot", "none"],
        default="none",
        help="Keep force_merge actions in both stages, cold only, snapshot_ready only, or neither.",
    )
    args = parser.parse_args()

    from_day = parse_day(args.from_date)
    to_day = parse_day(args.to_date)
    if from_day > to_day:
        raise ValueError("--from-date must be before --to-date")
    if args.hot_days < 1 or args.cold_days < 1:
        raise ValueError("--hot-days and --cold-days must be positive")

    base_path = Path(args.base_policy)
    out_path = Path(args.out)
    with base_path.open("r", encoding="utf-8") as handle:
        base_policy = json.load(handle)

    policy, layout = build_window_policy(
        base_policy,
        from_day,
        to_day,
        args.hot_days,
        args.cold_days,
        parse_now(args.now_utc),
        args.force_merge,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(policy, handle, indent=2)
        handle.write("\n")

    print(f"policy_file={out_path.as_posix()}")
    print(f"hot={layout['hot'][0]}..{layout['hot'][1]}")
    print(f"cold={layout['cold'][0]}..{layout['cold'][1]}")
    print(f"searchable_snapshot={layout['snapshot'][0]}..{layout['snapshot'][1]}")
    print(f"HOT_AFTER_DAYS={layout['hot_after_days']}")
    print(f"SNAPSHOT_AFTER_DAYS={layout['snapshot_after_days']}")
    print(f"COLD_DAYS={layout['cold_age_window_days']}")
    print(f"FORCE_MERGE={layout['force_merge']}")


if __name__ == "__main__":
    main()
