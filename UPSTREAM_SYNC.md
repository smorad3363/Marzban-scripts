# Upstream sync

The canonical upstream is `https://github.com/gozargah/Marzban-scripts.git`.

```bash
git remote add upstream https://github.com/gozargah/Marzban-scripts.git
git fetch upstream --prune --tags
git checkout master
git merge --ff-only upstream/master
```

If the fork contains local commits, create a dedicated sync branch and review the
upstream diff before merging. Never force-push `master`; keep published commit-pinned
installer URLs immutable.
