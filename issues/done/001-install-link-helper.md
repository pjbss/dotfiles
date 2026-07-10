## Parent PRD

`issues/prd.md`

## What to build

A shared `install_link(src, dst)` helper used by the root `install.sh` and every per-directory `install.sh` (`git/`, `zsh/`, `vim/`) to create symlinks safely and idempotently. Per PRD Implementation Decisions ("Installer") and Further Notes (the `git/install.sh` logic has apparently never been run on this machine, and the current `zsh/install.sh` / `vim/install.sh` both do an unconditional `rm` with no backup).

Behavior:
- No-ops if `dst` is already a symlink pointing at `src`.
- If `dst` exists as a real file/dir (not already the correct symlink), back it up with a timestamped suffix before linking.
- Creates the symlink at `dst` pointing to `src`.

Rewire `zsh/install.sh` and `vim/install.sh` to call `install_link` instead of their current unconditional `rm ~/.zshrc` / `rm ~/.vim; rm ~/.vimrc` logic. `git/install.sh`'s backup/append logic for `~/.gitconfig` should also be reconsidered to use the same idempotent pattern where applicable (it currently does an unconditional backup-copy-append every run rather than a proper no-op check).

## Acceptance criteria

- [x] `install_link` helper exists (e.g. in root `install.sh` or a sourced shared file) and is used by `git/install.sh`, `zsh/install.sh`, and `vim/install.sh`
- [x] Running the root `install.sh` twice in a row on a machine with nothing yet installed results in symlinks being created on the first run and a clean no-op on the second run (no errors, no duplicate backups)
- [x] Running `install.sh` when `~/.zshrc`, `~/.vimrc`/`~/.vim`, or `~/.gitconfig` already exist as real files backs them up with a timestamped suffix before linking, with nothing lost
- [x] Manually verified in a scratch `$HOME` (or via `HOME=` override) rather than against the real live dotfiles, since automated tests are out of scope for this effort

## Resolution notes

- `install_link(src, dst)` added to root `install.sh`, defined before the per-directory sourcing loop so it's in scope for `git/`, `zsh/`, and `vim/`'s sourced `install.sh` scripts.
- `zsh/install.sh` and `vim/install.sh` rewired to call `install_link` instead of unconditional `rm`+`ln`. `vim/install.sh`'s `mkdir` calls switched to `mkdir -p` for idempotency (nothing else changed there).
- `git/install.sh` reworked: since it merges `git/gitconfig.partial` into a real file rather than symlinking, it now writes a `# dotfiles: managed block from ...` marker line before the appended partial, backs up `~/.gitconfig` with a timestamped suffix only the first time (when the marker isn't yet present), and no-ops entirely on subsequent runs. This preserves any user edits made to `~/.gitconfig` after installation, unlike the old restore-from-backup-then-reappend-every-run logic.
- Verified manually via `HOME=<scratch dir> bash install.sh`, twice in a row, against both an empty scratch `$HOME` and one pre-seeded with real (non-symlink) `.zshrc`/`.vimrc`/`.vim`/`.gitconfig` files — confirmed first-run linking + backups, second-run full no-op (no output, no duplicate backups), and backup file contents matched the original files exactly.
- No automated tests added, per PRD Testing Decisions (deliberately out of scope for this repo).

## Blocked by

None - can start immediately

## User stories addressed

- User story 24
- User story 25
- User story 27
