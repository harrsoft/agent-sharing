#!/bin/sh
# verify-beacon.sh — walk alpha@harrsoft's porch light as a stranger (D6 call site).
#
# Verifies that beacon.json is signed by the key it names, and that the key's
# SHA-256 fingerprint matches the one the beacon declares. Needs: curl, openssl,
# python3. No house docs, no house access.
#
# Usage:
#   sh verify-beacon.sh                 # fetch live from HarrSoft/agent-sharing
#   sh verify-beacon.sh <dir>           # verify beacon.json + agent-key.pub in <dir>
#   sh verify-beacon.sh <base-url>      # fetch from a base URL (…/alpha/identity)
#
# Exit: 0 verified · 1 verification failed · 2 could not fetch/read inputs.
set -eu

DEFAULT_BASE="https://raw.githubusercontent.com/HarrSoft/agent-sharing/main/alpha/identity"
ARG="${1:-$DEFAULT_BASE}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

case "$ARG" in
  http://*|https://*)
    curl -fsS -o "$tmp/beacon.json"   "$ARG/beacon.json"    || { echo "BLIND: could not fetch beacon.json" >&2; exit 2; }
    curl -fsS -o "$tmp/agent-key.pub" "$ARG/agent-key.pub"  || { echo "BLIND: could not fetch agent-key.pub" >&2; exit 2; }
    ;;
  *)
    [ -r "$ARG/beacon.json" ]   || { echo "BLIND: no beacon.json in $ARG" >&2; exit 2; }
    [ -r "$ARG/agent-key.pub" ] || { echo "BLIND: no agent-key.pub in $ARG" >&2; exit 2; }
    cp "$ARG/beacon.json" "$tmp/beacon.json"
    cp "$ARG/agent-key.pub" "$tmp/agent-key.pub"
    ;;
esac

# 1. fingerprint of the fetched key vs the fingerprint the beacon declares
DECLARED="$(python3 -c 'import json;print(json.load(open("'"$tmp"'/beacon.json"))["identity"]["publicKeyFingerprint"])')"
ACTUAL="sha256:$(openssl pkey -pubin -in "$tmp/agent-key.pub" -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
if [ "$DECLARED" != "$ACTUAL" ]; then
  echo "FAIL: key fingerprint mismatch — beacon declares $DECLARED, fetched key is $ACTUAL" >&2
  exit 1
fi

# 2. signature over the canonical bytes (beacon minus 'attestation', sorted, compact)
python3 - "$tmp" "$ACTUAL" <<'PY'
import json, base64, subprocess, sys, datetime
tmp = sys.argv[1]
actual = sys.argv[2]
d = json.load(open(f"{tmp}/beacon.json"))
sig = base64.b64decode(d.pop("attestation")["signature"])
canon = json.dumps(d, sort_keys=True, separators=(",", ":")).encode()
open(f"{tmp}/canon.bin","wb").write(canon)
open(f"{tmp}/sig.bin","wb").write(sig)
p = subprocess.run(["openssl","dgst","-sha256","-verify",f"{tmp}/agent-key.pub",
                    "-signature",f"{tmp}/sig.bin",f"{tmp}/canon.bin"],
                   capture_output=True)
if p.returncode != 0:
    sys.stderr.write("FAIL: signature did not verify — " + p.stderr.decode().strip() + "\n")
    sys.exit(1)
ts  = d["coherence"]["timestamp"]
nxt = d["coherence"].get("expectedNext","?")
age = ""
try:
    t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
    age = f" · age {secs/3600:.1f}h"
except Exception:
    pass
print(f"VERIFIED · {d['identity']['agentId']} · {ts} · expected next {nxt}{age} · fingerprint {actual}")
PY
