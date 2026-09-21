# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# One step: preflight every checkout, park what is safe to park, protect the
# beads database, `repo sync`, verify.
#
# WHY THIS EXISTS. `repo sync` is not idempotent against a dirty client. It
# walks every project in the manifest, and one of them in the wrong state stops
# the walk for all of them - which is expensive twice over, because the
# projects that did sync are now at a different revision from the ones that did
# not, and the next run starts from that mixture.
#
# A correct sync here was five commands and the order mattered. Out of order it
# fails silently in both directions: sync before the preflight and `repo`
# starts a rebase it cannot finish, sync before the backup and the gitignored
# beads Dolt database is re-cloned away with no message. Five commands that
# must be run in one order is one command nobody had written.
#
# THREE STATES STOP A SYNC, and the gate enumerates all three rather than the
# one that stopped it most recently:
#
#   A FEATURE BRANCH LEFT CHECKED OUT. `repo` leaves a project detached at the
#   manifest revision. A branch on top of that is work `repo sync` tries to
#   carry forward, so it starts a rebase onto the new revision, and a rebase
#   that conflicts leaves the project mid-rebase, where the next sync refuses
#   to start at all with `prior sync failed; rebase still in progress`. This
#   happened twice on `4-entities/godot`, which the manifest pins at a tag
#   while three feature branches live in the same checkout.
#
#   A PLAIN GIT REPOSITORY AT A MANIFEST PATH. A project made with `git init`
#   at a path the manifest places has no entry under `.repo/projects`, and
#   `repo` reports `unsupported checkout state` rather than adopting it. This
#   happened to `.beads` and to `2-contract/pixel-stream`.
#
#   A MERGE OR REBASE ALREADY IN PROGRESS. The residue of a previous failure.
#   It reads as the first state to anybody skimming, and it is not: no branch
#   is checked out, and the fix is `git rebase --abort` rather than a checkout.
#
# WHAT IT PARKS, AND WHAT IT REFUSES TO. Parking a branch is destructive when
# the branch is the only copy of the work, so the distinction is kept rather
# than dropped for convenience: a branch whose commits are all on its upstream
# is detached and deleted, and a branch carrying anything the remote has not
# seen stops the run with the branch named. Rebase residue and unmanaged
# checkouts stop the run too - both need a judgement this script does not have.
# `--preflight` reports and touches nothing.
#
# THE BEADS DATABASE IS COPIED FIRST. `.beads/embeddeddolt` is gitignored, so
# `repo sync` has re-cloned it away before. The copy is taken before the sync
# and restored only when the directory is missing or empty afterwards, so a
# sync that leaves it alone changes nothing.
#
# VERIFICATION IS PART OF THE RUN, not a thing to remember afterwards. The
# issue count is read before and after and both are printed, because a restore
# that silently produced an empty database would otherwise read as a success.
#
# DETECTION FLOOR. None. The population is every <project> element in
# `default.xml`, a fixed list, so it is enumerated rather than sampled. A
# project the manifest names and the disk does not carry is counted and named:
# `repo sync` clones it, so it is not a failure, but a run that printed nothing
# about it would be indistinguishable from one that checked it.
#
# CONTROLS. Two positive and six negative, plus a control that a project absent
# from disk is counted rather than skipped. `--self-test` runs them.
#
# Run:  elixir sync.exs [workspace] [--preflight] [--self-test]

