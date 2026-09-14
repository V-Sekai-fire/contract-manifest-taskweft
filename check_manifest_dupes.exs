# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Gate: the goal manifest carries one project per interface. Two projects
# with the same name, or two entries mounted at the same path, or two
# checkouts of the same remote and revision at different paths, are the
# duplicate shape RFD 2229's interchangeable-parts policy exists to stop.
#
# WHY THIS EXISTS. The workspace's own reference case is three ggml checkouts
# with three revisions where RFD 2188 says there is one canonical source at
# 2-contract/ggml. The duplicates were not visible in review because a
# manifest is 200 lines that look like data, and duplicates are absence of
# a difference — three of the same thing reads as unremarkable. The gate
# reads the manifest the way a machine does and reports the groups.
#
# WHAT COUNTS AS A DUPLICATE. Three shapes, one line-item per shape:
#   1. Two <project> entries with the same `(remote, name, revision)`
#      triple. Two entries with the same repo name pointed at two
#      different branches are the legitimate multi-side-checkout pattern
#      (`entities-godot` at both `main/fabric-0.2.3` and `feat/module-*`
#      side by side), so the revision is part of the key.
#   2. Two <project> entries with the same `path`. Two things trying to
#      mount at the same directory is the same class of failure the
#      manifest-root gate checks against files, one level up.
#   3. Two <project> entries with the same (remote, revision) pair at
#      different paths WHEN THE REVISION IS A SHA PIN. Not a `repo`-level
#      failure — `repo sync` will happily clone the same commit into two
#      directories — but it is the interchangeable-parts pattern this gate
#      exists to surface: two consumers pinned to identical bytes with no
#      consolidation in sight. Scoped to SHA revisions because a branch
#      name like `main` is the natural default for "this project's tip"
#      and pointing many projects at their own `main` is not a duplicate.
#      A revision counts as a SHA when it is 40 lowercase hex characters
#      or a `refs/tags/...` reference — the two forms `repo` accepts as a
#      pin distinct from "the current branch tip".
#
# WHAT DOES NOT COUNT. Two <project> entries with the same NAME on
# different REMOTES — that's how upstreams are named the way their vendor
# names them (`ggml` under `weftspun` vs `ggml` under an upstream). The
# `name`-collision rule is scoped by remote, matching how `repo` itself
# resolves the pair.
#
# DETECTION FLOOR. None. The manifest is a fixed population; every
# <project> is read, none sampled. `repo` clients read the same file the
# same way, so the gate cannot miss what a client would trip on.
#
# CONTROLS. Every counter carries a planted control. `--self-test` runs
# them: one planted duplicate name is rejected, one planted duplicate path
# is rejected, one planted duplicate remote+revision is rejected, a clean
# manifest passes, and a manifest with two same-named entries on different
# remotes passes (the not-a-duplicate case).
#
# Run:  elixir check_manifest_dupes.exs [--manifest PATH] [--self-test]

