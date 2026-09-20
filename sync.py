# SPDX-License-Identifier: Apache-2.0 OR MIT
"""One step: preflight, park what is safe to park, protect the beads database,
`repo sync`, verify.

WHY THIS EXISTS. A correct sync in this workspace was five commands, and the
order mattered. Run them out of order and the failure is silent in both
directions: sync before the preflight and `repo` starts a rebase it cannot
finish, sync before the backup and the beads Dolt database is gone with no
message. Five commands that must be run in one order is one command that
nobody wrote yet.

WHAT IT PARKS, AND WHAT IT REFUSES TO. `check_sync_preflight.py` repairs
nothing on purpose, because parking a branch is destructive when the branch
is the only copy of the work. This script keeps that distinction rather than
dropping it: a branch whose commits are all on its upstream is detached to the
manifest revision and deleted, and a branch carrying anything the remote has
not seen stops the run with the branch named. Rebase residue and unmanaged
checkouts stop the run too - both need a judgement this script does not have.

THE BEADS DATABASE IS COPIED FIRST. `.beads/embeddeddolt` is gitignored, so
`repo sync` has re-cloned it away before. The copy is taken before the sync
and restored only if the directory is missing or empty afterwards, so a sync
that leaves it alone changes nothing.

VERIFICATION IS PART OF THE RUN, not a thing to remember afterwards. The issue
count is read before and after and both are printed, because a restore that
silently produced an empty database would otherwise read as a success.

Run:  python .repo/manifests/sync.py [--dry-run] [--self-test]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_sync_preflight as pre  # noqa: E402

BEADS_DB = os.path.join(".beads", "embeddeddolt")


def resolve(name):
    """`repo` ships as an extensionless Python script, which CreateProcess on
    Windows cannot launch; run it under this interpreter when that is what it is."""
    found = shutil.which(name)
    if found and os.path.splitext(found)[1]:
        return [found]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return [sys.executable, p]
    return [name]


def run(args, cwd=None, capture=True):
    return subprocess.run(args, cwd=cwd, text=True,
                          capture_output=capture, stdin=subprocess.DEVNULL)


def issue_count(root):
    """Open issues beads reports, or None when beads cannot be asked."""
    p = run(resolve("bd") + ["list", "--status", "open", "--json"], cwd=root)
    if p.returncode != 0:
        return None
    try:
        import json
        return len(json.loads(p.stdout))
    except Exception:
        return None


def park(root, path, revision, detail):
    """Detach a fully-pushed branch onto the manifest revision, or explain."""
    full = os.path.join(root, path)
    if "fully pushed" not in detail:
        return False, detail
    rc, branch, _ = pre.git(full, "symbolic-ref", "--short", "-q", "HEAD")
    if rc != 0:
        return False, "HEAD moved while parking"
    rc, _, err = pre.git(full, "checkout", "--detach", "@{upstream}")
    if rc != 0:
        return False, "detach failed: %s" % err.strip()[:120]
    pre.git(full, "branch", "-D", branch)
    return True, "parked %s, which was fully pushed" % branch


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workspace", nargs="?", default=".")
    ap.add_argument("--dry-run", action="store_true",
                    help="preflight and report; park nothing and do not sync")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    root = os.path.abspath(args.workspace)
    manifest = os.path.join(root, pre.DEFAULT_MANIFEST)
    if not os.path.exists(manifest):
        print("no manifest at %s" % manifest)
        return 1
    revisions = dict(pre.projects(manifest))

    print("\n== preflight")
    rows = pre.check(root, manifest, verbose=False)
    blocked, parked = [], []
    for path, verdict, detail in rows:
        if verdict != "FAIL":
            continue
        if args.dry_run or "on branch " not in detail:
            blocked.append((path, detail))
            continue
        ok, why = park(root, path, revisions.get(path, ""), detail)
        (parked if ok else blocked).append((path, why))

    for path, why in parked:
        print("  parked %-42s %s" % (path, why))
    for path, why in blocked:
        print("  STOP   %-42s %s" % (path, why))
    print("  %d project(s) enumerated, %d parked, %d blocking, 0 unchecked."
          % (len(rows), len(parked), len(blocked)))
    if blocked:
        print("\nNothing was synced. Each line above needs a decision this "
              "script does not have:\nunpushed work to push or discard, "
              "rebase residue to abort, a checkout repo does not manage.")
        return 1
    if args.dry_run:
        print("\nDry run: nothing parked, nothing synced.")
        return 0

    print("\n== beads")
    before = issue_count(root)
    db = os.path.join(root, BEADS_DB)
    backup = None
    if os.path.isdir(db):
        backup = tempfile.mkdtemp(prefix="beads-")
        shutil.copytree(db, os.path.join(backup, "embeddeddolt"))
        print("  %s open issue(s), database copied aside" %
              ("unknown" if before is None else before))
    else:
        print("  no database at %s; nothing to protect" % BEADS_DB)

    print("\n== repo sync")
    rc = run(resolve("repo") + ["sync"], cwd=root, capture=False).returncode

    restored = False
    if backup:
        empty = not os.path.isdir(db) or not os.listdir(db)
        if empty:
            shutil.rmtree(db, ignore_errors=True)
            shutil.copytree(os.path.join(backup, "embeddeddolt"), db)
            restored = True
        shutil.rmtree(backup, ignore_errors=True)

    print("\n== verify")
    after = issue_count(root)
    print("  beads: %s open before, %s after%s"
          % (before, after, ", restored from the copy" if restored else ""))
    rows = pre.check(root, manifest, verbose=False)
    left = [r for r in rows if r[1] == "FAIL"]
    print("  %d project(s) enumerated, %d still blocking." % (len(rows), len(left)))
    if rc != 0:
        print("\nrepo sync failed; the beads database is intact.")
        return 1
    if before is not None and after != before:
        print("\nThe issue count changed across the sync. Read it before "
              "trusting the database.")
        return 1
    if left:
        return 1
    print("\nSynced.")
    return 0


def self_test():
    print("\nsync.py self-test")

    def fixture(tmp, pushed):
        """A client with one tag-pinned project sitting on a feature branch."""
        os.makedirs(os.path.join(tmp, ".repo", "projects", "proj.git"))
        os.makedirs(os.path.join(tmp, ".repo", "manifests"))
        manifest = os.path.join(tmp, ".repo", "manifests", "default.xml")
        with open(manifest, "w") as fh:
            fh.write('<manifest><project name="proj" path="proj" '
                     'revision="refs/tags/v1" /></manifest>\n')
        origin = os.path.join(tmp, "origin")
        os.makedirs(origin)
        pre._seed(origin)
        pre.git(origin, "tag", "v1")
        repo = os.path.join(tmp, "proj")
        pre.git(tmp, "clone", "-q", origin, repo)
        # The clone gets its own identity: a runner has no global git user, so a
        # commit made without one fails and the fixture silently becomes the
        # opposite of what it is named.
        pre.git(repo, "config", "user.email", "t@t")
        pre.git(repo, "config", "user.name", "t")
        pre.git(repo, "checkout", "-q", "-b", "feat/x")
        pre.git(repo, "push", "-q", "-u", "origin", "feat/x")
        if not pushed:
            with open(os.path.join(repo, "g"), "w") as fh:
                fh.write("y")
            pre.git(repo, "add", "g")
            rc, _, err = pre.git(repo, "commit", "-qm", "unpushed")
            if rc != 0:
                raise RuntimeError("fixture could not commit: %s" % err[:200])
        return manifest, repo

    bad = 0
    tmp = tempfile.mkdtemp()
    try:
        manifest, repo = fixture(tmp, pushed=True)
        verdict, detail = pre.inspect(tmp, "proj", "refs/tags/v1")
        ok, why = park(tmp, "proj", "refs/tags/v1", detail)
        rc, _, _ = pre.git(repo, "symbolic-ref", "-q", "HEAD")
        print("  %-4s positive control: a fully pushed branch is parked"
              % ("ok" if ok and rc != 0 else "FAIL"))
        if not (ok and rc != 0):
            bad += 1
    finally:
        pre._rmtree(tmp)

    tmp = tempfile.mkdtemp()
    try:
        manifest, repo = fixture(tmp, pushed=False)
        verdict, detail = pre.inspect(tmp, "proj", "refs/tags/v1")
        ok, why = park(tmp, "proj", "refs/tags/v1", detail)
        rc, branch, _ = pre.git(repo, "symbolic-ref", "--short", "-q", "HEAD")
        held = (not ok) and branch == "feat/x"
        print("  %-4s negative control: a branch with unpushed commits is refused"
              % ("ok" if held else "FAIL"))
        if not held:
            bad += 1
    finally:
        pre._rmtree(tmp)

    tmp = tempfile.mkdtemp()
    try:
        manifest, repo = fixture(tmp, pushed=True)
        os.makedirs(os.path.join(repo, ".git", "rebase-merge"))
        verdict, detail = pre.inspect(tmp, "proj", "refs/tags/v1")
        refused = verdict == "FAIL" and "on branch " not in detail
        print("  %-4s negative control: rebase residue is not parked, it stops the run"
              % ("ok" if refused else "FAIL"))
        if not refused:
            bad += 1
    finally:
        pre._rmtree(tmp)

    if bad:
        print("       %d control(s) failed." % bad)
        return 1
    print("  3 of 3.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
