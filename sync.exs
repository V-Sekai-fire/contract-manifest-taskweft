# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# One step: preflight every checkout, park what is safe to park, `repo sync`,
# then verify.
#
# WHY THIS EXISTS. `repo sync` is not idempotent against a dirty client. It
# walks every project in the manifest, and one of them in the wrong state stops
# the walk for all of them - which is expensive twice over, because the
# projects that did sync are now at a different revision from the ones that did
# not, and the next run starts from that mixture.
#
# A correct sync here was several commands and the order mattered. Out of order
# it fails silently: sync before the preflight and `repo` starts a rebase it
# cannot finish. Several commands that must run in one order is one command
# nobody had written.
#
# FOUR STATES STOP A SYNC, and the gate enumerates all four rather than the
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
#   happened to `2-contract/pixel-stream`.
#
#   A MERGE OR REBASE ALREADY IN PROGRESS. The residue of a previous failure.
#   It reads as the first state to anybody skimming, and it is not: no branch
#   is checked out, and the fix is `git rebase --abort` rather than a checkout.
#
#   A DIRTY CHECKOUT THE MANIFEST DROPPED. `repo sync` deletes each path in
#   `.repo/project.list` the manifest no longer places, refuses one holding
#   uncommitted or untracked files, and stops there. This happened to
#   `3-interactor/stable-diffusion-ggml`, with two more dirty behind it.
#
# THE MANIFEST IS THE ONE REPO SYNC WILL READ. `repo sync` fetches the manifest
# before anything else, so a preflight of the checkout's `default.xml` misses
# what the remote just dropped. The preflight reads the remote's copy when the
# checkout is only behind it, and stops when the two have diverged.
#
# WHAT IT PARKS, AND WHAT IT REFUSES TO. Parking a branch is destructive when
# the branch is the only copy of the work, so the distinction is kept rather
# than dropped for convenience: a branch whose commits are all on its upstream
# is detached and deleted, and a branch carrying anything the remote has not
# seen stops the run with the branch named. An unmanaged checkout is renamed to
# `<path>.aside`, which keeps its work, so repo sync can clone the path. Rebase
# residue and a dirty dropped checkout stop the run - each needs a judgement
# this script does not have. `--preflight` fetches the manifest and touches
# nothing else.
#
# VERIFICATION IS PART OF THE RUN, not a thing to remember afterwards. After the
# sync every project is re-checked and any still-blocking one is counted, so a
# sync that left a checkout in a bad state does not read as a success. Every
# dropped path is re-checked too: `repo` renames a checkout it cannot empty to
# `<path>_repo_to_be_deleted_<time>` and reports success.
#
# DETECTION FLOOR. None. The population is every <project> element in
# `default.xml` and every path in `.repo/project.list` it no longer places, two
# fixed lists, so both are enumerated rather than sampled. A project the
# manifest names and the disk does not carry is counted and named: `repo sync`
# clones it, so it is not a failure, but a run that printed nothing about it
# would be indistinguishable from one that checked it.
#
# CONTROLS. Three positive and fourteen negative, plus three that a missing
# project, a dropped path already off disk and one left without .git are each
# counted rather than skipped. `--self-test` runs them.
#
# Run:  elixir sync.exs [workspace] [--preflight] [--self-test]

