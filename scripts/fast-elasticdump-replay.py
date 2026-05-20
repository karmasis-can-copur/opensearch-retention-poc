#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait


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


def post_bulk(url, payload, timeout):
    req = urllib.request.Request(
        f"{url}/_bulk?filter_path=errors,took",
        data=payload,
        method="POST",
        headers={"content-type": "application/x-ndjson"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        result = json.loads(response.read().decode() or "{}")
    if result.get("errors"):
        raise RuntimeError("Bulk request returned errors=true")
    return int(result.get("took", 0))


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
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    url = args.url.rstrip("/")
    ensure_index(url, args.index_name, args.timeout)

    started = time.monotonic()
    submitted_docs = 0
    completed_docs = 0
    inflight = {}
    bulk_took_ms = 0

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        for upto_docs, payload in iter_bulk_batches(args.dump_file, args.index_name, args.batch_docs):
            while len(inflight) >= args.workers * 2:
                done, _ = wait(inflight, return_when=FIRST_COMPLETED)
                for future in done:
                    docs_in_batch = inflight.pop(future)
                    bulk_took_ms += future.result()
                    completed_docs += docs_in_batch
            docs_in_batch = upto_docs - submitted_docs
            submitted_docs = upto_docs
            inflight[executor.submit(post_bulk, url, payload, args.timeout)] = docs_in_batch
            if submitted_docs == docs_in_batch or submitted_docs % 100000 <= args.batch_docs:
                elapsed = max(time.monotonic() - started, 0.001)
                print(f"submitted={submitted_docs} completed={completed_docs} rate={completed_docs / elapsed:.0f} docs/s", flush=True)

        for future in list(inflight):
            docs_in_batch = inflight[future]
            bulk_took_ms += future.result()
            completed_docs += docs_in_batch

    if args.refresh:
        request_json("POST", f"{url}/{args.index_name}/_refresh", timeout=args.timeout)

    elapsed = max(time.monotonic() - started, 0.001)
    print(
        f"completed={completed_docs} elapsed_seconds={elapsed:.2f} rate={completed_docs / elapsed:.0f} docs/s bulk_took_ms={bulk_took_ms}",
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"error={exc}", file=sys.stderr, flush=True)
        raise
