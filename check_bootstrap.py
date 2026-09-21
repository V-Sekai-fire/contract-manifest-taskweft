# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Gate: the bootstrap pins, the two installers and the workspace's declared platforms all
say the same thing.

WHY THIS EXISTS. Bootstrapping is the step that cannot be done by the tools it installs, so
the pins live in a text table rather than in a lockfile. A table is a second place, and a
second place drifts: an installer grows an architecture arm whose row was never added, a
release is re-pinned and the checksum copied from the wrong line, or a project declares
`osx-arm64` in its `pixi.toml` while nothing here can install pixi on it. None of those is
visible until somebody is standing at a bare machine.

ORDER, AND THE ONE LINK NO PIN COVERS. `repo` comes first and `pixi` second, because the
pins live inside the manifest repository and only `repo init` puts that on disk. So the
launcher that performed the first fetch was itself unpinned; `install.sh` re-fetches it at
the pinned version, verifies it, and says so when the launcher already on PATH differs.
Moving pixi first would not close the circle, only relocate it.

Five pairs are walked, each enumerated rather than sampled -- every population here is a
handful of lines in files this repository owns.

  1. every architecture arm in an installer resolves to a pixi row
  2. every pixi row is reachable from at least one installer arm
  3. every platform any workspace `pixi.toml` declares has a pixi row
  4. every pinned pixi checksum matches what the release publishes
  5. the pinned repo launcher matches what its source serves
  6. every script the readme's one-step command names exists here
  7. the pinned llvm-mingw is the release the engine's Windows CI job installs

The last two need the network. They are not skipped when it is absent, because a silent skip
reads exactly like a pass; `--offline` drops them and still exits non-zero, naming them.

Run:  python check_bootstrap.py [--workspace DIR] [--offline] [--self-test]
"""

import argparse
import hashlib
import pathlib
import sys
import xml.etree.ElementTree as ET
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
WORKSPACE = HERE.parent.parent  # .repo/manifests -> .repo -> the repo client root


def read_pins(text):
    """`<tool> <key> <value...>` lines; pixi platform rows keyed by platform name."""
    scalars, rows = {}, {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        if parts[0] == "pixi" and parts[1] == "platform" and len(parts) == 6:
            rows[parts[2]] = {"asset": parts[3], "sha256": parts[4], "member": parts[5]}
        else:
            scalars[(parts[0], parts[1])] = parts[2]
    return scalars, rows


def sh_arms(text):
    """Platform names the POSIX installer can select, from its `want=NAME` assignments."""
    out = set()
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("want=") or ") want=" in stripped:
            token = stripped.split("want=", 1)[1].split()[0]
            if token and token[0].isalpha():
                out.add(token.rstrip(";"))
    return out


def ps_arms(text):
    """Platform names the PowerShell installer can select, from its `'ARCH' { 'NAME' }` arms."""
    out = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("'") or "{ '" not in stripped:
            continue
        name = stripped.split("{ '", 1)[1].split("'", 1)[0]
        if name:
            out.add(name)
    return out


def declared_platforms(workspace):
    """Every platform named in a `platforms = [...]` line of a workspace pixi.toml."""
    out = {}
    for toml in sorted(pathlib.Path(workspace).glob("*/*/pixi.toml")):
        if ".pixi" in toml.parts:
            continue
        for line in toml.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line.startswith("platforms"):
                continue
            inner = line.split("[", 1)[-1].split("]", 1)[0]
            for name in inner.split(","):
                name = name.strip().strip('"').strip("'")
                if name:
                    out.setdefault(name, []).append(str(toml.relative_to(workspace)))
    return out


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def readme_scripts(readme_text):
    """Every bootstrap script the readme's one-step commands name, in the order they appear."""
    out = []
    for line in readme_text.splitlines():
        for token in line.replace("`", " ").split():
            name = token.rsplit("/", 1)[-1]
            if name.startswith("bootstrap.") and name not in out:
                out.append(name)
    return out


