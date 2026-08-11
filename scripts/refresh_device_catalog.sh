#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  echo "usage: $0 <device-udid> [output.plist]" >&2
  exit 64
fi

UDID="$1"
OUTPUT="${2:-/tmp/MCMIdentifiers.plist}"
PYMOBILEDEVICE3="${PYMOBILEDEVICE3:-pymobiledevice3}"
TEMP_JSON="$(mktemp /tmp/filza-mcm-apps.XXXXXX.json)"
trap 'trash "$TEMP_JSON"' EXIT

"$PYMOBILEDEVICE3" apps list --type Any --udid "$UDID" > "$TEMP_JSON"
python3 - "$TEMP_JSON" "$OUTPUT" <<'PY'
import json
import plistlib
import re
import sys

source, output = sys.argv[1:]
records = json.load(open(source, "r", encoding="utf-8"))
safe = re.compile(r"^[A-Za-z0-9._-]{1,255}$")
apps = set()
groups = set()
for map_key, record in records.items():
    if not isinstance(record, dict):
        continue
    identifier = record.get("CFBundleIdentifier") or map_key
    if isinstance(identifier, str) and safe.fullmatch(identifier):
        apps.add(identifier)
    containers = record.get("GroupContainers")
    if isinstance(containers, dict):
        groups.update(key for key in containers if isinstance(key, str) and safe.fullmatch(key))

catalog = {
    "AppData": sorted(apps),
    "AppGroups": sorted(groups),
    "ExtensionData": [],
    "VPNData": [],
    "ServiceData": [],
    "SystemData": [],
    "SystemGroups": [],
    "ProtectedData": [],
}
with open(output, "wb") as stream:
    plistlib.dump(catalog, stream, sort_keys=False)
print(f"wrote {output}: app_data={len(apps)} app_groups={len(groups)}")
PY