defmodule Sync do
  @moduledoc false

  @default_manifest Path.join([".repo", "manifests", "default.xml"])

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
          (not File.exists?(Path.join([root, ".repo", "projects", path <> ".git"])) or
             match?({:ok, %{type: :directory}}, File.lstat(gitdir))) ->
        {:fail,
         "a plain git repository repo does not manage; move it aside and let repo sync clone it"}

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

  # ---- the manifest repo sync will read -----------------------------------

  def upcoming_manifest(root) do
    dir = Path.join([root, ".repo", "manifests"])

    with {0, _} <- git(dir, ["fetch", "-q"]),
         {0, behind} <- git(dir, ["rev-list", "--count", "HEAD..@{upstream}"]),
         {0, ahead} <- git(dir, ["rev-list", "--count", "@{upstream}..HEAD"]) do
      cond do
        behind == "0" ->
          {:ok, Path.join(dir, "default.xml"), "the checkout's, which is current"}

        ahead != "0" ->
          {:error,
           "the manifest checkout has #{ahead} commit(s) of its own and is #{behind} behind; " <>
             "repo sync rebases them, so the manifest it will read is not known yet"}

        true ->
          case git(dir, ["show", "@{upstream}:default.xml"]) do
            {0, xml} ->
              tmp = Path.join(System.tmp_dir!(), "sync-#{System.unique_integer([:positive])}.xml")
              File.write!(tmp, xml)
              {:ok, tmp, "the remote's, #{behind} commit(s) ahead of the checkout"}

            {_, err} ->
              {:error, "cannot read the remote's default.xml: #{String.slice(err, 0, 160)}"}
          end
      end
    else
      {_, err} ->
        {:error, "cannot read the manifest repo sync will use: #{String.slice(err, 0, 160)}"}
    end
  end

  # ---- dropped projects ---------------------------------------------------

  def placed(manifest), do: MapSet.new(projects(manifest), &elem(&1, 0))

  def dropped(root, manifest) do
    placed = placed(manifest)

    case File.read(Path.join([root, ".repo", "project.list"])) do
      {:ok, body} ->
        for path <- String.split(body, ["\r\n", "\n"], trim: true),
            not MapSet.member?(placed, path) do
          {verdict, detail} = inspect_dropped(root, path, placed)
          {path, verdict, detail}
        end

      {:error, _} ->
        []
    end
  end

  def inspect_dropped(root, path, placed) do
    full = Path.join(root, path)

    cond do
      not File.exists?(full) ->
        {:gone, "off disk"}

      not File.exists?(Path.join(full, ".git")) ->
        if Enum.any?(placed, &String.starts_with?(&1, path <> "/")),
          do: {:gone, "only a placed project beneath it remains"},
          else: {:remnant, "left on disk without .git, which repo sync skips"}

      true ->
        case git(full, ["status", "--porcelain", "--ignored"]) do
          {0, out} ->
            {ignored, dirty} =
              out
              |> String.split("\n", trim: true)
              |> Enum.split_with(&String.starts_with?(&1, "!! "))

            cond do
              dirty != [] ->
                {:fail,
                 "dropped by the manifest with #{length(dirty)} uncommitted path(s), " <>
                   "which repo sync refuses to delete"}

              ignored == [] ->
                {:dropped, "repo sync deletes it"}

              true ->
                names =
                  ignored |> Enum.take(4) |> Enum.map_join(", ", &String.trim_leading(&1, "!! "))

                {:dropped,
                 "repo sync deletes it and #{length(ignored)} ignored path(s): #{names}"}
            end

          {_, err} ->
            {:fail,
             "dropped by the manifest, and git cannot read it: #{String.slice(err, 0, 120)}"}
        end
    end
  end

  def left_behind(root, placed, drops) do
    Enum.flat_map(drops, fn
      {_, :remnant, _} ->
        []

      {path, _, _} ->
        root = Path.expand(root)
        renamed = Path.wildcard(Path.join(root, path) <> "_repo_to_be_deleted_*", match_dot: true)

        case {renamed, inspect_dropped(root, path, placed)} do
          {[r | _], _} -> [{path, "renamed by repo to #{Path.relative_to(r, root)}; delete it"}]
          {[], {:gone, _}} -> []
          {[], {_, detail}} -> [{path, "still on disk after the sync: #{detail}"}]
        end
    end)
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

  @doc "Rename an unmanaged checkout out of the manifest path, keeping it whole."
  def move_aside(root, path) do
    full = Path.join(root, path)

    dest =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(fn
        0 -> full <> ".aside"
        n -> full <> ".aside#{n}"
      end)
      |> Enum.find(&(not File.exists?(&1)))

    case File.rename(full, dest) do
      :ok -> {:ok, "moved aside to #{Path.relative_to(dest, root)}; repo sync clones the path"}
      {:error, why} -> {:error, "move aside failed: #{why}"}
    end
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

    upcoming =
      case upcoming_manifest(root) do
        {:ok, path, whose} ->
          IO.puts("  default.xml: #{whose}")
          path

        {:error, why} ->
          IO.puts("  STOP   #{pad(".repo/manifests")} #{why}")
          System.halt(1)
      end

    rows = check(root, upcoming)
    drops = dropped(root, upcoming)
    if upcoming != manifest, do: File.rm(upcoming)

    {parked, blocked} =
      Enum.reduce(rows, {[], []}, fn
        {_p, v, _d}, acc when v != :fail ->
          acc

        {path, :fail, detail}, {ok, bad} ->
          result =
            cond do
              mode == :preflight -> {:error, detail}
              String.contains?(detail, "on branch ") -> park(root, path, detail)
              String.contains?(detail, "repo does not manage") -> move_aside(root, path)
              true -> {:error, detail}
            end

          case result do
            {:ok, why} -> {[{path, why} | ok], bad}
            {:error, why} -> {ok, [{path, why} | bad]}
          end
      end)

    parked = Enum.reverse(parked)
    blocked = Enum.reverse(blocked)
    stopped = for {path, :fail, why} <- drops, do: {path, why}
    absent = Enum.count(rows, fn {_, v, _} -> v == :absent end)

    for {path, why} <- parked, do: IO.puts("  parked #{pad(path)} #{why}")
    for {path, why} <- blocked ++ stopped, do: IO.puts("  STOP   #{pad(path)} #{why}")

    for {path, v, why} <- drops,
        v == :remnant or String.contains?(why, "ignored"),
        do: IO.puts("  drop   #{pad(path)} #{why}")

    IO.puts(
      "  #{length(rows)} project(s) enumerated, #{absent} absent from disk, " <>
        "#{length(parked)} parked, #{length(blocked)} blocking, 0 unchecked."
    )

    IO.puts(
      if File.regular?(Path.join([root, ".repo", "project.list"])) do
        "  #{length(drops)} dropped by the manifest: #{tally(drops, :dropped)} for repo sync " <>
          "to delete, #{length(stopped)} blocking, #{tally(drops, :gone)} off disk, " <>
          "#{tally(drops, :remnant)} left without .git."
      else
        "  no .repo/project.list, so repo sync has no dropped path to delete."
      end
    )

    cond do
      blocked != [] or stopped != [] ->
        IO.puts(
          "\nNothing was synced. Each line above needs a decision this script " <>
            "does not have:\nunpushed work to push or discard, rebase residue to abort, " <>
            "or files in a dropped checkout to keep or discard."
        )

        System.halt(1)

      mode == :preflight ->
        IO.puts("\nEvery project on disk is in a state `repo sync` can advance.")
        System.halt(0)

      true ->
        :ok
    end

    IO.puts("\n== repo sync")
    code = repo_sync(root)

    IO.puts("\n== verify")
    left = Enum.count(check(root, manifest), fn {_, v, _} -> v == :fail end)
    behind = left_behind(root, placed(manifest), drops)
    for {path, why} <- behind, do: IO.puts("  left   #{pad(path)} #{why}")
    IO.puts("  #{length(rows)} project(s) enumerated, #{left} still blocking.")
    IO.puts("  #{length(drops)} dropped path(s) re-checked, #{length(behind)} left behind.")

    cond do
      code != 0 ->
        IO.puts("\nrepo sync failed.")
        System.halt(1)

      left > 0 or behind != [] ->
        System.halt(1)

      true ->
        IO.puts("\nSynced.")
        System.halt(0)
    end
  end

  defp pad(s), do: String.pad_trailing(s, 42)
  defp tally(rows, verdict), do: Enum.count(rows, fn {_, v, _} -> v == verdict end)
