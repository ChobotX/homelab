# GitHub repo settings

Set once, after bootstrap. Not enforced by code.

## Branch protection — `main`

- Require PR before merging, 1 approval, dismiss stale approvals
- Required checks: `lint`, `docker-test`
- Require conversation resolution
- Require linear history
- Restrict pushes (nobody direct to `main`)
- Require signed commits

## Actions — General

- Actions permissions → **Allow select actions**, allowlist
- Fork PR workflows from outside collaborators → **Require approval**
- Workflow permissions → **Read contents + packages**

## Code security

- Dependabot alerts + security updates
- Secret scanning + push protection

## Account

- 2FA (TOTP + WebAuthn)
- SSH commit signing
