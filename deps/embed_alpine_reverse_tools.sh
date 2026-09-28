#!/usr/bin/env bash
set -euo pipefail

# Install radare2 and its aarch64 Alpine dependencies into an unpacked
# minirootfs before fakefsify converts it for iSH. This runs on the build host;
# the resulting ELF and libraries ship inside the iOS app's rootfs.

STAGE_DIR="${1:?stage directory required}"
ALPINE_VERSION="${2:-3.21}"
ALPINE_ARCH="${3:-aarch64}"
MIRROR="${4:-https://dl-cdn.alpinelinux.org/alpine}"
CACHE_DIR="${5:-$(dirname "$STAGE_DIR")/.apk-cache}"
INDEX_DIR="$CACHE_DIR/index"
APK_DIR="$CACHE_DIR/apk"

mkdir -p "$INDEX_DIR" "$APK_DIR" "$STAGE_DIR"
export STAGE_DIR ALPINE_VERSION ALPINE_ARCH MIRROR INDEX_DIR APK_DIR

python3 <<'PY'
import io
import json
import os
import re
import tarfile
import urllib.request
from collections import deque
from pathlib import PurePosixPath

stage = os.environ["STAGE_DIR"]
version = os.environ["ALPINE_VERSION"]
arch = os.environ["ALPINE_ARCH"]
mirror = os.environ["MIRROR"].rstrip("/")
index_dir = os.environ["INDEX_DIR"]
apk_dir = os.environ["APK_DIR"]

repos = ["main", "community"]
records = []

def fetch(url, destination):
    if os.path.isfile(destination) and os.path.getsize(destination) > 0:
        return
    tmp = destination + ".tmp"
    urllib.request.urlretrieve(url, tmp)
    os.replace(tmp, destination)

def parse_index(repo):
    destination = os.path.join(index_dir, repo + ".tar.gz")
    fetch(f"{mirror}/v{version}/{repo}/{arch}/APKINDEX.tar.gz", destination)
    with tarfile.open(destination, "r:gz") as archive:
        raw = archive.extractfile("APKINDEX")
        if raw is None:
            raise RuntimeError(f"APKINDEX missing in {repo}")
        text = raw.read().decode("utf-8", "replace")
    for chunk in text.split("\n\n"):
        fields = {}
        for line in chunk.splitlines():
            if len(line) > 2 and line[1] == ":":
                fields.setdefault(line[0], []).append(line[2:])
        if "P" in fields and "V" in fields:
            records.append({
                "repo": repo,
                "name": fields["P"][0],
                "version": fields["V"][0],
                "deps": fields.get("D", [""])[0].split(),
                "provides": fields.get("p", [""])[0].split(),
            })

for repo in repos:
    parse_index(repo)

by_name = {}
providers = {}
for record in records:
    by_name.setdefault(record["name"], record)
    for provided in record["provides"]:
        key = re.split(r"[<>=~!]", provided, maxsplit=1)[0]
        providers.setdefault(key, record)

# Prefer the package with the exact name. For virtual dependencies (so:/cmd:/pc:)
# resolve the provider advertised by APKINDEX.
def resolve(token):
    token = token.rstrip("?")
    base = re.split(r"[<>=~!]", token, maxsplit=1)[0]
    if base in by_name:
        return by_name[base]
    if base in providers:
        return providers[base]
    return None

wanted = deque(["radare2"])
selected = {}
while wanted:
    token = wanted.popleft()
    record = resolve(token)
    if record is None:
        # Base rootfs packages can satisfy a few virtual libc/proc dependencies.
        if token.startswith(("so:", "cmd:", "pc:")):
            continue
        raise RuntimeError(f"Unable to resolve Alpine dependency: {token}")
    key = (record["repo"], record["name"], record["version"])
    if key in selected:
        continue
    selected[key] = record
    wanted.extend(record["deps"])


def safe_member(name):
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts

for record in selected.values():
    filename = f"{record['name']}-{record['version']}.apk"
    destination = os.path.join(apk_dir, filename)
    url = f"{mirror}/v{version}/{record['repo']}/{arch}/{filename}"
    fetch(url, destination)
    # APK is an outer tar.gz containing data.tar.gz; only the data archive
    # belongs in the guest filesystem.
    with tarfile.open(destination, "r:gz") as outer:
        data_member = outer.extractfile("data.tar.gz")
        if data_member is None:
            raise RuntimeError(f"data.tar.gz missing in {filename}")
        payload = io.BytesIO(data_member.read())
    with tarfile.open(fileobj=payload, mode="r:gz") as archive:
        members = [m for m in archive.getmembers() if safe_member(m.name)]
        archive.extractall(stage, members=members)

marker = os.path.join(stage, "opt", "minis-reverse-tools", "manifest.json")
os.makedirs(os.path.dirname(marker), exist_ok=True)
with open(marker, "w", encoding="utf-8") as handle:
    json.dump({
        "engine": "radare2",
        "version": next(iter(selected.values()))["version"],
        "architecture": arch,
        "source": "Alpine package embedded at iOS build time",
        "runtimeDownload": False,
        "decompiler": "pdc",
        "packages": sorted(f"{r['name']}={r['version']}" for r in selected.values()),
    }, handle, ensure_ascii=False, indent=2)

print(f"embedded radare2 and {len(selected) - 1} dependencies")
PY

# Verify the expected guest executable and marker exist before fakefsify.
test -x "$STAGE_DIR/usr/bin/r2"
test -s "$STAGE_DIR/opt/minis-reverse-tools/manifest.json"
echo "embedded reverse engine: $STAGE_DIR/usr/bin/r2"