def ci_llvm_mingw(workspace, manifest=None):
    """The llvm-mingw release the engine's Windows CI installs, or None if unreadable.

    The engine's checkout path comes from the manifest rather than being spelled here, so
    moving the project cannot silently turn this check into a skip.
    """
    manifest = manifest or (HERE / "default.xml")
    try:
        tree = ET.parse(manifest)
    except Exception:
        return None
    path = None
    for project in tree.getroot().iter("project"):
        if project.get("name") == "entities-godot":
            path = project.get("path")
    if not path:
        return None
    workflow = pathlib.Path(workspace) / path / ".github" / "workflows" / "windows_builds.yml"
    if not workflow.is_file():
        return None
    for line in workflow.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("ver=") and stripped[4:].isdigit():
            return stripped[4:]
    return None


def check(pins_text, sh_text, ps_text, workspace, offline, readme_text=None):
    scalars, rows = read_pins(pins_text)
    failures, counts = [], {}

    for key in [("pixi", "version"), ("pixi", "source"), ("pixi", "checksums"),
                ("repo", "version"), ("repo", "source"), ("repo", "sha256")]:
        if key not in scalars:
            failures.append(f"FAIL bootstrap-pins.txt names no {key[0]} {key[1]}")
    if failures or not rows:
        return failures or ["FAIL bootstrap-pins.txt pins no pixi platform"], counts

    arms = sh_arms(sh_text) | ps_arms(ps_text)
    counts["installer arms"] = len(arms)
    for arm in sorted(arms):
        if arm not in rows:
            failures.append(f"FAIL an installer selects {arm}, which has no pixi row")

    counts["pinned pixi rows"] = len(rows)
    for name in sorted(rows):
        if name not in arms:
            failures.append(f"FAIL bootstrap-pins.txt pins {name}, which no installer can select")

    counts["llvm-mingw pin checked against the engine's CI"] = 0
    if workspace:
        ci = ci_llvm_mingw(workspace)
        if ci is None:
            failures.append("FAIL could not read the llvm-mingw version out of the engine's windows_builds.yml")
        else:
            counts["llvm-mingw pin checked against the engine's CI"] = 1
            pinned = scalars.get(("llvm-mingw", "version"))
            if pinned != ci:
                failures.append(
                    f"FAIL llvm-mingw: pinned {pinned}, the engine's Windows CI installs {ci}"
                )

    declared = declared_platforms(workspace) if workspace else {}
    counts["platforms declared by workspace pixi.toml"] = len(declared)
    for name, users in sorted(declared.items()):
        if name not in rows:
            failures.append(f"FAIL {users[0]} declares {name}, which pixi cannot be bootstrapped on")

    if readme_text is not None:
        named = readme_scripts(readme_text)
        counts["bootstrap scripts named by the readme"] = len(named)
        if not named:
            failures.append("FAIL the readme names no bootstrap script, so it is not one step")
        for name in named:
            if not (HERE / name).is_file():
                failures.append(f"FAIL the readme's one-step command names {name}, which is not here")

    if offline:
        counts["pixi checksums verified against the release"] = 0
        counts["repo launcher verified against its source"] = 0
        failures.append("FAIL --offline: the published checksums were not read, which is not a pass")
        return failures, counts

    try:
        body = fetch(scalars[("pixi", "checksums")]).decode("utf-8")
    except Exception as exc:
        failures.append(f"FAIL could not read the pixi checksums: {exc}")
    else:
        upstream = {p[1]: p[0] for p in (l.split() for l in body.splitlines()) if len(p) == 2}
        counts["pixi checksums verified against the release"] = len(rows)
        for name, row in sorted(rows.items()):
            want = upstream.get(row["asset"])
            if want is None:
                failures.append(f"FAIL {row['asset']} is not in the release's sha256.sum")
            elif want != row["sha256"]:
                failures.append(f"FAIL {name}: pinned {row['sha256'][:12]}, published {want[:12]}")

    try:
        launcher = fetch(scalars[("repo", "source")])
    except Exception as exc:
        failures.append(f"FAIL could not read the repo launcher: {exc}")
    else:
        counts["repo launcher verified against its source"] = 1
        got = hashlib.sha256(launcher).hexdigest()
        if got != scalars[("repo", "sha256")]:
            failures.append(
                f"FAIL repo launcher {scalars[('repo', 'version')]}: "
                f"pinned {scalars[('repo', 'sha256')][:12]}, served {got[:12]}"
            )

    return failures, counts