defmodule ManifestDupes do
  @moduledoc false

  def parse(path) do
    {doc, _rest} = path |> String.to_charlist() |> :xmerl_scan.file(quiet: true)
    projects =
      for {:xmlElement, :project, _, _, _, _, _, attrs, _, _, _, _} <-
            xml_walk(doc) do
        Enum.reduce(attrs, %{}, fn
          {:xmlAttribute, :name, _, _, _, _, _, _, v, _}, acc ->
            Map.put(acc, :name, List.to_string(v))

          {:xmlAttribute, :path, _, _, _, _, _, _, v, _}, acc ->
            Map.put(acc, :path, List.to_string(v))

          {:xmlAttribute, :remote, _, _, _, _, _, _, v, _}, acc ->
            Map.put(acc, :remote, List.to_string(v))

          {:xmlAttribute, :revision, _, _, _, _, _, _, v, _}, acc ->
            Map.put(acc, :revision, List.to_string(v))

          _, acc ->
            acc
        end)
      end

    default_remote = default_remote(doc)
    Enum.map(projects, fn p ->
      p
      |> Map.put_new(:remote, default_remote)
      |> Map.put_new(:path, Map.get(p, :name))
    end)
  end

  defp default_remote(doc) do
    doc
    |> xml_walk()
    |> Enum.find_value(fn
      {:xmlElement, :default, _, _, _, _, _, attrs, _, _, _, _} ->
        Enum.find_value(attrs, fn
          {:xmlAttribute, :remote, _, _, _, _, _, _, v, _} -> List.to_string(v)
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp xml_walk(node), do: xml_walk(node, [])
  defp xml_walk({:xmlElement, _, _, _, _, _, _, _, children, _, _, _} = el, acc),
    do: Enum.reduce(children, [el | acc], fn c, a -> xml_walk(c, a) end)
  defp xml_walk(_other, acc), do: acc

  # Three duplicate shapes, in the order the docstring names them.
  def groups(projects) do
    sha_pinned = Enum.filter(projects, &sha_revision?/1)

    [
      by_name: group(projects, fn p -> {p[:remote], p[:name], p[:revision]} end),
      by_path: group(projects, fn p -> p[:path] end),
      by_remote_rev: group(sha_pinned, fn p -> {p[:remote], p[:revision]} end)
    ]
    |> Enum.map(fn {k, v} ->
      {k, v |> Enum.filter(fn {_key, ps} -> length(ps) > 1 end)}
    end)
  end

  defp group(projects, key_fn) do
    projects
    |> Enum.group_by(key_fn)
    |> Enum.reject(fn {k, _} -> is_nil(k) or (is_tuple(k) and elem(k, 1) == nil) end)
  end

  # A SHA revision is 40 lowercase hex, or a `refs/tags/...` pin. Anything
  # else — `main`, `master`, `feat/whatever` — is a branch tip and does not
  # count as an interchangeable-parts duplicate.
  defp sha_revision?(%{revision: rev}) when is_binary(rev) do
    Regex.match?(~r/^[0-9a-f]{40}$/, rev) or String.starts_with?(rev, "refs/tags/")
  end
  defp sha_revision?(_), do: false

  def report(dupes) do
    lines =
      for {shape, groups} <- dupes, {key, ps} <- groups do
        header =
          case shape do
            :by_name -> "duplicate name #{inspect(key)}"
            :by_path -> "duplicate path #{inspect(key)}"
            :by_remote_rev -> "duplicate remote+revision #{inspect(key)}"
          end

        body =
          Enum.map_join(ps, "\n", fn p ->
            "  - name=#{p[:name]} path=#{p[:path]} remote=#{p[:remote]} revision=#{p[:revision] || "<unset>"}"
          end)

        header <> "\n" <> body
      end

    Enum.join(lines, "\n\n")
  end

  def total(dupes), do: Enum.sum(for {_shape, groups} <- dupes, do: length(groups))
end

defmodule ManifestDupes.SelfTest do
  @moduledoc false

  @clean """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="a" revision="main" />
    <project name="beta"  path="b" revision="main" />
  </manifest>
  """

  @dup_name """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="a1" revision="main" />
    <project name="alpha" path="a2" revision="main" />
  </manifest>
  """

  # Same name, same remote, but two different revisions is the legitimate
  # multi-side-checkout pattern (entities-godot at main/fabric-0.2.3 next
  # to entities-godot at feat/module-pixal3d). Not a duplicate.
  @same_name_diff_rev """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="a1" revision="main" />
    <project name="alpha" path="a2" revision="feat/branch" />
  </manifest>
  """

  @dup_path """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="shared" revision="main" />
    <project name="beta"  path="shared" revision="main" />
  </manifest>
  """

  # The (remote, revision) check applies only to SHA pins; two consumers
  # of the same 40-char commit at different paths is the interchangeable-
  # parts case. A branch-name revision like `main` at two paths is not.
  @dup_remote_rev """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="a" revision="a675fe9d2184333729f194317fa7b2895dd439f8" />
    <project name="beta"  path="b" revision="a675fe9d2184333729f194317fa7b2895dd439f8" />
  </manifest>
  """

  # Two projects both at `main` are not a duplicate — that's the natural
  # default. Control asserts the SHA-scoping doesn't let branch-name reuse
  # slip past.
  @same_branch_no_dupe """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <default remote="one" />
    <project name="alpha" path="a" revision="main" />
    <project name="beta"  path="b" revision="main" />
  </manifest>
  """

  # Same NAME on different REMOTES is not a duplicate. That is how upstreams
  # are usually named the way their vendor names them — the ggml under
  # weftspun and an unrelated ggml under some upstream fork.
  @same_name_diff_remote """
  <?xml version="1.0" encoding="UTF-8"?>
  <manifest>
    <remote name="one" fetch="https://example.com/one" />
    <remote name="two" fetch="https://example.com/two" />
    <default remote="one" />
    <project name="ggml" path="p1" remote="one" revision="main" />
    <project name="ggml" path="p2" remote="two" revision="main" />
  </manifest>
  """

  def run do
    cases = [
      {"a clean manifest passes", @clean, :passes},
      {"a duplicate name is rejected", @dup_name, :rejects},
      {"a duplicate path is rejected", @dup_path, :rejects},
      {"a duplicate SHA-pinned remote+revision is rejected", @dup_remote_rev, :rejects},
      {"same name on different remotes passes", @same_name_diff_remote, :passes},
      {"two projects at branch revision `main` pass", @same_branch_no_dupe, :passes},
      {"same name/remote at different revisions passes", @same_name_diff_rev, :passes}
    ]

    Enum.reduce(cases, {0, 0}, fn {label, xml, expected}, {ok, bad} ->
      tmp = Path.join(System.tmp_dir!(), "check-manifest-dupes-#{:erlang.unique_integer([:positive])}.xml")
      File.write!(tmp, xml)

      dupes =
        try do
          ManifestDupes.parse(tmp) |> ManifestDupes.groups()
        after
          File.rm(tmp)
        end

      actual = if ManifestDupes.total(dupes) == 0, do: :passes, else: :rejects

      if actual == expected do
        IO.puts("  ok   #{label}")
        {ok + 1, bad}
      else
        IO.puts("  FAIL #{label}: expected #{expected}, got #{actual}")
        IO.puts(ManifestDupes.report(dupes))
        {ok, bad + 1}
      end
    end)
    |> case do
      {n, 0} ->
        IO.puts("\nAll #{n} controls behaved.")
        0

      {_, bad} ->
        IO.puts("\n#{bad} control(s) misbehaved.")
        1
    end
  end
end

# ---- entry point ----
args =
  System.argv()
  |> Enum.chunk_by(&String.starts_with?(&1, "--"))
  |> case do
    [flags] -> flags
    _ -> System.argv()
  end

cond do
  "--self-test" in args ->
    System.halt(ManifestDupes.SelfTest.run())

  true ->
    manifest =
      case Enum.chunk_every(System.argv(), 2, 1, [nil]) do
        chunks ->
          Enum.find_value(chunks, "default.xml", fn
            ["--manifest", v] when is_binary(v) -> v
            _ -> nil
          end)
      end

    unless File.regular?(manifest) do
      IO.puts(:stderr, "check_manifest_dupes: manifest not found: #{manifest}")
      System.halt(2)
    end

    dupes = manifest |> ManifestDupes.parse() |> ManifestDupes.groups()

    if ManifestDupes.total(dupes) == 0 do
      IO.puts("no duplicates in #{manifest}")
      System.halt(0)
    else
      IO.puts(ManifestDupes.report(dupes))
      System.halt(1)
    end
end
