#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait


TRANSIENT_BULK_STATUSES = {408, 429, 500, 502, 503, 504}


def request_json(method, url, body=None, timeout=300):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"content-type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        payload = response.read()
        return json.loads(payload.decode() or "{}") if payload else {}


def split_bulk_payload(payload):
    text = payload.decode()
    if text.endswith("\n"):
        text = text[:-1]
    if not text:
        return []
    lines = text.split("\n")
    if len(lines) % 2 != 0:
        raise RuntimeError(f"Bulk payload has an odd NDJSON line count: {len(lines)}")
    return [(lines[i], lines[i + 1]) for i in range(0, len(lines), 2)]


def encode_bulk_pairs(pairs):
    lines = []
    for action, source in pairs:
        lines.append(action)
        lines.append(source)
    return ("\n".join(lines) + "\n").encode()


def append_failed_items(path, failed_items):
    if not failed_items:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        for action, source, status, error in failed_items:
            handle.write(json.dumps({
                "status": status,
                "error": error,
                "action": json.loads(action),
                "source": json.loads(source),
            }, separators=(",", ":"), ensure_ascii=False))
            handle.write("\n")


def post_bulk(url, payload, timeout, max_retries, failed_output):
    total_took = 0
    attempt = 0
    current_payload = payload

    while True:
        req = urllib.request.Request(
            f"{url}/_bulk",
            data=current_payload,
            method="POST",
            headers={"content-type": "application/x-ndjson"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            result = json.loads(response.read().decode() or "{}")

        total_took += int(result.get("took", 0))
        if not result.get("errors"):
            return total_took, 0

        pairs = split_bulk_payload(current_payload)
        retry_pairs = []
        permanent_failures = []

        for offset, item in enumerate(result.get("items", [])):
            op = item.get("index") or item.get("create") or item.get("update") or item.get("delete") or {}
            error = op.get("error")
            if not error:
                continue

            status = int(op.get("status", 0) or 0)
            if offset >= len(pairs):
                raise RuntimeError(
                    f"Bulk response item offset {offset} is outside payload pair count {len(pairs)}"
                )
            action, source = pairs[offset]
            if status in TRANSIENT_BULK_STATUSES and attempt < max_retries:
                retry_pairs.append((action, source))
            else:
                permanent_failures.append((action, source, status, error))

        append_failed_items(failed_output, permanent_failures)

        if retry_pairs:
            attempt += 1
            time.sleep(min(2 ** attempt, 30))
            current_payload = encode_bulk_pairs(retry_pairs)
            continue

        if permanent_failures:
            print(f"bulk_permanent_errors={len(permanent_failures)} failed_output={failed_output}", flush=True)
            return total_took, len(permanent_failures)

        raise RuntimeError("Bulk request returned errors=true but no item errors were present in the response")


def creation_date_from_index(index_name):
    match = re.search(r"_(\d{4})_(\d{2})_(\d{2})$", index_name)
    if not match:
        raise ValueError(f"Index name does not end with yyyy_MM_dd: {index_name}")
    year, month, day = map(int, match.groups())
    instant = dt.datetime(year, month, day, tzinfo=dt.timezone.utc)
    return str(int(instant.timestamp() * 1000))


def ensure_index(url, index_name, timeout):
    body = {"settings": {"index.creation_date": creation_date_from_index(index_name)}}
    try:
        request_json("PUT", f"{url}/{index_name}", body, timeout)
        print(f"index_created={index_name}", flush=True)
    except urllib.error.HTTPError as error:
        text = error.read().decode(errors="replace")
        if error.code == 400 and "resource_already_exists_exception" in text:
            print(f"index_exists={index_name}", flush=True)
            return
        raise RuntimeError(f"Failed to create index {index_name}: HTTP {error.code} {text}") from error


def iter_bulk_batches(path, index_name, batch_docs):
    docs = 0
    lines = []
    with open(path, "rb") as handle:
        for raw in handle:
            if not raw.strip():
                continue
            item = json.loads(raw)
            source = item.get("_source", item)
            doc_id = item.get("_id")
            action = {"index": {"_index": index_name}}
            if doc_id:
                action["index"]["_id"] = doc_id
            lines.append(json.dumps(action, separators=(",", ":")))
            lines.append(json.dumps(source, separators=(",", ":"), ensure_ascii=False))
            docs += 1
            if docs % batch_docs == 0:
                yield docs, ("\n".join(lines) + "\n").encode()
                lines.clear()
    if lines:
        yield docs, ("\n".join(lines) + "\n").encode()


def main():
    parser = argparse.ArgumentParser(description="Fast elasticdump hit replay to OpenSearch bulk API.")
    parser.add_argument("dump_file")
    parser.add_argument("index_name")
    parser.add_argument("--url", default="http://localhost:9200")
    parser.add_argument("--batch-docs", type=int, default=5000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--max-retries", type=int, default=3)
    parser.add_argument("--failed-output", default="artifacts/rejected-events/fast-elasticdump-replay-errors.ndjson")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    url = args.url.rstrip("/")
    ensure_index(url, args.index_name, args.timeout)

    started = time.monotonic()
    submitted_docs = 0
    completed_docs = 0
    failed_docs = 0
    inflight = {}
    bulk_took_ms = 0

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        for upto_docs, payload in iter_bulk_batches(args.dump_file, args.index_name, args.batch_docs):
            while len(inflight) >= args.workers * 2:
                done, _ = wait(inflight, return_when=FIRST_COMPLETED)
                for future in done:
                    docs_in_batch = inflight.pop(future)
                    took, failed = future.result()
                    bulk_took_ms += took
                    failed_docs += failed
                    completed_docs += docs_in_batch - failed
            docs_in_batch = upto_docs - submitted_docs
            submitted_docs = upto_docs
            inflight[executor.submit(post_bulk, url, payload, args.timeout, args.max_retries, args.failed_output)] = docs_in_batch
            if submitted_docs == docs_in_batch or submitted_docs % 100000 <= args.batch_docs:
                elapsed = max(time.monotonic() - started, 0.001)
                print(f"submitted={submitted_docs} completed={completed_docs} rate={completed_docs / elapsed:.0f} docs/s", flush=True)

        for future in list(inflight):
            docs_in_batch = inflight[future]
            took, failed = future.result()
            bulk_took_ms += took
            failed_docs += failed
            completed_docs += docs_in_batch - failed

    if args.refresh:
        request_json("POST", f"{url}/{args.index_name}/_refresh", timeout=args.timeout)

    elapsed = max(time.monotonic() - started, 0.001)
    print(
        f"completed={completed_docs} failed={failed_docs} elapsed_seconds={elapsed:.2f} rate={completed_docs / elapsed:.0f} docs/s bulk_took_ms={bulk_took_ms}",
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"error={exc}", file=sys.stderr, flush=True)
        raise
