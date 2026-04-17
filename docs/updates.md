# Updates

| Track | What | Auto-applies | Human touch |
|-------|------|--------------|-------------|
| OS packages (APT) | Ubuntu security + optional patch channel | yes (nightly, unattended-upgrades) | only major/LTS upgrades (`do-release-upgrade`) |
| Container images + Ansible collections + GitHub Actions | Docker images, `ansible-galaxy` deps, workflow `uses:` | patch: yes (auto-merge PR); minor/major: no (approve in GitHub UI) | click "Merge" on the PR |

## OS packages — unattended-upgrades

Configured by the `common` role. Two knobs in `roles/common/defaults/main.yml` (override in `/etc/homelab/config.yml`):

```yaml
unattended_upgrades_mode: security   # or "patch"
unattended_upgrades_mail: ""          # optional: email recipient for reports
```

| Mode | Origins allowed |
|------|----------------|
| `security` (default) | `distro-security` only. Classic Ubuntu guidance. |
| `patch` | `security` + `distro-updates`. Auto-applies stable point releases too. Bigger drift, higher break risk (still rare on LTS). |

`apt_pinned_packages` (default: docker-ce + friends) are always blacklisted — Docker major versions never auto-bump. You bump Docker by updating the pin or letting Renovate propose it.

Reports: set `unattended_upgrades_mail` and make sure `sendmail`-compatible MTA is present (out of scope for this iteration — easiest: add ntfy or Gotify web push later).

## Container images + workflows — Renovate

Config: `renovate.json` at repo root.

### What Renovate watches

- **Docker images referenced in role defaults** (the `*_image:` lines in `roles/**/defaults/main.yml`). Custom regex manager, datasource `docker`.
- **GitHub Actions** in `.github/workflows/*.yml` (`uses:` lines). Native manager.
- **Ansible collections** in `ansible/requirements.yml`. Native manager (major bumps disabled — we pin major ourselves).

### Behaviour

| Update type | Action | UI |
|-------------|--------|-----|
| `digest` (image sha) | auto-merge after CI green | PR shows, closes itself |
| `patch` (1.2.3 → 1.2.4) | auto-merge after CI green | same |
| `minor` (1.2.x → 1.3.0) | open PR, wait for your click | labelled `needs-approval` |
| `major` (1.x → 2.x) | open PR, wait for your click | labelled `needs-approval` |
| vulnerability alert | open PR immediately, ignores schedule | labelled `security` |

Schedule: weekly (`before 6am on monday`) except security, which fires any time.

### The UI

- **GitHub PR list** — each pending update = one PR. Diff shows the version bump + (if Renovate found them) release notes and changelogs.
- **Dependency Dashboard** — a single issue titled `🤖 Renovate dashboard (approve major/minor here)` with checkbox list of every pending change. Tick a box to trigger Renovate to re-open / re-create the PR. This is the closest thing to a native "approve" UI.
- **Merge the PR** → `deploy.yml` fires automatically (because it matches `paths: ansible/**`) → Ansible rolls out the new image or dep → done.

### Enabling Renovate

One-time GitHub App install, no self-hosting needed:

1. Go to https://github.com/apps/renovate → **Install**
2. Pick the `ChobotX/homelab` repo.
3. Renovate will open an onboarding PR (`Configure Renovate`). Since `renovate.json` already exists in the repo, Renovate will just use it. Merge the onboarding PR.
4. First run creates the dashboard issue + initial set of PRs for anything currently out of date.

### Self-hosted alternative

If you'd rather run Renovate on the homelab itself (no third-party app), add a role that `docker run`s `renovate/renovate` nightly. Overkill for one repo; revisit when there are 5+.

## New services

When you add a service (`docs/add-service.md`), put the image in `*_image:` form in `roles/<svc>/defaults/main.yml`:

```yaml
nextcloud_image: "nextcloud:30.0.1"
```

Renovate's regex manager catches it automatically.

## Rolling back an update

Patch auto-merged and broke something? Three options:

1. **Revert the PR**: GitHub UI → PR → Revert → merge the revert PR → `deploy.yml` redeploys the old image.
2. **Pin manually**: edit `roles/<svc>/defaults/main.yml`, pin to the known-good tag, commit, push.
3. **Emergency rollback on the box** (bypasses IaC):
   ```bash
   docker compose -f /opt/<svc>/docker-compose.yml pull <svc>:<old-tag>
   docker compose -f /opt/<svc>/docker-compose.yml up -d
   ```
   Then follow up with option 1 or 2 so the repo matches reality.

## What we deliberately don't do

- **watchtower / auto-pull latest inside containers.** Bypasses IaC. You'd have no record of what version ran when something broke. Renovate + deploy.yml gives you the same "it just upgrades" outcome with a full audit trail.
- **LTS distro upgrade automation.** `do-release-upgrade` is a deliberate, rare event. Wear a helmet, run manually, verify.
