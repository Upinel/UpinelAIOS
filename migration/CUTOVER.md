# Cutting over to the unified UpinelAIOS

The state this starts from: `UpinelAIOS-GGUF` carries a branch called
`UpinelAIOS` that serves **both engines**, and `UpinelAIOS-MLX` is the older
MLX-only edition.

The state it ends in: there is one repo. `UpinelAIOS-GGUF` is renamed to
**`UpinelAIOS`**, its `main` is the merged branch, and `UpinelAIOS-MLX` carries
a redirect instead of a project.

Nothing here is destructive until step 4, and steps 1–3 are reversible with a
`git reset`. Do not start until you have finished testing the branch.

---

## 0. Preconditions

```bash
cd /path/to/UpinelAIOS-G
git switch UpinelAIOS
git status --short          # must be empty
```

Everything below assumes a clean tree. The full sweep must be green:

```bash
./bench/verify-all.sh       # 258 assertions, offline, no server needed
./install.sh --scan-only    # must not error
```

`verify-all.sh` deliberately excludes `bench/verify-tools.py`, which needs a
live endpoint — run that one via `./bench/verify-tools.sh` with the server up.

If any of that fails, stop — this is not a cutover problem, it is a bug.

---

## 1. Land the branch on `main`

```bash
git switch main
git merge --ff-only UpinelAIOS     # fast-forward if main has not moved
```

If `--ff-only` refuses, `main` has commits the branch does not. Look before
merging:

```bash
git log --oneline main ^UpinelAIOS
```

Do not force this. If those commits matter, merge them into the branch first and
re-test; if they are junk, say so explicitly in the merge commit rather than
dropping them silently.

## 2. Confirm `main` is the merged product

```bash
git switch main
grep -rn "UpinelAIOS-GGUF" --include="*.sh" --include="*.py" --include="*.md" --include="*.conf" . \
  | grep -v '^./.git/' | grep -v '^./migration/CUTOVER.md:'
```

Expect **no output**. Any hit is a stale identity that survived the merge.

`migration/CUTOVER.md` is excluded because it is this file: it has to name the
old repo to explain the rename, so it matches itself. Without that exclusion
this check reports hits forever and stops meaning anything.

```bash
grep -n 'SERVED_MODEL_NAME' env.conf lib/common.sh
```

Both must read `Upinel-AIOS` — code default and config agreeing is what makes
the bench tools work against a fresh install.

Re-run the sweep from step 0 on `main`. It is the same tree, but the point of
cutover is to stop assuming.

## 3. Push

```bash
git push origin main
git push origin UpinelAIOS
```

Keep the branch until the rename is confirmed working, then:

```bash
git push origin --delete UpinelAIOS
```

## 4. Rename the repository

On GitHub: **Settings → General → Repository name** → `UpinelAIOS` → Rename.
Or, with the [GitHub CLI](https://cli.github.com/manual/gh_repo_rename), where
`<new-name>` is the new name without the owner and `-R` selects the repo:

```bash
gh repo rename UpinelAIOS -R Upinel/UpinelAIOS-GGUF
```

GitHub redirects the old URLs, so existing clones keep fetching and pushing.
Two things that redirect does **not** survive:

- **Creating a new repo called `UpinelAIOS-GGUF`.** That reuses the old name and
  kills the redirect for everyone still pointing at it. Do not do it.
- **Anything that hardcoded the old name** in a CI config, a badge, or a
  `git remote` outside this machine. The redirect covers `git`, not prose.

Point the local clone at the new URL:

```bash
git remote set-url origin https://github.com/Upinel/UpinelAIOS.git
git remote -v
git fetch origin && git status
```

The local directory name is irrelevant to git. Renaming it is cosmetic:

```bash
cd .. && mv UpinelAIOS-G UpinelAIOS && cd UpinelAIOS
```

## 5. Redirect the MLX repo

```bash
cd /path/to/UpinelAIOS-MLX
git switch main

# Keep the original README under its own name - it documents what the MLX
# edition was, and the redirect is more trustworthy when the history stays.
git mv README.md README-MLX-EDITION.md

cp /path/to/UpinelAIOS/migration/UpinelAIOS-MLX-README.md README.md
git add README.md README-MLX-EDITION.md
git -c user.name="Upinel" -c user.email="noreply@upinel.dev" \
    commit -m "Redirect to the unified UpinelAIOS, which now serves MLX too"
git push origin main
```

Then, on GitHub: **Settings → General → Danger Zone → Archive this repository**,
or `gh repo archive -R Upinel/UpinelAIOS-MLX`.
Archiving makes it read-only and shows a banner, which is the honest signal —
the code is not gone, but it is not where development happens.

Do **not** delete it. Every `mlx-q-*` alias in the merged repo traces back to
this repo's work, and the issues and history are the record of how the MLX side
was tuned.

## 6. Verify the cutover

```bash
cd /path/to/UpinelAIOS
git pull

# Identity
grep -n "SERVED_MODEL_NAME" env.conf lib/common.sh
grep -rn "UpinelAIOS-GGUF" --include="*.md" --include="*.sh" . \
  | grep -v '^./.git/' | grep -v '^./migration/CUTOVER.md:'

# Licence is still byte-identical to the MLX edition's
shasum -a 256 LICENSE
# 0906eccc1ebc7e22f8de876997a4f33b7b85c3516d2c5a28796aad759fde7ff7

# Compatibility: pre-merge aliases still resolve to the same weights
python3 bench/verify-legacy-aliases.py

# Everything offline
./bench/verify-all.sh
```

Then do one real install end to end, on the merged `main`, from a clean clone:

```bash
git clone https://github.com/Upinel/UpinelAIOS /tmp/aios-check && cd /tmp/aios-check
./install.sh --deps-only
./model_download.sh gguf-g-26ba4b     # must also fetch the 240 MB MTP draft head
./start.sh
./bench/verify-tools.py               # needs the live server
./stop.sh
```

The draft-head line matters. `gguf-g-26ba4b` does not publish it; the installer
borrows it from a sibling repo. If that step is skipped the server still comes
up, just autoregressive and about half the speed, with nothing to say why.

---

## Rollback

Before step 4, everything is git and `git reset --hard` is the whole story.

After the rename, the repo name is the only irreversible-ish part — GitHub will
let you rename it back, but old links will have been re-shared by then.

The MLX redirect is reversible by reverting one commit; nothing in it deletes
the edition's code.

---

## What is deliberately *not* in this runbook

- **Deleting `UpinelAIOS-MLX`.** Archiving is enough, and deleting loses the
  MLX tuning history that the merged repo's defaults came from.
- **Rewriting history to drop the old name.** Every commit message, tag and
  issue that says `UpinelAIOS-GGUF` was true when it was written. Rewriting to
  make a grep clean would break the SHA-256 people already have.
- **Forcing the merge.** If `--ff-only` refuses, that is information, not an
  obstacle.