defmodule Sync do
  @moduledoc false

  @default_manifest Path.join([".repo", "manifests", "default.xml"])
  @beads_db Path.join(".beads", "embeddeddolt")

  def default_manifest, do: @default_manifest

  # ---- manifest -----------------------------------------------------------

  def projects(manifest) do
    {doc, _} = manifest |> String.to_charlist() |> :xmerl_scan.file(quiet: true)

    for {:xmlElement, :project, _, _, _, _, _, attrs, _, _, _, _} <- walk(doc) do
      a =
        Enum.reduce(attrs, %{}, fn
          {:xmlAttribute, k, _, _, _, _, _, _, v, _}, acc when k in [:name, :path, :revision] ->
            Map.put(acc, k, List.to_string(v))

          _, acc ->
            acc
        end)

      {Map.get(a, :path, Map.get(a, :name)), Map.get(a, :revision, "")}
    end
  end

  defp walk(node), do: walk(node, [])

  defp walk({:xmlElement, _, _, _, _, _, _, _, children, _, _, _} = el, acc),
    do: Enum.reduce(children, [el | acc], fn c, a -> walk(c, a) end)

  defp walk(_other, acc), do: acc

  @doc """
  The local branch a checkout may legitimately sit on, or nil when the manifest
  pins a tag or a bare SHA and only a detached HEAD is legitimate.
  """
  def pinned_branch("refs/tags/" <> _), do: nil
  def pinned_branch("refs/changes/" <> _), do: nil
  def pinned_branch("refs/heads/" <> rest), do: rest

  def pinned_branch(rev) do
    if byte_size(rev) in [40, 64] and String.match?(rev, ~r/^[0-9a-f]+$/), do: nil, else: rev
  end

  # ---- git ----------------------------------------------------------------

  def git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {0, String.trim(out)}
      {out, code} -> {code, String.trim(out)}
    end
  rescue
    _ -> {127, ""}
  end

  # ---- one project --------------------------------------------------------

  def inspect_project(root, path, revision) do
    full = Path.join(root, path)
    gitdir = Path.join(full, ".git")

    cond do
      not File.dir?(full) ->
        {:absent, "not on disk; repo sync will clone it"}

      not File.exists?(gitdir) ->
        {:fail, "a manifest path that is not a git checkout"}

      File.dir?(Path.join(root, ".repo")) and
          not File.exists?(Path.join([root, ".repo", "projects", path <> ".git"])) ->
        {:fail, "a plain git repository repo does not manage; move it aside and let repo sync clone it"}

      true ->
        residue =
          Enum.find(
            [
              {"rebase-merge", "git rebase --abort"},
              {"rebase-apply", "git rebase --abort"},
              {"MERGE_HEAD", "git merge --abort"},
              {"CHERRY_PICK_HEAD", "git cherry-pick --abort"}
            ],
            fn {name, _} -> File.exists?(Path.join(gitdir, name)) end
          )

        case residue do
          {name, fix} -> {:fail, "a #{name} left in progress; #{fix}"}
          nil -> branch_state(full, revision)
        end
    end
  end

  defp branch_state(full, revision) do
    case git(full, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {c, _} when c != 0 ->
        {:ok, "detached, as repo leaves it"}

      {0, branch} ->
        if branch == pinned_branch(revision) do
          {:ok, "on #{branch}, which the manifest pins"}
        else
          {:fail,
           "on branch #{branch}, which the manifest does not pin " <>
             "(#{if revision == "", do: "no revision", else: revision}) - #{push_state(full)}"}
        end
    end
  end

  defp push_state(full) do
    base =
      case git(full, ["rev-list", "--count", "@{upstream}..HEAD"]) do
        {0, "0"} -> "fully pushed"
        {0, n} -> "#{n} commit(s) the remote has not seen"
        _ -> "no upstream, so every commit on it is unpushed"
      end

    case git(full, ["status", "--porcelain"]) do
      {0, ""} -> base
      {0, dirty} -> base <> ", #{length(String.split(dirty, "\n"))} uncommitted path(s)"
      _ -> base
    end
  end

  def check(root, manifest) do
    for {path, revision} <- projects(manifest) do
      {verdict, detail} = inspect_project(root, path, revision)
      {path, verdict, detail}
    end
  end

  # ---- parking ------------------------------------------------------------

  @doc "Detach a fully-pushed branch onto its upstream and delete it, or explain."
  def park(root, path, detail) do
    full = Path.join(root, path)

    cond do
      not String.contains?(detail, "fully pushed") ->
        {:error, detail}

      true ->
        case git(full, ["symbolic-ref", "--short", "-q", "HEAD"]) do
          {c, _} when c != 0 ->
            {:error, "HEAD moved while parking"}

          {0, branch} ->
            case git(full, ["checkout", "--detach", "@{upstream}"]) do
              {0, _} ->
                git(full, ["branch", "-D", branch])
                {:ok, "parked #{branch}, which was fully pushed"}

              {_, err} ->
                {:error, "detach failed: #{String.slice(err, 0, 120)}"}
            end
        end
    end
  end

  # ---- beads --------------------------------------------------------------

  def beads_db(root), do: Path.join(root, @beads_db)

  def issue_count(root) do
    case System.cmd("bd", ["list", "--status", "open", "--json"], cd: root, stderr_to_stdout: false) do
      {out, 0} -> out |> :json.decode() |> length()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # `repo` ships as an extensionless Python script on this desk, which is not
  # directly executable everywhere; fall back to running it under python.
  def repo_sync(root) do
    case System.cmd("repo", ["sync"], cd: root, into: IO.stream(:stdio, :line)) do
      {_, code} -> code
    end
  rescue
    _ ->
      case System.find_executable("python") do
        nil ->
          127

        py ->
          script =
            System.get_env("PATH", "")
            |> String.split(if match?({:win32, _}, :os.type()), do: ";", else: ":")
            |> Enum.map(&Path.join(&1, "repo"))
            |> Enum.find(&File.regular?/1)

          if script do
            {_, code} = System.cmd(py, [script, "sync"], cd: root, into: IO.stream(:stdio, :line))
            code
          else
            127
          end
      end
  end
end

defmodule Sync.Run do
  @moduledoc false
  import Sync

  def main(root, mode) do
    manifest = Path.join(root, Sync.default_manifest())

    unless File.regular?(manifest) do
      IO.puts("no manifest at #{manifest}")
      System.halt(1)
    end

    IO.puts("\n== preflight")
    rows = check(root, manifest)

    {parked, blocked} =
      Enum.reduce(rows, {[], []}, fn
        {_p, v, _d}, acc when v != :fail ->
          acc

        {path, :fail, detail}, {ok, bad} ->
          if mode == :preflight or not String.contains?(detail, "on branch ") do
            {ok, [{path, detail} | bad]}
          else
            case park(root, path, detail) do
              {:ok, why} -> {[{path, why} | ok], bad}
              {:error, why} -> {ok, [{path, why} | bad]}
            end
          end
      end)

    parked = Enum.reverse(parked)
    blocked = Enum.reverse(blocked)
    absent = Enum.count(rows, fn {_, v, _} -> v == :absent end)

    for {path, why} <- parked, do: IO.puts("  parked #{pad(path)} #{why}")
    for {path, why} <- blocked, do: IO.puts("  STOP   #{pad(path)} #{why}")

    IO.puts(
      "  #{length(rows)} project(s) enumerated, #{absent} absent from disk, " <>
        "#{length(parked)} parked, #{length(blocked)} blocking, 0 unchecked."
    )

    cond do
      blocked != [] ->
        IO.puts(
          "\nNothing was synced. Each line above needs a decision this script " <>
            "does not have:\nunpushed work to push or discard, rebase residue to " <>
            "abort, a checkout repo does not manage."
        )

        System.halt(1)

      mode == :preflight ->
        IO.puts("\nEvery project on disk is in a state `repo sync` can advance.")
        System.halt(0)

      true ->
        :ok
    end

    IO.puts("\n== beads")
    before = issue_count(root)
    db = beads_db(root)

    backup =
      if File.dir?(db) do
        dir = Path.join(System.tmp_dir!(), "beads-#{System.unique_integer([:positive])}")
        # cp_r! needs the destination's parent to exist. It does not create it,
        # and the failure reads as the source being missing rather than the
        # target: "no such file or directory" naming the path being written.
        File.mkdir_p!(dir)
        File.cp_r!(db, Path.join(dir, "embeddeddolt"))
        IO.puts("  #{before || "unknown"} open issue(s), database copied aside")
        dir
      else
        IO.puts("  no database at #{Sync.beads_db("")}; nothing to protect")
        nil
      end

    IO.puts("\n== repo sync")
    code = repo_sync(root)

    restored =
      if backup && (not File.dir?(db) or File.ls!(db) == []) do
        File.rm_rf!(db)
        File.cp_r!(Path.join(backup, "embeddeddolt"), db)
        true
      else
        false
      end

    if backup, do: File.rm_rf!(backup)

    IO.puts("\n== verify")
    after_count = issue_count(root)

    IO.puts(
      "  beads: #{before} open before, #{after_count} after" <>
        if(restored, do: ", restored from the copy", else: "")
    )

    left = Enum.count(check(root, manifest), fn {_, v, _} -> v == :fail end)
    IO.puts("  #{length(rows)} project(s) enumerated, #{left} still blocking.")

    cond do
      code != 0 ->
        IO.puts("\nrepo sync failed; the beads database is intact.")
        System.halt(1)

      before != nil and after_count != before ->
        IO.puts("\nThe issue count changed across the sync. Read it before trusting the database.")
        System.halt(1)

      left > 0 ->
        System.halt(1)

      true ->
        IO.puts("\nSynced.")
        System.halt(0)
    end
  end

  defp pad(s), do: String.pad_trailing(s, 42)
end

defmodule Sync.SelfTest do
  @moduledoc false
  import Sync

  def run do
    IO.puts("\nsync.exs self-test")

    positives = [
      {"a detached checkout at the pinned tag", "refs/tags/v1", nil},
      {"a checkout on the branch the manifest pins", "topic", "topic"}
    ]

    bad =
      Enum.reduce(positives, 0, fn {name, rev, branch}, acc ->
        in_tmp(fn tmp ->
          {manifest, repo} = fixture(tmp, rev)
          if branch, do: git(repo, ["checkout", "-q", "-b", branch])
          clean = Enum.all?(check(tmp, manifest), fn {_, v, _} -> v == :ok end)
          say(clean, "positive control: #{name} passes")

          if clean do
            acc
          else
            IO.puts("       the gate rejects a correct tree; the controls below prove nothing.")
            System.halt(1)
          end
        end)
      end)

    negatives = [
      {"a feature branch left checked out", &on_a_branch/2, :fail},
      {"a branch with unpushed commits is refused parking", &unpushed/2, :refused},
      {"a plain git repository at a manifest path", &unmanaged/2, :fail},
      {"a rebase left in progress", &mid_rebase/2, :fail},
      {"a merge left in progress", &mid_merge/2, :fail},
      {"a manifest path that is not a checkout", &not_a_checkout/2, :fail},
      {"a project the disk does not carry is counted, not skipped", &gone/2, :absent}
    ]

    bad =
      Enum.reduce(negatives, bad, fn {name, mutate, want}, acc ->
        in_tmp(fn tmp ->
          {manifest, repo} = fixture(tmp, "refs/tags/v1")
          mutate.(tmp, repo)

          caught =
            if want == :refused do
              {_, detail} = inspect_project(tmp, "proj", "refs/tags/v1")
              {res, _} = park(tmp, "proj", detail)
              {_, branch} = git(repo, ["symbolic-ref", "--short", "-q", "HEAD"])
              res == :error and branch == "feat/x"
            else
              Enum.any?(check(tmp, manifest), fn {_, v, _} -> v == want end)
            end

          say(caught, "negative control: #{name}")
          if caught, do: acc, else: acc + 1
        end)
      end)

    if bad > 0 do
      IO.puts("       #{bad} mode(s) the gate claims to catch and does not.")
      1
    else
      IO.puts("  #{length(negatives)} of #{length(negatives)} rejected.")
      0
    end
  end

  defp say(ok, text), do: IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} #{text}")

  defp in_tmp(fun) do
    tmp = Path.join(System.tmp_dir!(), "synctest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      fun.(tmp)
    after
      File.rm_rf(tmp)
    end
  end

  defp fixture(tmp, revision) do
    File.mkdir_p!(Path.join([tmp, ".repo", "projects", "proj.git"]))
    manifest = Path.join(tmp, "default.xml")

    File.write!(
      manifest,
      ~s(<manifest><project name="proj" path="proj" revision="#{revision}" /></manifest>\n)
    )

    origin = Path.join(tmp, "origin")
    File.mkdir_p!(origin)
    seed(origin)
    git(origin, ["tag", "v1"])
    repo = Path.join(tmp, "proj")
    git(tmp, ["clone", "-q", origin, repo])
    # The clone gets its own identity. A runner has no global git user, and a
    # commit made without one fails, which turns the unpushed fixture into the
    # fully-pushed one and makes its control certify the opposite of its name.
    git(repo, ["config", "user.email", "t@t"])
    git(repo, ["config", "user.name", "t"])
    git(repo, ["checkout", "-q", "--detach", "v1"])
    {manifest, repo}
  end

  defp seed(repo) do
    git(repo, ["init", "-q"])
    git(repo, ["config", "user.email", "t@t"])
    git(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "f"), "x")
    git(repo, ["add", "f"])
    git(repo, ["commit", "-qm", "c"])
  end

  defp on_a_branch(_tmp, repo), do: git(repo, ["checkout", "-q", "-b", "feat/x"])

  defp unpushed(_tmp, repo) do
    git(repo, ["checkout", "-q", "-b", "feat/x"])
    git(repo, ["push", "-q", "-u", "origin", "feat/x"])
    File.write!(Path.join(repo, "g"), "y")
    git(repo, ["add", "g"])

    case git(repo, ["commit", "-qm", "unpushed"]) do
      {0, _} -> :ok
      {_, err} -> raise "fixture could not commit: #{String.slice(err, 0, 200)}"
    end
  end

  defp unmanaged(tmp, _repo), do: File.rm_rf!(Path.join([tmp, ".repo", "projects", "proj.git"]))

  defp mid_rebase(_tmp, repo), do: File.mkdir_p!(Path.join([repo, ".git", "rebase-merge"]))

  defp mid_merge(_tmp, repo),
    do: File.write!(Path.join([repo, ".git", "MERGE_HEAD"]), "deadbeef\n")

  defp not_a_checkout(_tmp, repo), do: File.rm_rf!(Path.join(repo, ".git"))

  defp gone(_tmp, repo), do: File.rm_rf!(repo)
end

args = System.argv()

cond do
  "--self-test" in args ->
    System.halt(Sync.SelfTest.run())

  true ->
    root =
      args
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> List.first(".")
      |> Path.expand()

    Sync.Run.main(root, if("--preflight" in args, do: :preflight, else: :sync))
end
