# Decisions

This folder records the decisions that shape yaga, one file per decision, so that anyone working on the project can see what was decided and why. Each record describes the situation that prompted the decision, the decision itself, and what follows from it.

Records aren't rewritten when a decision changes. Instead, a new record explains the change and marks the old one as superseded.

| # | Decision | Status |
| --- | --- | --- |
| [1](0001-distribute-outside-the-app-store.md) | Distribute outside the Mac App Store | Accepted |
| [2](0002-minimum-macos-26.md) | Require macOS 26 or later | Accepted |
| [3](0003-use-the-users-git.md) | Use the user's git, with a minimum version | Accepted |
| [4](0004-apache-2-license.md) | License yaga under Apache 2.0 | Accepted |
| [5](0005-read-the-commit-graph-and-run-git.md) | Read history from the commit-graph file and run git for everything else | Accepted |
| [6](0006-keep-the-commit-graph-up-to-date.md) | Keep the commit-graph file up to date automatically | Accepted |
| [7](0007-commit-list-is-an-nstableview.md) | Build the commit list on NSTableView | Accepted |
| [8](0008-require-git-2-44.md) | Require git 2.44 or later | Accepted |
| [9](0009-diff-view-uses-textkit-1.md) | Show diffs in a TextKit 1 text view | Accepted |
| [10](0010-our-own-tabs-in-one-window.md) | Show repositories as tabs that yaga draws itself | Partly superseded by [13](0013-repositories-in-a-sidebar.md) |
| [11](0011-thin-xcode-project-and-a-local-package.md) | Keep the Xcode project thin and the code in a local Swift package | Accepted |
| [12](0012-history-in-topological-order.md) | Show history in topological order by default | Accepted |
| [13](0013-repositories-in-a-sidebar.md) | List repositories and their worktrees in a sidebar | Accepted |
| [14](0014-the-sidebar-keeps-every-added-repository.md) | Keep every added repository in the sidebar, and save the list in Application Support | Sidebar order changed by [16](0016-a-rail-of-organizations-in-the-sidebar.md) |
| [15](0015-uncommitted-changes-as-a-row-in-history.md) | Show uncommitted changes as a row at the top of history | Accepted |
| [16](0016-a-rail-of-organizations-in-the-sidebar.md) | Pick repositories by organization with a rail in the sidebar | Folding of worktrees changed by [17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md), and where an owner comes from by [18](0018-every-remote-counts-toward-a-repositorys-organization.md) |
| [17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md) | Show a repository's worktrees with a line, and collapse them into one row | Accepted |
| [18](0018-every-remote-counts-toward-a-repositorys-organization.md) | Count every remote toward a repository's organization | Accepted |
| [19](0019-pull-and-push-from-the-branch-in-the-title-row.md) | Pull and push from the branch in the title row | The house's animation changed by [21](0021-draw-the-houses-animations-from-joints.md), its icons' drawings by [24](0024-icons-as-custom-symbols-from-lucide.md), how the house comes and goes by [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md), and what a stuck worktree shows by [28](0028-show-a-worktree-thats-stuck-partway.md) |
| [20](0020-fetch-when-yaga-becomes-active.md) | Fetch by itself when yaga becomes active | Accepted |
| [21](0021-draw-the-houses-animations-from-joints.md) | Draw the house's animations from joints, in Swift | How the house comes and goes changed by [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md), and a fetch's house removed by [26](0026-a-fetch-shows-only-its-words.md) |
| [22](0022-host-the-landing-page-on-cloudflare-workers.md) | Host the landing page on Cloudflare Workers, as static files | Accepted |
| [23](0023-one-badge-for-a-branch-and-its-upstream.md) | Show a branch and its upstream as one badge, and a commit's body after its subject | Its colors and the current branch's checkmark changed by [27](0027-give-the-graph-and-branches-monokais-colors.md) |
| [24](0024-icons-as-custom-symbols-from-lucide.md) | Draw the app's icons as custom symbols, from Lucide | Accepted |
| [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md) | Zoom the house in and out, and move the words the way the commits go | A fetch's house removed by [26](0026-a-fetch-shows-only-its-words.md) |
| [26](0026-a-fetch-shows-only-its-words.md) | A fetch shows only its words | Accepted |
| [27](0027-give-the-graph-and-branches-monokais-colors.md) | Give the graph and the branches Monokai's colors | Accepted |
| [28](0028-show-a-worktree-thats-stuck-partway.md) | Show a worktree that's stuck partway through | Accepted |
