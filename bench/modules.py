#!/usr/bin/env python3
"""The benchmark estate's modules.

    modules.py select <count>        print the <count> most-downloaded Forge modules
    modules.py fetch <list> <pool>   download the modules in <list> into <pool>

`select` prints one "owner-name version" per line, for modules.txt. It skips
deprecated modules, the generated Windows DSC modules, releases over 8 MB, and a
second module with a name already taken. `fetch` unpacks each release into
<pool>/<name>, as r10k deploys modules, and keeps releases already there.
"""
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://forgeapi.puppet.com"
HEADERS = {"User-Agent": "ovlens-bench"}


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as response:
        return response.read()


def select(count):
    chosen = {}
    offset = 0
    while len(chosen) < count and offset < 2000:
        page = json.loads(get(f"{API}/v3/modules?sort_by=downloads&limit=100&offset={offset}&hide_deprecated=true"))
        for module in page["results"]:
            release = module.get("current_release") or {}
            name = module["name"]
            if module["owner"]["slug"] == "dsc" or name.startswith("dsc") or name in chosen:
                continue
            if not release.get("file_uri") or (release.get("file_size") or 0) > 8_000_000:
                continue
            chosen[name] = f'{module["slug"]} {release["version"]}'
            if len(chosen) >= count:
                break
        offset += 100
    for line in chosen.values():
        print(line)


def unpack(data, dest):
    """Unpacks a release tarball and moves the directory holding metadata.json
    to dest. Some releases put their files under ".", not under a named root."""
    with tempfile.TemporaryDirectory(dir=os.path.dirname(dest)) as work:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            tar.extractall(work, filter="data")
        roots = [root for root, _, files in os.walk(work) if "metadata.json" in files]
        if not roots:
            raise RuntimeError("no metadata.json in the release")
        shutil.move(min(roots, key=len), dest)


def fetch(listing, pool):
    os.makedirs(pool, exist_ok=True)
    wanted = [line.split() for line in open(listing) if line.strip() and not line.startswith("#")]

    def one(item):
        slug, version = item
        name = slug.split("-", 1)[1]
        dest = os.path.join(pool, name)
        if os.path.isdir(dest):
            return None
        try:
            unpack(get(f"{API}/v3/files/{slug}-{version}.tar.gz"), dest)
            return None
        except Exception as error:  # report every failure at the end
            return f"{slug} {version}: {type(error).__name__}: {error}"

    with ThreadPoolExecutor(8) as pool_executor:
        failures = [f for f in pool_executor.map(one, wanted) if f]
    print(f"{len(wanted) - len(failures)} of {len(wanted)} modules in {pool}")
    for failure in failures:
        print("  failed:", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["select"] and len(sys.argv) == 3:
        select(int(sys.argv[2]))
    elif sys.argv[1:2] == ["fetch"] and len(sys.argv) == 4:
        sys.exit(fetch(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)
