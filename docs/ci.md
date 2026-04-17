# CI / CD

After `bootstrap.sh` registers a self-hosted runner, every change flows through GitHub Actions.

## Workflows

| Workflow | Trigger | Runs on | What |
|----------|---------|---------|------|
| `.github/workflows/ci.yml` | every PR + push | GitHub-hosted `ubuntu-24.04` | yamllint, ansible-lint, gitleaks, shellcheck, Docker harness |
| `.github/workflows/deploy.yml` | push to `main` touching `ansible/`, `bootstrap.sh`, or this workflow; manual `workflow_dispatch` | self-hosted runner on the homelab | `ansible-playbook` with `connection: local`, post-deploy smoke |

`deploy.yml` uses `concurrency: deploy-homelab` — no two deploys race.

## No repo secrets needed

Everything sensitive lives on the homelab under `/etc/homelab/secrets/`. The runner reads it directly via Ansible slurp. GitHub stores nothing beyond the account-level PAT you used to register the runner in the first place — and that never leaves your laptop.

## Steady state

```bash
git push        # or Actions → deploy → Run workflow
```

That's it.

## Manual runs

Actions → `deploy` → Run workflow:
- `tags` → limit to one role, e.g. `traefik`
- `check` → dry run, no changes

## Self-hosted runner hygiene

The runner = a persistent process on the homelab, executing whatever is on `main`.

- Runs as `gha-runner`, not the admin user.
- Sudo is scoped (not `ALL`) — only the binaries Ansible needs.
- Forks can't push directly — their PRs run `ci` (no secrets) but never `deploy`.
- Audit:
  ```bash
  sudo systemctl status 'actions.runner.*'
  ls /opt/actions-runner/_work
  ```

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `deploy` stuck "Waiting for a runner" | Runner offline | `sudo systemctl status 'actions.runner.*'` on homelab; restart |
| Runner up but jobs skipped | Label mismatch | `GITHUB_RUNNER_LABELS` must match `runs-on:` in `deploy.yml` (`self-hosted, linux, homelab`) |
| Ansible fails on a missing var | `/etc/homelab/config.yml` missing or incomplete | `sudo $EDITOR /etc/homelab/config.yml` |
| Ansible template missing a secret | File missing in `/etc/homelab/secrets/` | `sudo install -m 0400 -T <(printf '%s' VALUE) /etc/homelab/secrets/NAME` |
| `docker-test` job fails | Real regression | Read the output — sanity asserts fail explicitly |

## Rotating / unregistering the runner

```bash
sudo systemctl stop 'actions.runner.*'
cd /opt/actions-runner
gh api -X POST /repos/<owner>/<repo>/actions/runners/remove-token --jq .token
sudo -u gha-runner ./config.sh remove --token <token>
sudo ./svc.sh uninstall
```

Or re-run `bootstrap.sh --skip-runner` to keep everything else.

## What CI does NOT cover

- `bootstrap.sh` itself — runs once on console, before CI exists.
- Adding new WG peers — hub-side change, outside this repo.
- Restic restore drill — manual (`docs/restore.md`).
