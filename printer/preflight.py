#!/usr/bin/env python3
import json
import sys
import urllib.request


URL = (
    "http://127.0.0.1:7125/printer/objects/query?"
    "webhooks&print_stats&idle_timeout&heater_bed&extruder&fan"
)


def fail(message):
    print("BLOCKED: " + message, file=sys.stderr)
    raise SystemExit(2)


try:
    with urllib.request.urlopen(URL, timeout=4) as response:
        result = json.load(response)["result"]["status"]
except Exception as exc:
    fail("Moonraker safety query failed: %s" % exc)

if result["webhooks"]["state"] != "ready":
    fail("Klippy is not Ready")
if result["print_stats"]["state"] in ("printing", "paused"):
    fail("a print is active or paused")
if result["idle_timeout"]["state"] == "Printing":
    fail("idle_timeout still reports Printing")
for heater in ("heater_bed", "extruder"):
    status = result[heater]
    if float(status.get("target", 0.0)) != 0.0:
        fail("%s target is nonzero" % heater)
    if float(status.get("power", 0.0)) != 0.0:
        fail("%s power is nonzero" % heater)

print("SAFE_IDLE_PASS")