def self_test():
    pins = (HERE / "bootstrap-pins.txt").read_text(encoding="utf-8")
    sh = (HERE / "install.sh").read_text(encoding="utf-8")
    ps = (HERE / "install.ps1").read_text(encoding="utf-8")
    readme = (HERE / "readme.md").read_text(encoding="utf-8")
    # The checksums to corrupt are read out of the pins rather than written
    # here. A control keyed to a literal stops corrupting anything the moment
    # the pin it names is bumped, and a control that mutates nothing tests
    # nothing - which is what a pixi bump to 0.81.0 did to the two below.
    def corrupt(text, prefix, col):
        """Flip one hex digit of the checksum in column col of the first row
        starting with prefix. The column is named rather than counted from the
        end, because the two row shapes put the checksum in different places
        and picking the wrong field corrupts a keyword instead - which fails
        the check too, so the control would pass while testing nothing."""
        out, done = [], False
        for line in text.splitlines(keepends=True):
            f = line.split()
            if not done and f[:len(prefix)] == prefix:
                sha = f[col]
                assert len(sha) == 64 and all(c in "0123456789abcdef" for c in sha),                     f"column {col} of {prefix} is {sha!r}, not a checksum"
                i = line.index(sha)
                line = line[:i] + ("0" if sha[0] != "0" else "1") + line[i + 1:]
                done = True
            out.append(line)
        assert done, f"no {prefix} row to corrupt; the control would test nothing"
        return "".join(out)

    controls = [
        ("a wrong pixi checksum is rejected",
         corrupt(pins, ["pixi", "platform"], 4), False),
        ("a wrong repo launcher checksum is rejected",
         corrupt(pins, ["repo", "sha256"], 2), False),
        (
            "an installer arm with no row is rejected",
            "\n".join(l for l in pins.splitlines() if not l.startswith("pixi platform osx-64")),
            True,
        ),
        (
            "a row no installer selects is rejected",
            pins + "pixi platform aix-64 pixi-aix.tar.gz " + "0" * 64 + " pixi\n",
            True,
        ),
        ("a missing repo pin is rejected",
         "\n".join(l for l in pins.splitlines() if not l.startswith("repo source")), True),
        ("--offline is not a pass", pins, True),
    ]
    readme_controls = [
        ("a readme naming a script that is not here is rejected",
         readme.replace("bootstrap.sh", "bootstrap.zsh")),
        ("a readme naming no bootstrap script is rejected",
         readme.replace("bootstrap.sh", "x").replace("bootstrap.ps1", "y")),
    ]
    bad = 0
    for name, text, offline in controls:
        failures, _ = check(text, sh, ps, None, offline)
        if failures:
            print(f"  ok: {name}")
        else:
            bad += 1
            print(f"  CONTROL DID NOT FIRE: {name}")
    for name, text in readme_controls:
        failures, _ = check(pins, sh, ps, None, True, text)
        readme_failed = any("readme" in f for f in failures)
        if readme_failed:
            print(f"  ok: {name}")
        else:
            bad += 1
            print(f"  CONTROL DID NOT FIRE: {name}")
    failures, _ = check(pins, sh, ps, None, False, readme)
    if failures:
        bad += 1
        print("  CONTROL DID NOT FIRE: the shipped pins pass")
        for f in failures:
            print(f"    {f}")
    else:
        print("  ok: the shipped pins pass")
    return 1 if bad else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", default=str(WORKSPACE))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    workspace = args.workspace if pathlib.Path(args.workspace).is_dir() else None
    failures, counts = check(
        (HERE / "bootstrap-pins.txt").read_text(encoding="utf-8"),
        (HERE / "install.sh").read_text(encoding="utf-8"),
        (HERE / "install.ps1").read_text(encoding="utf-8"),
        workspace,
        args.offline,
        (HERE / "readme.md").read_text(encoding="utf-8"),
    )
    if workspace is None:
        print(f"  note: {args.workspace} is not a directory, so no pixi.toml was read")
    for label, n in counts.items():
        print(f"  {n:>3}  {label}")
    for f in failures:
        print(f"  {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
