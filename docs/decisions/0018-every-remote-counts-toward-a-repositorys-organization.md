# 18. Count every remote toward a repository's organization

Accepted on 2026-11-03. This changes what [decision 16](0016-a-rail-of-organizations-in-the-sidebar.md) says about where a repository's organization comes from.

## Context

Decision 16 took a repository's organization from its `origin` URL. That misses a clone that has no `origin`, such as one that pushes to a client's Azure DevOps and to the company's GitHub, with a remote named for each. yaga saw no owner at all and listed it under **No remote**, even though it has two.

Choosing one remote to go by wouldn't settle it. Most branches in a clone like that track the client's remote, so going by what branches track would put it under the client, whereas the user thinks of it as the company's, where their other repositories are. Nothing in the clone says which of its remotes matters most.

## Decision

**Every remote counts.** yaga reads the `url` of every remote and takes each one's owner as before, from the first segment of the path. `origin` has no more say than any other remote. A remote's separate `pushurl` doesn't count.

**A repository is listed in each organization it has an owner in.** An organization still needs at least two listed repositories, and a repository counts once for an owner, however many of its remotes that owner has. **Other** lists a repository only when none of its owners has an organization, and names it after its first owner, which is `origin`'s if it has one, and otherwise goes by the names of its remotes.

**The sidebar stays where it is when it can.** Selecting a repository that the current organization lists stays in that organization, and doesn't change what its other organizations showed last. Selecting one from elsewhere moves the sidebar to its first organization. Selecting one from **All** counts as showing it in each of its organizations.

## Consequences

- A fork with `origin` in the user's account and `upstream` in an organization is listed in both, when each has another repository listed.
- **Add to acme** lists clones with `acme` as an owner of any remote, by the same rule.
- `repositories.json` keeps the first owner as `owner` and saves the rest as `moreOwners`. Earlier versions read the first and ignore the rest, and a file without `moreOwners` still opens.
- yaga still runs one short git command per repository each time it refreshes the list, which now reads every remote.
- An owner is still the first segment of the path on every host, so more URLs can now get it wrong. An Azure DevOps SSH URL, `git@ssh.dev.azure.com:v3/acme/project/repo`, reads as owned by `v3`.
