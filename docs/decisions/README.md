# Decisions

This folder records the decisions that shape Roga, one file per decision, so that anyone working on the project can see what was decided and why. Each record describes the situation that prompted the decision, the decision itself, and what follows from it.

Records aren't rewritten when a decision changes. Instead, a new record explains the change and marks the old one as superseded.

Records written before [decision 34](0034-name-the-app-roga.md) call the app yaga, because that was its name at the time, and their paths and commands use the old names too.

| # | Decision | Status |
| --- | --- | --- |
| [1](0001-distribute-outside-the-app-store.md) | Distribute outside the Mac App Store | Its download address changed by [34](0034-name-the-app-roga.md) |
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
| [14](0014-the-sidebar-keeps-every-added-repository.md) | Keep every added repository in the sidebar, and save the list in Application Support | Sidebar order changed by [16](0016-a-rail-of-organizations-in-the-sidebar.md), and the folder's name by [34](0034-name-the-app-roga.md) |
| [15](0015-uncommitted-changes-as-a-row-in-history.md) | Show uncommitted changes as a row at the top of history | What the panel holds and how tall it is changed by [30](0030-stage-and-commit-beside-history.md) |
| [16](0016-a-rail-of-organizations-in-the-sidebar.md) | Pick repositories by organization with a rail in the sidebar | Folding of worktrees changed by [17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md), and where an owner comes from by [18](0018-every-remote-counts-toward-a-repositorys-organization.md), and rows given a second line while there's something to say by [48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md), and the rail replaced by groups in the list by [53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md) |
| [17](0017-a-line-and-a-row-for-a-repositorys-worktrees.md) | Show a repository's worktrees with a line, and collapse them into one row | Accepted |
| [18](0018-every-remote-counts-toward-a-repositorys-organization.md) | Count every remote toward a repository's organization | A repository in two organizations listed once by [53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md) |
| [19](0019-pull-and-push-from-the-branch-in-the-title-row.md) | Pull and push from the branch in the title row | The house's animation changed by [21](0021-draw-the-houses-animations-from-joints.md), its icons' drawings by [24](0024-icons-as-custom-symbols-from-lucide.md), how the house comes and goes by [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md), what a stuck worktree shows by [28](0028-show-a-worktree-thats-stuck-partway.md), how a diverged branch asks by [29](0029-dialogs-that-say-what-happens-and-show-the-command.md), the repository's name made a menu by [40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md), and Fetch, New Branch and the number of commits moved to the right end by [45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md) |
| [20](0020-fetch-when-yaga-becomes-active.md) | Fetch by itself when yaga becomes active | The Fetch button turning while it runs added by [45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md) |
| [21](0021-draw-the-houses-animations-from-joints.md) | Draw the house's animations from joints, in Swift | How the house comes and goes changed by [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md), and a fetch's house removed by [26](0026-a-fetch-shows-only-its-words.md) |
| [22](0022-host-the-landing-page-on-cloudflare-workers.md) | Host the landing page on Cloudflare Workers, as static files | The app's name settled by [34](0034-name-the-app-roga.md) |
| [23](0023-one-badge-for-a-branch-and-its-upstream.md) | Show a branch and its upstream as one badge, and a commit's body after its subject | Its colors and the current branch's checkmark changed by [27](0027-give-the-graph-and-branches-monokais-colors.md), and another remote's branch of the same name by [35](0035-one-cloud-for-each-remote-on-a-badge.md) |
| [24](0024-icons-as-custom-symbols-from-lucide.md) | Draw the app's icons as custom symbols, from Lucide | What folds changed to a chevron by [31](0031-chevrons-for-what-folds-and-lines-down-a-tree.md) |
| [25](0025-the-house-zooms-and-the-words-move-the-way-the-commits-go.md) | Zoom the house in and out, and move the words the way the commits go | A fetch's house removed by [26](0026-a-fetch-shows-only-its-words.md) |
| [26](0026-a-fetch-shows-only-its-words.md) | A fetch shows only its words | Partly superseded by [45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md), where the Fetch button turns instead |
| [27](0027-give-the-graph-and-branches-monokais-colors.md) | Give the graph and the branches Monokai's colors | Colors given to lanes rather than columns by [42](0042-run-each-line-down-to-its-parent-in-its-lanes-color.md) |
| [28](0028-show-a-worktree-thats-stuck-partway.md) | Show a worktree that's stuck partway through | Reverts added by [44](0044-revert-a-commit-from-its-menu-in-history.md) |
| [29](0029-dialogs-that-say-what-happens-and-show-the-command.md) | Dialogs that say what happens and show the command | Partly superseded by [33](0033-one-row-in-a-menu-and-the-choice-in-the-dialog.md) and [38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) |
| [30](0030-stage-and-commit-beside-history.md) | Stage and commit in the panels under history | When a heading's buttons show changed by [39](0039-discard-with-undo-and-ask-only-for-many.md), and how the panel's height is split by [55](0055-split-the-panel-for-uncommitted-changes-40-40-and-20.md) |
| [31](0031-chevrons-for-what-folds-and-lines-down-a-tree.md) | Chevrons for what folds, and lines down a tree of files | Accepted |
| [32](0032-ask-before-forcing-a-worktree-with-submodules.md) | Ask before forcing a worktree with submodules | Accepted |
| [33](0033-one-row-in-a-menu-and-the-choice-in-the-dialog.md) | Put one row in a menu, and the choice in the dialog | A commit's menu changed by [38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) |
| [34](0034-name-the-app-roga.md) | Name the app Roga, at roga.sh | Accepted |
| [35](0035-one-cloud-for-each-remote-on-a-badge.md) | One cloud on a badge for each remote that has the branch | Accepted |
| [36](0036-a-solid-ink-tile-for-whats-selected-on-the-rail.md) | A solid ink tile for what's selected on the rail | Superseded by [53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md), which removes the rail |
| [37](0037-double-click-a-commit-to-go-to-it.md) | Double-click a commit to go to it | Accepted |
| [38](0038-one-delete-on-a-commit-with-its-branches-in-the-dialog.md) | One Delete… on a commit, with its branches in the dialog | A commit's menu gets Revert… in [44](0044-revert-a-commit-from-its-menu-in-history.md) |
| [39](0039-discard-with-undo-and-ask-only-for-many.md) | Discard changes, with Undo, and ask only for more than one file | Accepted |
| [40](0040-the-repositorys-name-opens-a-menu-of-its-worktrees.md) | The repository's name opens a menu of its worktrees | Accepted |
| [41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) | Show what agents are doing from their hooks, and write commit messages with their CLIs | The working ring made to turn by [46](0046-turn-the-ring-of-an-agent-at-work.md), and what the helper sends and what the mark's tooltip and the worktree menu say by [47](0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md), and its mark moved to the start of that second line by [48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md), then to the right of the row, with a worktree's New Window button dropped, by [51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md) |
| [42](0042-run-each-line-down-to-its-parent-in-its-lanes-color.md) | Run each line down to its parent, in its lane's color | Accepted |
| [43](0043-show-a-new-version-in-the-sidebar-rather-than-sparkles-window.md) | Show a new version in the sidebar, rather than in Sparkle's window | Moved from the rail to a row at the top of the sidebar by [53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md) |
| [44](0044-revert-a-commit-from-its-menu-in-history.md) | Revert a commit from its menu in history | Accepted |
| [45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md) | Fetch and New Branch as buttons, and the number of commits with history's commands | The Fetch icon's turn replaced by the house dropping through the button in [57](0057-the-house-drops-through-the-fetch-button.md) |
| [46](0046-turn-the-ring-of-an-agent-at-work.md) | Turn the ring of an agent at work | Accepted |
| [47](0047-say-what-an-agent-is-doing-in-a-line-the-helper-makes.md) | Say what an agent is doing, in a line the helper makes | Accepted |
| [48](0048-a-second-line-under-a-sidebar-row-while-theres-something-to-say.md) | A second line under a sidebar row while there's something to say | The mark moved to the right of the row, and the line's words given a fade and how long its own place at the right, by [51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md) |
| [49](0049-look-again-at-what-changes-on-disk.md) | Look again at what changes on disk | Accepted |
| [50](0050-branches-in-folders-at-each-slash-of-their-names.md) | Branches in folders, at each slash of their names | Accepted |
| [51](0051-marks-at-the-right-of-a-sidebar-row-and-names-that-fade.md) | Marks at the right of a sidebar row, and names that fade | Accepted |
| [52](0052-maximize-or-minimize-the-panels-under-history.md) | Maximize or minimize the panels under history | Accepted |
| [53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md) | Organizations as groups in the list, and Add Repositories and Settings at the top | Accepted |
| [54](0054-menus-as-wide-as-their-rows-and-shortcuts-for-the-worktree-on-screen.md) | Menus as wide as their rows, and shortcuts for the worktree on screen | Accepted |
| [55](0055-split-the-panel-for-uncommitted-changes-40-40-and-20.md) | Split the panel for uncommitted changes 40, 40 and 20 | Accepted |
| [56](0056-the-panels-show-a-run-of-commits-two-commits-a-branch-or-a-stash.md) | The panels show a run of commits, two commits, a branch or a stash | Accepted |
| [57](0057-the-house-drops-through-the-fetch-button.md) | The house drops through the Fetch button | Accepted |
