#!/usr/bin/env python3
"""Project unified-log records onto shareable fields; omit macOS path/backtrace metadata."""
import json
import sys

FIELDS = ("timestamp", "messageType", "subsystem", "category", "processID", "eventMessage")


def project(record):
    message = record.get("eventMessage")
    if record.get("subsystem") != "local.freely.app" or not isinstance(message, str) or not message.startswith("run="):
        return None
    return {key: record[key] for key in FIELDS if key in record}


def main():
    for line in sys.stdin:
        if not line.strip() or not line.lstrip().startswith("{"):
            continue  # log(1) can write a human-readable filter header.
        record = project(json.loads(line))
        if record is not None:
            print(json.dumps(record, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
