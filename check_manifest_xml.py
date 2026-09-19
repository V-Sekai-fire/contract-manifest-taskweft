# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Gate: `default.xml` parses, and every revision names a ref `repo` can actually fetch.

WHY THIS EXISTS. A `default.xml` that does not sync stops every checkout in the workspace
rather than the one row that is wrong, so the file is worth checking before it is pushed
and not after somebody's `repo sync` fails.

Two failures are caught, and the second is the one that cost something.

IT PARSES. A malformed file fails every `repo` command at once, and the error names an XML
parser rather than the edit that caused it.

AND EVERY REVISION IS THE SHAPE REPO FETCHES. `repo` reads a bare revision as a branch and
fetches `refs/heads/<revision>`. So a tag pinned by its own name looks right, reviews fine,
and fails at sync:

    fatal: couldn't find remote ref refs/heads/v2026.09.19.0820-main-fabric-0.2.4

A tag has to be written `refs/tags/<tag>`. That is not visible in the diff — the two forms
differ by a prefix — which is exactly why it belongs in a gate rather than in review.

A revision is accepted in three forms: a 40-character SHA, a `refs/tags/<tag>`, or a branch
name that exists as `refs/heads/<name>` on the remote. Anything else fails, including a
`refs/heads/` that is gone and a `refs/tags/` that was never pushed.

DETECTION FLOOR. None. Every `<project>` element is enumerated rather than sampled, because
the population is fixed and small. A row whose remote cannot be reached is a FAIL and not a
skip: a skip reads exactly like a pass.

Run:  python check_manifest_xml.py [--manifest PATH] [--offline] [--self-test]
"""

import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SHA = re.compile(r"\A[0-9a-f]{40}\Z")


def remotes(root):
    out = {}
    for r in root.findall("remote"):
        name, fetch = r.get("name"), r.get("fetch", "")
        if name:
            out[name] = fetch.rstrip("/")
    return out


def url_for(fetch, project):
    base = fetch if fetch.startswith(("http", "git@", "ssh")) else fetch
    return f"{base.rstrip('/')}/{project}"


def ls_remote(url, ref):
    try:
        done = subprocess.run(
            ["git", "ls-remote", url, ref],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    if done.returncode != 0:
        return None, done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "ls-remote failed"
    return bool(done.stdout.strip()), None


def check(manifest, offline):
    try:
        root = ET.parse(manifest).getroot()
    except ET.ParseError as exc:
        print(f"FAIL {manifest} is not well-formed XML: {exc}")
        return 1

    fetches = remotes(root)
    default = root.find("default")
    default_remote = default.get("remote") if default is not None else None
    default_rev = default.get("revision") if default is not None else None

    checked = failed = 0
    for p in root.findall("project"):
        name = p.get("name")
        rev = p.get("revision", default_rev)
        remote = p.get("remote", default_remote)
        checked += 1

        if not name or not rev or not remote:
            print(f"FAIL {name or '<unnamed>'}: name, revision and remote are all required")
            failed += 1
            continue
        if SHA.match(rev):
            continue
        if remote not in fetches:
            print(f"FAIL {name}: remote {remote!r} is not declared")
            failed += 1
            continue
        if offline:
            continue

        url = url_for(fetches[remote], name)
        ref = rev if rev.startswith("refs/") else f"refs/heads/{rev}"
        found, err = ls_remote(url, ref)
        if err is not None:
            print(f"FAIL {name}: cannot reach {url}: {err}")
            failed += 1
        elif not found:
            hint = ""
            if not rev.startswith("refs/"):
                tag, _ = ls_remote(url, f"refs/tags/{rev}")
                if tag:
                    hint = f" — it is a tag, so write revision=\"refs/tags/{rev}\""
            print(f"FAIL {name}: {ref} does not exist on {url}{hint}")
            failed += 1

    print(f"checked {checked} projects, {failed} failed")
    return 1 if failed else 0


SELF_TESTS = [
    ("well-formed manifest passes", '<manifest><remote name="r" fetch="https://example.invalid"/>'
     '<default remote="r" revision="main"/><project name="p" revision="0" /></manifest>'
     .replace('revision="0"', 'revision="%s"' % ("a" * 40)), 0),
    ("malformed XML is rejected", "<manifest><project></manifest>", 1),
    ("a project with no revision is rejected",
     '<manifest><remote name="r" fetch="https://example.invalid"/><project name="p"/></manifest>', 1),
    ("an undeclared remote is rejected",
     '<manifest><default revision="main"/><project name="p" remote="nope"/></manifest>', 1),
    ("a sha revision needs no network",
     '<manifest><remote name="r" fetch="https://example.invalid"/>'
     f'<project name="p" remote="r" revision="{"b" * 40}"/></manifest>', 0),
]


def self_test():
    import tempfile, pathlib

    bad = 0
    for label, xml, want in SELF_TESTS:
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "m.xml"
            path.write_text(xml)
            got = check(str(path), offline=True)
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label} (want {want}, got {got})")
        bad += 0 if ok else 1
    print(f"{len(SELF_TESTS) - bad}/{len(SELF_TESTS)} controls passed")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="default.xml")
    ap.add_argument("--offline", action="store_true", help="skip the ls-remote checks")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    return self_test() if args.self_test else check(args.manifest, args.offline)


if __name__ == "__main__":
    sys.exit(main())
