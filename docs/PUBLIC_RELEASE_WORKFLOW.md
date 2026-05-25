# Public Release Workflow

This repository now uses two different local concepts on purpose:

- `main`: engineering branch that keeps the upstream DeerFlow development history intact.
- `public-release`: local publish branch that points to the single-author public snapshot pushed to `steven/main`.

This split lets the public repository show only the maintainer as the contributor, without rewriting the engineering history used for normal development.

## Why This Does Not Affect Installation Or Usage

The public publish flow does not patch files, rewrite the working tree, or apply any repo-specific transforms.

Instead, it publishes the exact Git tree from a chosen source ref by creating a synthetic root commit directly from `HEAD^{tree}`.

That means:

- the files seen by external users match the selected source snapshot exactly;
- README-based install steps stay aligned with the published contents;
- runtime behavior is unchanged unless the source branch itself changed it.

## Maintainer Rules

1. Do all normal development on `main`.
2. Do not implement product changes directly on `public-release`.
3. Publish only from a clean working tree unless you intentionally bypass that guard.
4. Treat `steven/main` as a generated public branch, not as the engineering source of truth.

## One-Time Setup State

The public repository branch on GitHub is `steven/main`.

The local branch used to track that generated public history is `public-release`.

## Publish Command

Dry run:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\publish-public-repo.ps1 -DryRun
```

Publish current `HEAD`:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\publish-public-repo.ps1
```

Publish a different ref explicitly:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\publish-public-repo.ps1 -SourceRef <git-ref>
```

## What The Script Does

1. Verifies the working tree is clean by default.
2. Reads the source ref commit and tree.
3. Reuses the existing `public-release` commit if the tree is unchanged.
4. Otherwise creates a new root commit with the current Git user as the only author.
5. Updates the local `public-release` ref.
6. Force-pushes that snapshot commit to `steven/main`.
7. Verifies that the remote branch points to the expected commit.

## Contributor Sidebar Note

GitHub's web UI can lag behind the actual repository state.

If the sidebar still shows stale contributor avatars immediately after a publish:

1. hard refresh the repository page;
2. check the contributors REST API response;
3. wait for GitHub's background counters to recalculate.

The source of truth is the repository history and the contributors API, not a cached sidebar snapshot.
