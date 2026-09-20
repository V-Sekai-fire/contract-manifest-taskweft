# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Preflight: every checkout in this workspace is in a state `repo sync` can advance.

WHY THIS EXISTS. `repo sync` is not idempotent against a dirty client. It walks 148
projects, and one of them in the wrong state stops the walk for all of them - which is
expensive twice over, because the projects that did sync are now at a different revision
from the ones that did not, and the next run starts from that mixture.

Three states have stopped a sync in this workspace, and this gate enumerates all three
rather than the one that stopped it most recently:

  A FEATURE BRANCH LEFT CHECKED OUT. `repo` leaves a project detached at the manifest
  revision. A branch checked out on top of that is work `repo sync` tries to carry
  forward, so it starts a rebase onto the new revision - and a rebase that conflicts
  leaves the project mid-rebase, where the next sync refuses to start at all with
  `prior sync failed; rebase still in progress`. This happened twice on
  `4-entities/godot`, which the manifest pins at a tag while three feature branches
  live in the same checkout.

  A PLAIN GIT REPOSITORY AT A MANIFEST PATH. A project created with `git init` at a
  path the manifest places has no entry under `.repo/projects`, and `repo` reports
  `unsupported checkout state` rather than adopting it. This happened to `.beads` and
  to `2-contract/pixel-stream`, both of which were made locally before they were
  placed.

  A MERGE OR REBASE ALREADY IN PROGRESS. The residue of a previous failure. It reads
  as the first state above to anybody skimming, and it is not: no branch is checked
  out, and the fix is `git rebase --abort` rather than a checkout.

WHAT IT DOES NOT DO. It does not sync, checkout, abort, or stash anything. A preflight
that repaired the workspace would be a preflight nobody read the output of, and the
repair for the first state is a judgement call - the branch is either pushed and
disposable or it is the only copy of the work. So the gate reports and the operator
decides.

UNPUSHED WORK IS REPORTED SEPARATELY, because it changes what the operator should do
rather than whether the sync will stop. A branch whose commits are all on the remote can
be parked with `git checkout --detach` and lose nothing; one carrying commits the remote
has never seen cannot.

DETECTION FLOOR. None. The population is every project element in `default.xml`, a fixed
list of 148, so it is enumerated rather than sampled. A project the manifest names and
the disk does not carry is counted and named: `repo sync` clones it, so it is not a
failure, but a run that printed nothing about it would be indistinguishable from one
that checked it.

Run:  python check_sync_preflight.py <workspace> [--manifest PATH] [--self-test]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

DEFAULT_MANIFEST = os.path.join(".repo", "manifests", "default.xml")


def git(repo, *args):
    p = subprocess.run(("git", "-C", repo) + args, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def projects(manifest):
    root = ET.parse(manifest).getroot()
    return [(p.get("path") or p.get("name"), p.get("revision") or "")
            for p in root.iter("project")]


def pinned_branch(revision):
    """The local branch a checkout may legitimately sit on, or None when the manifest
    pins a tag or a bare SHA and only a detached HEAD is legitimate."""
    if revision.startswith("refs/tags/") or revision.startswith("refs/changes/"):
        return None
    if revision.startswith("refs/heads/"):
        return revision[len("refs/heads/"):]
    if len(revision) in (40, 64) and all(c in "0123456789abcdef" for c in revision):
        return None
    return revision


def inspect(root, path, revision):
    """One project's state, as (verdict, detail); verdict is ok, FAIL or absent."""
    full = os.path.join(root, path)
    if not os.path.isdir(full):
        return "absent", "not on disk; repo sync will clone it"
    gitdir = os.path.join(full, ".git")
    if not os.path.exists(gitdir):
        return "FAIL", "a manifest path that is not a git checkout"

    if os.path.isdir(os.path.join(root, ".repo")) and \
       not os.path.exists(os.path.join(root, ".repo", "projects", path + ".git")):
        return "FAIL", ("a plain git repository repo does not manage; "
                        "move it aside and let repo sync clone it")

    for residue, fix in (("rebase-merge", "git rebase --abort"),
                         ("rebase-apply", "git rebase --abort"),
                         ("MERGE_HEAD", "git merge --abort"),
                         ("CHERRY_PICK_HEAD", "git cherry-pick --abort")):
        if os.path.exists(os.path.join(gitdir, residue)):
            return "FAIL", "a %s left in progress; %s" % (residue, fix)

    rc, branch, _ = git(full, "symbolic-ref", "--short", "-q", "HEAD")
    if rc != 0:
        return "ok", "detached, as repo leaves it"
    if branch == pinned_branch(revision):
        return "ok", "on %s, which the manifest pins" % branch

    rc, ahead, _ = git(full, "rev-list", "--count", "@{upstream}..HEAD")
    if rc != 0:
        state = "no upstream, so every commit on it is unpushed"
    elif ahead != "0":
        state = "%s commit(s) the remote has not seen" % ahead
    else:
        state = "fully pushed"
    _, dirty, _ = git(full, "status", "--porcelain")
    if dirty:
        state += ", %d uncommitted path(s)" % len(dirty.splitlines())
    return "FAIL", ("on branch %s, which the manifest does not pin (%s) - %s"
                    % (branch, revision or "no revision", state))


def check(root, manifest, verbose=True):
    rows = []
    for path, revision in projects(manifest):
        verdict, detail = inspect(root, path, revision)
        rows.append((path, verdict, detail))
        if verbose and verdict != "ok":
            print("  %-6s %-42s %s" % (verdict, path, detail))
    return rows


def _rmtree(path):
    # git marks loose objects read-only, which blocks unlink on Windows.
    def clear(func, target, _exc):
        os.chmod(target, 0o700)
        func(target)
    shutil.rmtree(path, onexc=clear)


def _seed(repo):
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "t@t")
    git(repo, "config", "user.name", "t")
    with open(os.path.join(repo, "f"), "w") as fh:
        fh.write("x")
    git(repo, "add", "f")
    git(repo, "commit", "-qm", "c")


