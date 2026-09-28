#!/bin/bash
# UDID of an available iPhone simulator on the newest iOS runtime.
xcrun simctl list devices available -j | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    m=re.search(r"iOS-(\d+)-(\d+)",rt)
    if not m: continue
    v=(int(m.group(1)),int(m.group(2)))
    for x in devs:
        if x["name"].startswith("iPhone") and (best is None or v>best[0]): best=(v,x["udid"])
print(best[1])'
