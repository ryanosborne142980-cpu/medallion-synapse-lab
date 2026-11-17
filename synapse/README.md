# synapse/

Synapse Studio's Git root (D9). Pipelines, datasets, linked services and SQL scripts land here
as JSON when you **Save** in Studio. Fabric equivalent: a Git-integrated workspace folder.

- **Save** in Studio = a git commit to the branch Studio is on. Work in a Studio feature branch;
  `main` is protected and only accepts PRs.
- **Publish** (from `main` only) = deploy to the live workspace + a commit of ARM templates to
  the `workspace_publish` branch. Never edit, merge or protect `workspace_publish` by hand.
- Studio PRs: squash-merge with a Conventional Commit title (Studio's own commit messages
  don't follow the convention).
- Linked services authenticate with the workspace managed identity only; a source that needs a
  secret gets a Key Vault reference. CI fails on inline secrets in this folder.
- After a teardown/redeploy the live workspace is empty: open Studio, re-authorize GitHub if
  asked, and Publish from `main`.

Synapse ignores files here that aren't artifacts, like this README.