end

defmodule Sync.SelfTest do
  @moduledoc false
  import Sync

  def run do
    IO.puts("\nsync.exs self-test")

    positives = [
      {"a detached checkout at the pinned tag", "refs/tags/v1", fn _, _ -> :ok end},
      {"a checkout on the branch the manifest pins", "topic",
       fn _, repo -> git(repo, ["checkout", "-q", "-b", "topic"]) end},
      {"a clean checkout the manifest dropped, deleted by the sync", "refs/tags/v1", &drop/2}
    ]

    bad =
      Enum.reduce(positives, 0, fn {name, rev, setup}, acc ->
        in_tmp(fn tmp ->
          {manifest, repo} = fixture(tmp, rev)
          setup.(tmp, repo)
          drops = dropped(tmp, manifest)
          File.rm_rf!(Path.join(tmp, "old"))

          clean =
            Enum.all?(check(tmp, manifest) ++ drops, fn {_, v, _} -> v in [:ok, :dropped] end) and
              left_behind(tmp, placed(manifest), drops) == []

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
      {"a plain clone beside a stub repo made for it", &plain_clone/2, :fail},
      {"an unmanaged checkout is moved aside with its commits", &unmanaged/2, :aside},
      {"a rebase left in progress", &mid_rebase/2, :fail},
      {"a merge left in progress", &mid_merge/2, :fail},
      {"a manifest path that is not a checkout", &not_a_checkout/2, :fail},
      {"a project the disk does not carry is counted, not skipped", &gone/2, :absent},
      {"a dropped checkout with a deleted tracked file", &dropped_deletion/2, :fail},
      {"a dropped checkout with an untracked file", &dropped_untracked/2, :fail},
      {"a dirty checkout only the remote's manifest drops", &behind_manifest/2, :upcoming},
      {"a manifest checkout diverged from its remote", &diverged_manifest/2, :unknown},
      {"a dropped checkout the sync left on disk", &drop/2, :left},
      {"a dropped checkout repo renamed instead of deleting", &renamed/2, :left},
      {"a dropped path left without .git is counted, not skipped", &remnant/2, :remnant},
      {"a dropped path already off disk is counted, not skipped", &dropped_gone/2, :gone}
    ]

    bad =
      Enum.reduce(negatives, bad, fn {name, mutate, want}, acc ->
        in_tmp(fn tmp ->
          {manifest, repo} = fixture(tmp, "refs/tags/v1")
          mutate.(tmp, repo)

          caught =
            case want do
              :refused ->
                {_, detail} = inspect_project(tmp, "proj", "refs/tags/v1")
                {res, _} = park(tmp, "proj", detail)
                {_, branch} = git(repo, ["symbolic-ref", "--short", "-q", "HEAD"])
                res == :error and branch == "feat/x"

              :aside ->
                {res, _} = move_aside(tmp, "proj")
                {code, _} = git(repo <> ".aside", ["rev-parse", "--verify", "-q", "v1"])
                res == :ok and not File.exists?(repo) and code == 0

              :upcoming ->
                case upcoming_manifest(tmp) do
                  {:ok, m, _} ->
                    found = Enum.any?(dropped(tmp, m), &match?({"old", :fail, _}, &1))
                    File.rm(m)
                    found

                  {:error, _} ->
                    false
                end

              :unknown ->
                match?({:error, _}, upcoming_manifest(tmp))

              :left ->
                left_behind(tmp, placed(manifest), [{"old", :dropped, ""}]) != []

              _ ->
                Enum.any?(check(tmp, manifest) ++ dropped(tmp, manifest), fn {_, v, _} ->
                  v == want
                end)
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
    tmp =
      Path.join(
        System.tmp_dir!(),
        "synctest-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    try do
      fun.(tmp)
    after
      for git <- Path.wildcard(Path.expand(tmp) <> "/*/.git", match_dot: true), do: unlink(git)
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
    projects = Path.join([tmp, ".repo", "projects", "proj.git"])
    File.rm_rf!(projects)
    File.rename!(Path.join(repo, ".git"), projects)
    link(projects, Path.join(repo, ".git"))
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

  defp unmanaged(tmp, repo) do
    plain_clone(tmp, repo)
    File.rm_rf!(Path.join([tmp, ".repo", "projects", "proj.git"]))
  end

  defp plain_clone(tmp, repo) do
    :ok = unlink(Path.join(repo, ".git"))
    File.cp_r!(Path.join([tmp, ".repo", "projects", "proj.git"]), Path.join(repo, ".git"))
  end

  defp mid_rebase(_tmp, repo), do: File.mkdir_p!(Path.join([repo, ".git", "rebase-merge"]))

  defp mid_merge(_tmp, repo),
    do: File.write!(Path.join([repo, ".git", "MERGE_HEAD"]), "deadbeef\n")

  defp not_a_checkout(_tmp, repo), do: File.rm_rf!(Path.join(repo, ".git"))

  defp gone(_tmp, repo), do: File.rm_rf!(repo)

  # Erlang needs the symlink privilege on Windows; mklink works under developer mode.
  defp link(target, at) do
    with {:error, _} <- File.ln_s(target, at) do
      native = Enum.map([at, target], &:filename.nativename/1)
      {_, 0} = System.cmd("cmd", ["/c", "mklink", "/D" | native])
    end
  end

  # A directory link on Windows is removed with rmdir, not rm.
  defp unlink(at), do: with({:error, _} <- File.rm(at), do: File.rmdir(at))

  defp drop(tmp, _repo) do
    File.write!(Path.join([tmp, ".repo", "project.list"]), "old\r\nproj\r\n")
    old = Path.join(tmp, "old")
    git(tmp, ["clone", "-q", Path.join(tmp, "origin"), old])
    old
  end

  defp dropped_deletion(tmp, repo), do: drop(tmp, repo) |> Path.join("f") |> File.rm!()
  defp dropped_untracked(tmp, repo), do: drop(tmp, repo) |> Path.join("g") |> File.write!("y")
  defp remnant(tmp, repo), do: drop(tmp, repo) |> Path.join(".git") |> File.rm_rf!()
  defp dropped_gone(tmp, repo), do: drop(tmp, repo) |> File.rm_rf!()

  defp renamed(tmp, repo),
    do: File.rename!(drop(tmp, repo), Path.join(tmp, "old_repo_to_be_deleted_1"))

  defp behind_manifest(tmp, repo) do
    dropped_untracked(tmp, repo)
    remote = Path.join(tmp, "manifests-origin")
    File.mkdir_p!(remote)
    git(remote, ["init", "-q"])
    commit_manifest(remote, ~s(<project name="old" path="old" />))
    git(tmp, ["clone", "-q", remote, Path.join([tmp, ".repo", "manifests"])])
    commit_manifest(remote, "")
  end

  defp diverged_manifest(tmp, repo) do
    behind_manifest(tmp, repo)

    commit_manifest(
      Path.join([tmp, ".repo", "manifests"]),
      ~s(<project name="mine" path="mine" />)
    )
  end

  defp commit_manifest(dir, extra) do
    git(dir, ["config", "user.email", "t@t"])
    git(dir, ["config", "user.name", "t"])

    File.write!(
      Path.join(dir, "default.xml"),
      ~s(<manifest>#{extra}<project name="proj" path="proj" revision="refs/tags/v1" /></manifest>\n)
    )

    git(dir, ["add", "default.xml"])

    case git(dir, ["commit", "-qm", "m"]) do
      {0, _} -> :ok
      {_, err} -> raise "fixture could not commit: #{String.slice(err, 0, 200)}"
    end
  end
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
