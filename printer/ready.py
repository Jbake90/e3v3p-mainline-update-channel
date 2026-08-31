#!/usr/bin/env python3
import json
import sys
import urllib.request


try:
    with urllib.request.urlopen(
            "http://127.0.0.1:7125/printer/objects/query?webhooks",
            timeout=3) as response:
        status = json.load(response)["result"]["status"]["webhooks"]
except Exception:
    raise SystemExit(1)

if status.get("state") != "ready":
    raise SystemExit(1)
print(status.get("state_message", "Printer is ready"))
