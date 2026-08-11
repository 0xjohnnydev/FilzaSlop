#!/bin/bash

set -euo pipefail
umask 077

BUNDLE_ID="com.apple.mobile.MobileHouseArrest"

usage() {
    cat <<'EOF'
Usage:
  P12_PASSWORD=... scripts/sign_ipa.sh \
    unsigned.ipa certificate.p12 profile.mobileprovision signed.ipa

The provisioning profile must allow com.apple.mobile.MobileHouseArrest.
A wildcard iOS development profile is the simplest option.
EOF
}

if [[ $# -ne 4 ]]; then
    usage >&2
    exit 2
fi

if [[ "${P12_PASSWORD+x}" != x ]]; then
    echo "P12_PASSWORD is not set." >&2
    exit 2
fi

for command in awk codesign file plutil python3 security sed shasum unzip uuidgen zip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is missing: $command" >&2
        exit 1
    fi
done
if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    echo "Required command is missing: /usr/libexec/PlistBuddy" >&2
    exit 1
fi

absolute_path() {
    python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

INPUT_IPA="$(absolute_path "$1")"
CERTIFICATE_P12="$(absolute_path "$2")"
PROVISIONING_PROFILE="$(absolute_path "$3")"
OUTPUT_IPA="$(absolute_path "$4")"

for input in "$INPUT_IPA" "$CERTIFICATE_P12" "$PROVISIONING_PROFILE"; do
    if [[ ! -f "$input" ]]; then
        echo "Input file does not exist: $input" >&2
        exit 1
    fi
done

if [[ "$INPUT_IPA" == "$OUTPUT_IPA" ]]; then
    echo "The output IPA must differ from the input IPA." >&2
    exit 1
fi

WORK_DIRECTORY="$(mktemp -d)"
KEYCHAIN="$WORK_DIRECTORY/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
    keychain="$(printf '%s' "$keychain" |
        sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
    if [[ -n "$keychain" ]]; then
        ORIGINAL_KEYCHAINS+=("$keychain")
    fi
done < <(security list-keychains -d user)

cleanup() {
    if [[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
            >/dev/null 2>&1 || true
    fi
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    python3 - "$WORK_DIRECTORY" <<'PY'
import os
import shutil
import sys
path = sys.argv[1]
if os.path.isdir(path):
    shutil.rmtree(path)
PY
}
trap cleanup EXIT INT TERM

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
security import "$CERTIFICATE_P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

PROFILE_PLIST="$WORK_DIRECTORY/profile.plist"
security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"

IDENTITIES_FILE="$WORK_DIRECTORY/identities.txt"
security find-identity -v -p codesigning "$KEYCHAIN" |
    awk '/[0-9]+\) [A-F0-9]{40}/ { print $2 }' > "$IDENTITIES_FILE"
if [[ ! -s "$IDENTITIES_FILE" ]]; then
    echo "The P12 file does not contain a usable code-signing identity." >&2
    exit 1
fi

SIGNING_IDENTITY="$(python3 - "$PROFILE_PLIST" "$IDENTITIES_FILE" <<'PY'
import hashlib
import plistlib
import sys

profile_path, identities_path = sys.argv[1:]
with open(profile_path, "rb") as stream:
    profile = plistlib.load(stream)
with open(identities_path, "r", encoding="utf-8") as stream:
    identities = [line.strip().upper() for line in stream if line.strip()]

allowed = {
    hashlib.sha1(bytes(certificate)).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
}
for identity in identities:
    if identity in allowed:
        print(identity)
        break
else:
    raise SystemExit("No P12 identity belongs to the provisioning profile.")
PY
)"

PAYLOAD_DIRECTORY="$WORK_DIRECTORY/extracted"
mkdir -p "$PAYLOAD_DIRECTORY"
unzip -q "$INPUT_IPA" -d "$PAYLOAD_DIRECTORY"

APP_COUNT="$(find "$PAYLOAD_DIRECTORY/Payload" -maxdepth 1 -type d -name '*.app' |
    wc -l | tr -d ' ')"
if [[ "$APP_COUNT" != "1" ]]; then
    echo "The IPA must contain exactly one application bundle." >&2
    exit 1
fi
APP="$(find "$PAYLOAD_DIRECTORY/Payload" -maxdepth 1 -type d -name '*.app' -print)"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"

# Remove all signatures, profiles, and generated device catalogs from the
# working copy before the new user-specific signature is applied.
python3 - "$APP" <<'PY'
import os
import shutil
import sys

app = sys.argv[1]
for root, dirs, files in os.walk(app, topdown=False):
    for name in files:
        if name in {"embedded.mobileprovision", "MCMIdentifiers.plist"}:
            os.unlink(os.path.join(root, name))
    for name in dirs:
        if name == "_CodeSignature":
            shutil.rmtree(os.path.join(root, name))
PY

BUNDLE_IDS="$WORK_DIRECTORY/bundle_ids.txt"
: > "$BUNDLE_IDS"
find "$APP" -type d \( -name '*.app' -o -name '*.appex' \) -print0 |
while IFS= read -r -d '' bundle; do
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$bundle/Info.plist")"
    printf '%s\n' "$identifier" >> "$BUNDLE_IDS"
done

TEAM_ID_FILE="$WORK_DIRECTORY/team_id.txt"
python3 - "$PROFILE_PLIST" "$SIGNING_IDENTITY" "$BUNDLE_IDS" "$TEAM_ID_FILE" <<'PY'
import datetime
import fnmatch
import hashlib
import plistlib
import sys

profile_path, identity, bundle_ids_path, team_id_path = sys.argv[1:]
with open(profile_path, "rb") as stream:
    profile = plistlib.load(stream)

expiration = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if expiration is None:
    raise SystemExit("The provisioning profile has no expiration date.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= now:
    raise SystemExit("The provisioning profile has expired.")

teams = profile.get("TeamIdentifier") or []
if len(teams) != 1:
    raise SystemExit("The provisioning profile has no unique TeamIdentifier.")
team_id = teams[0]

entitlements = profile.get("Entitlements") or {}
pattern = entitlements.get("application-identifier")
if not isinstance(pattern, str):
    raise SystemExit("The provisioning profile has no application-identifier.")

with open(bundle_ids_path, "r", encoding="utf-8") as stream:
    bundle_ids = [line.strip() for line in stream if line.strip()]
for bundle_id in bundle_ids:
    required = f"{team_id}.{bundle_id}"
    if not fnmatch.fnmatchcase(required, pattern):
        raise SystemExit(
            f"The profile pattern {pattern!r} does not allow {bundle_id!r}."
        )

certificate_hashes = {
    hashlib.sha1(bytes(certificate)).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
}
if identity.upper() not in certificate_hashes:
    raise SystemExit("The P12 certificate is not included in the profile.")

devices = profile.get("ProvisionedDevices") or []
all_devices = bool(profile.get("ProvisionsAllDevices"))
if not devices and not all_devices:
    raise SystemExit("The profile does not authorize any installation device.")

with open(team_id_path, "w", encoding="utf-8") as stream:
    stream.write(team_id)

print(f"Profile: {profile.get('Name', 'unnamed')}")
print(f"Team: {team_id}")
print(f"Authorized devices: {len(devices)}")
print(f"Expires: {expiration.isoformat()}")
PY
TEAM_ID="$(cat "$TEAM_ID_FILE")"

make_entitlements() {
    local bundle_id="$1"
    local output="$2"
    python3 - "$PROFILE_PLIST" "$TEAM_ID" "$bundle_id" "$output" <<'PY'
import copy
import plistlib
import sys

profile_path, team_id, bundle_id, output_path = sys.argv[1:]
with open(profile_path, "rb") as stream:
    profile = plistlib.load(stream)

entitlements = copy.deepcopy(profile.get("Entitlements") or {})
application_identifier = f"{team_id}.{bundle_id}"
entitlements["application-identifier"] = application_identifier
entitlements["com.apple.developer.team-identifier"] = team_id

groups = entitlements.get("keychain-access-groups")
if isinstance(groups, list):
    entitlements["keychain-access-groups"] = [
        application_identifier if value == f"{team_id}.*" else value
        for value in groups
    ]

with open(output_path, "wb") as stream:
    plistlib.dump(entitlements, stream, fmt=plistlib.FMT_XML, sort_keys=True)
PY
}

sign_plain() {
    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --keychain "$KEYCHAIN" \
        --timestamp=none \
        "$1"
}

# Sign every Mach-O first. Framework, extension, and application bundles are
# then sealed from the inside out.
find "$APP" -type f -print0 |
while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
        sign_plain "$candidate"
    fi
done

find "$APP" -depth -type d -name '*.framework' -print0 |
while IFS= read -r -d '' framework; do
    sign_plain "$framework"
done

find "$APP" -depth -type d -name '*.appex' -print0 |
while IFS= read -r -d '' extension; do
    extension_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$extension/Info.plist")"
    extension_entitlements="$WORK_DIRECTORY/$(basename "$extension").xcent"
    make_entitlements "$extension_id" "$extension_entitlements"
    cp "$PROVISIONING_PROFILE" "$extension/embedded.mobileprovision"
    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --keychain "$KEYCHAIN" \
        --entitlements "$extension_entitlements" \
        --generate-entitlement-der \
        --timestamp=none \
        "$extension"
done

APP_ENTITLEMENTS="$WORK_DIRECTORY/app.xcent"
make_entitlements "$BUNDLE_ID" "$APP_ENTITLEMENTS"
cp "$PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"
codesign --force \
    --sign "$SIGNING_IDENTITY" \
    --keychain "$KEYCHAIN" \
    --entitlements "$APP_ENTITLEMENTS" \
    --generate-entitlement-der \
    --timestamp=none \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

CODE_DIRECTORY_ID="$(codesign -dvv "$APP" 2>&1 |
    sed -n 's/^Identifier=//p' | head -n 1)"
if [[ "$CODE_DIRECTORY_ID" != "$BUNDLE_ID" ]]; then
    echo "Unexpected CodeDirectory identifier: $CODE_DIRECTORY_ID" >&2
    exit 1
fi

SIGNED_ENTITLEMENTS="$WORK_DIRECTORY/signed-entitlements.plist"
codesign -d --entitlements :- "$APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
APPLICATION_IDENTIFIER="$(plutil -extract application-identifier raw \
    "$SIGNED_ENTITLEMENTS")"
if [[ "$APPLICATION_IDENTIFIER" != "$TEAM_ID.$BUNDLE_ID" ]]; then
    echo "Unexpected application-identifier: $APPLICATION_IDENTIFIER" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_IPA")"
if [[ -e "$OUTPUT_IPA" ]]; then
    python3 - "$OUTPUT_IPA" <<'PY'
import os
import sys
os.unlink(sys.argv[1])
PY
fi
(
    cd "$PAYLOAD_DIRECTORY"
    zip -qry -X "$OUTPUT_IPA" Payload
)
unzip -tq "$OUTPUT_IPA"

echo "Signed IPA: $OUTPUT_IPA"
echo "Bundle identifier: $BUNDLE_ID"
echo "CodeDirectory identifier: $CODE_DIRECTORY_ID"
echo "Application identifier: $APPLICATION_IDENTIFIER"
shasum -a 256 "$OUTPUT_IPA"