def self_test():
    print()
    print("check_sync_preflight.py self-test")

    def fixture(tmp, revision="refs/tags/v1"):
        os.makedirs(os.path.join(tmp, ".repo", "projects", "proj.git"))
        manifest = os.path.join(tmp, "default.xml")
        with open(manifest, "w") as fh:
            fh.write('<manifest><project name="proj" path="proj" revision="%s" />'
                     "</manifest>\n" % revision)
        repo = os.path.join(tmp, "proj")
        os.makedirs(repo)
        _seed(repo)
        git(repo, "tag", "v1")
        git(repo, "checkout", "-q", "--detach", "v1")
        return manifest, repo

    def on_a_branch(tmp, repo):
        git(repo, "checkout", "-q", "-b", "feat/x")

    def unmanaged(tmp, repo):
        shutil.rmtree(os.path.join(tmp, ".repo", "projects", "proj.git"))

    def mid_rebase(tmp, repo):
        os.makedirs(os.path.join(repo, ".git", "rebase-merge"))

    def mid_merge(tmp, repo):
        with open(os.path.join(repo, ".git", "MERGE_HEAD"), "w") as fh:
            fh.write("deadbeef\n")

    def not_a_checkout(tmp, repo):
        _rmtree(os.path.join(repo, ".git"))

    def gone(tmp, repo):
        _rmtree(repo)

    positives = [
        ("a detached checkout at the pinned tag", "refs/tags/v1", None),
        ("a checkout on the branch the manifest pins", "topic", "topic"),
    ]
    bad = 0
    for name, revision, branch in positives:
        tmp = tempfile.mkdtemp()
        try:
            manifest, repo = fixture(tmp, revision)
            if branch:
                git(repo, "checkout", "-q", "-b", branch)
            clean = all(v == "ok" for _, v, _ in check(tmp, manifest, verbose=False))
            print("  %-4s positive control: %s passes"
                  % ("ok" if clean else "FAIL", name))
            if not clean:
                print("       the gate rejects a correct tree; "
                      "the controls below prove nothing.")
                return 1
        finally:
            _rmtree(tmp)

    negatives = [
        ("a feature branch left checked out", on_a_branch, "FAIL"),
        ("a plain git repository at a manifest path", unmanaged, "FAIL"),
        ("a rebase left in progress", mid_rebase, "FAIL"),
        ("a merge left in progress", mid_merge, "FAIL"),
        ("a manifest path that is not a checkout", not_a_checkout, "FAIL"),
        ("a project the disk does not carry is counted, not skipped", gone, "absent"),
    ]
    for name, mutate, want in negatives:
        tmp = tempfile.mkdtemp()
        try:
            manifest, repo = fixture(tmp)
            mutate(tmp, repo)
            caught = any(v == want for _, v, _ in check(tmp, manifest, verbose=False))
            print("  %-4s negative control: %s" % ("ok" if caught else "FAIL", name))
            if not caught:
                bad += 1
        finally:
            _rmtree(tmp)

    if bad:
        print("       %d mode(s) the gate claims to catch and does not." % bad)
        return 1
    print("  %d of %d rejected." % (len(negatives), len(negatives)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workspace", nargs="?", default=None,
                    help="the repo client root; omit with --self-test")
    ap.add_argument("--manifest", default=None,
                    help="default: <workspace>/%s" % DEFAULT_MANIFEST)
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate rejects each state that has stopped a sync")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if args.workspace is None:
        ap.error("a workspace is required unless --self-test is given")

    root = os.path.abspath(args.workspace)
    manifest = args.manifest or os.path.join(root, DEFAULT_MANIFEST)
    if not os.path.exists(manifest):
        print("no manifest at %s" % manifest)
        return 1

    print()
    rows = check(root, manifest)
    failures = [r for r in rows if r[1] == "FAIL"]
    absent = [r for r in rows if r[1] == "absent"]

    print()
    print("%d project(s) enumerated, %d absent from disk, %d unchecked."
          % (len(rows), len(absent), 0))
    if failures:
        print("%d project(s) would stop `repo sync`." % len(failures))
        return 1
    print("Every project on disk is in a state `repo sync` can advance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
