"""Build web/fdroid.json: a trimmed copy of F-Droid's app list that the website can search.

Browsers may not read f-droid.org directly (it sends no CORS header), so the website reads this copy from its own
address instead. Run daily by .github/workflows/fdroid-index.yml.
Each app: [package, name, summary, icon path, [[versionName, versionCode, minSdk, maxSdk or 0, "abi,abi", apk path, sha256, size], ...]]
"""
import json
import sys
import urllib.request

INDEX = "https://f-droid.org/repo/index-v2.json"
KEEP_VERSIONS = 6   # newest few: apps built per processor type ship one APK per type


def en(field):
    """English text of a localized field, else any language."""
    if not isinstance(field, dict):
        return field or ""
    return field.get("en-US") or field.get("en") or next(iter(field.values()), "")


def build(index):
    apps = []
    for pkg, data in index["packages"].items():
        meta, versions = data.get("metadata", {}), []
        for v in sorted(data.get("versions", {}).values(), key=lambda v: -v["manifest"]["versionCode"])[:KEEP_VERSIONS]:
            m, f = v["manifest"], v["file"]
            sdk = m.get("usesSdk", {})
            versions.append([m.get("versionName", ""), m["versionCode"], sdk.get("minSdkVersion", 1), m.get("maxSdkVersion", 0),
                             ",".join(m.get("nativecode", [])), f["name"], f["sha256"], f["size"]])
        if versions:
            icon = en(meta.get("icon"))
            apps.append([pkg, en(meta.get("name")) or pkg, en(meta.get("summary")), icon.get("name", "") if isinstance(icon, dict) else "", versions])
    apps.sort(key=lambda a: a[1].casefold())
    return apps


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "web/fdroid.json"
    with urllib.request.urlopen(INDEX, timeout=300) as r:
        apps = build(json.load(r))
    assert len(apps) > 1000, f"only {len(apps)} apps: refusing to replace the list"   # a broken download must not empty the store
    with open(out, "w") as f:
        json.dump(apps, f, separators=(",", ":"), ensure_ascii=False)
    print(f"{len(apps)} apps written to {out}")
