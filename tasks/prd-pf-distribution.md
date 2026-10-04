[PRD]
# PRD: pf Distribution and Verified Self-Update

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-10-02 | Arthur Jean | Initial draft from the workflow audit, the Paneflow release infrastructure, and web, documentation, and codebase research |
| 1.1 | 2026-10-02 | Arthur Jean | No release is published by this PRD: the pipeline is proven by dry runs, publication waits for Arthur's go decision, and US-018 becomes the go-live checklist |

## Problem Statement

pf cannot be released or updated. Every distribution path it inherited from fx points at infrastructure that belongs to Vercel, and the parts that would run unchanged would fail or publish nothing.

1. **The release workflows assume Vercel's accounts.** `release.yml` signs macOS binaries with `Developer ID Application: Vercel, Inc (JW6Y669B67)` (`scripts/sign-and-notarize-macos.sh:7`) and uploads to `blob.vercel-storage.com` with `BLOB_READ_WRITE_TOKEN` (`release.yml:289-328`). `dev-release.yml` and `cdn-backfill.yml` upload to the same store, `publish-libpf.yml` publishes an npm package pf does not own, and `prepare-release.yml` calls the Vercel AI Gateway with a paid key.
2. **The first public push would trigger failing, expensive runs.** `release.yml` runs on every push to `main` while the tag `v0.0.12` is missing, builds every platform including the macOS PGSO qualification, then fails at signing. `dev-release.yml` and `publish-libpf.yml` run after every successful `CI` run on `main` (`ci.yml` is named `CI`) and fail at upload or publish.
3. **`pf upgrade` is disabled and incomplete.** `cdn_base` is `null` (`src/core/upgrade/upgrade_helpers.zig:52`), so `pf upgrade` returns `NoReleaseChannel`. Downloads are verified by SHA-256 only (`upgrade_helpers.zig:353-385`), which proves integrity but not authenticity because the checksum comes from the same host. Windows has no platform string (`upgrade_helpers.zig:83-100`), extraction shells out to `tar` (`upgrade_helpers.zig:405-416`), and `replaceBinary` cannot replace a running `.exe` (`upgrade_helpers.zig:418-423`).
4. **The documentation describes infrastructure that does not exist.** `CONTRIBUTING.md` states that `paneflow.dev/agent/releases` is backed by the Vercel Blob CDN, `AGENTS.md` describes benchmark uploads to Vercel Blob that `bench.yml` no longer performs, and `NOTICE:14` states that upgrades are disabled.

**Why now:** Arthur is making the repository public, which turns these workflows on. EP-005 of the Windows PRD (`tasks/prd-windows-native-support.md`) cannot reach DONE until Full CI runs on the public repository, and that push must not fire the release workflows first. The CLI is not ready for a release yet, so the pipeline must be built and proven now without publishing anything, leaving the first release to a single deliberate step when Arthur decides. Paneflow already operates signing on the same Apple team and Azure account, and a Cloudflare R2 host (`pkg.paneflow.dev`), so pf can reuse them at no added cost.

## Overview

Delivery is phased, and no phase publishes a release. **Release 0 (public CI)** gates the three workflows that fire on `main` to manual dispatch and corrects the documentation, so the public push runs only verification workflows. **Release 1 (signed pipeline and verified upgrade, proven without publishing)** adapts the inherited pipeline to Paneflow's infrastructure: macOS binaries are signed and notarized with Paneflow's Apple Developer ID, `pf.exe` is signed with Paneflow's Azure Artifact Signing account (`strivex-signing`, profile `StriveX-Release`), every archive is signed with a minisign key dedicated to pf and attested with GitHub build provenance, and the publication to GitHub Releases and to a Cloudflare R2 bucket served at `https://releases.paneflow.dev/agent` is implemented, tested with fake uploaders, and exercised as a dry run. `pf upgrade` fetches only from that host, verifies the minisign signature fail-closed with two embedded public key slots, extracts archives in-process, and replaces itself on every platform including Windows, all proven against signed fixtures. **Release 2 (dev channel and SDK)** prepares signed dev builds as dry runs and settles whether the JavaScript SDK `libpf` becomes a pf product.

Publication stays behind three locks until Arthur decides the CLI is ready: the release workflows run only on manual dispatch, they default to dry runs, and the publishing job waits for Arthur's approval in the `release` environment. US-018 writes the go-live checklist that turns the proven pipeline into the first release in one session.

Key decisions. Hosting uses R2 rather than Vercel Blob: Blob on the Hobby plan includes 1 GB of storage and 10 GB of monthly transfer, stops serving for 30 days when exceeded, and forbids commercial use, while R2's free tier includes 10 GB of storage, 10 million reads, and free egress. The host is a Cloudflare subdomain rather than the path `paneflow.dev/agent/releases`, because `paneflow.dev` is served by Vercel and a path under it would route release traffic through Vercel, while `pkg.paneflow.dev` already shows the zone on Cloudflare. Signing reuses Paneflow's team-level identities instead of new accounts, so pf adds no subscription. The macOS notarization keeps fx's App Store Connect API key method and changes only the identity and identifier, which keeps the diff against fx small for future ports. Dev builds carry minisign signatures only, because Apple and Azure signing behind a reviewer gate on every push to `main` is impractical.

The self-updater follows the field's strongest pattern rather than its norm. Deno, Bun, and `gh` rely on HTTPS alone; the Zig toolchain signs every tarball with minisign. pf verifies a minisign signature whose signed trusted comment names the archive file, version, and channel, so a compromised bucket can neither substitute an archive nor relabel an older signed archive as a newer version. Stable upgrades keep refusing downgrades (`update_target.zig:134-140`).

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| Workflows that fail on a push to `main` of the public repository | 0 | 0 |
| Releases, tags, npm versions, or R2 release objects published before Arthur's go decision | 0 | 0 |
| `validate_only` runs where all five archives are signed, minisign-verified, and attested | 100% after US-009 | 100% |
| Full CI platforms where `pf upgrade` installs a signed fixture release end to end | 5 (Linux x86_64 and aarch64, macOS x86_64 and aarch64, Windows x86_64) | 5 |
| Added recurring cost (R2, CI, signing) | $0 | $0 |
| Tampered archives accepted by `pf upgrade` in tests | 0 | 0 |

## Target Users

### Maintainer releasing pf
- **Role:** Arthur, sole maintainer of pf and Paneflow, releasing from GitHub Actions.
- **Behaviors:** Already releases Paneflow with tag-driven workflows, Apple and Azure signing, minisign, and an R2 host. Ports fx changes by hand with `scripts/rebrand.py`. Wants pf's CLI finished before its first release.
- **Pain points:** pf's workflows reference Vercel accounts, so no release can be cut. Pushing the repository publicly would trigger failing runs on every push to `main`, and `release.yml` would try to publish `v0.0.12`. Divergent workflows make fx ports conflict.
- **Current workaround:** None. pf is built from source only (`README.md:18`).
- **Success looks like:** The whole pipeline is proven by dry runs while nothing is published, and when Arthur decides the CLI is ready, the first release takes one Prepare Release PR, one dispatch, and one approval, with no manual upload and no added cost.

### pf user updating the binary
- **Role:** A developer running pf on Linux, macOS, or Windows, in a terminal or inside Paneflow, once releases exist.
- **Behaviors:** Expects `pf upgrade` and background auto-upgrade to work like Claude Code's updater, with a way to disable them.
- **Pain points:** `pf upgrade` reports that no release channel exists. Windows users read that upgrades are unavailable (`README.md`, Windows section).
- **Current workaround:** Rebuilds pf from source with Zig 0.16.
- **Success looks like:** After the first release, `pf upgrade` installs the latest release in under a minute, refuses anything not signed by pf's key, and never leaves a broken binary. Before it, `pf upgrade` states that no release is published and auto-upgrade stays silent.

### Security-conscious adopter
- **Role:** A user or organization that verifies downloads before running them.
- **Behaviors:** Checks signatures and provenance before installing a CLI that executes commands.
- **Pain points:** No published signature or provenance exists for pf.
- **Current workaround:** Audits and builds the source.
- **Success looks like:** From the first release on, each archive has a minisign signature verifiable with a published public key and a GitHub provenance attestation verifiable with `gh attestation verify`.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **Claude Code:** own CDN, `stable` and `latest` channels, background auto-update with an opt-out environment variable; package-manager installs do not self-update ([setup docs](https://code.claude.com/docs/en/setup)). pf already has channels, `auto_upgrade`, and `PF_AUTO_UPGRADE=0`.
- **Zig toolchain:** JSON index plus minisign signatures over every tarball. pf adopts the same signature scheme.
- **Deno, Bun:** archives from GitHub Releases over HTTPS without signature verification. pf exceeds this by verifying minisign fail-closed.
- **GitHub CLI:** no self-update; a throttled update notice instead. pf keeps its existing 30-minute auto-upgrade interval (`auto_upgrade.zig:9`) and opt-out.
- **Market gap:** among comparable coding-agent CLIs, none documents a self-updater that verifies a publisher signature bound to the version it installs.

### Best Practices Applied
- Verify the archive completely, in a temporary directory, before touching the installed binary; replace atomically.
- Embed two public key slots (active and next) for rotation; keep the private key in a GitHub Environment secret.
- Bind the signature to the file name, version, and channel through minisign's signed trusted comment ([minisign](https://github.com/jedisct1/minisign)).
- Serve mutable manifests with `Cache-Control: no-cache` and immutable archives with a long cache lifetime ([rclone S3 docs](https://rclone.org/s3/)).
- Never poll the GitHub Releases API from the updater, which is rate limited to 60 requests per hour per IP without authentication.
- Attest build provenance with `actions/attest-build-provenance`, free for public repositories ([GitHub docs](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)).
- On Windows, rename the running `pf.exe` aside and sweep the leftover on the next start; `MoveFileEx` with delay-until-reboot needs elevation.

*Full research sources available in project documentation.*

## Assumptions & Constraints

### Assumptions (to validate)
- The `paneflow.dev` DNS zone is on Cloudflare, so an R2 custom domain can serve `releases.paneflow.dev`. Evidence: `pkg.paneflow.dev` answers with `Server: cloudflare`; validated by US-004.
  - **Validated (US-004, 2026-10-03):** the R2 bucket `paneflow-agent-releases` on the StriveX Cloudflare account serves the custom domain `releases.paneflow.dev` over TLS. Its R2 API token has Object Read & Write on that bucket only. `R2_ENDPOINT` is the account S3 endpoint `https://<account-id>.r2.cloudflarestorage.com` without a bucket path: with the bucket appended, rclone stores every key under `paneflow-agent-releases/` inside the bucket and reports success.
- Paneflow's Apple team can create an App Store Connect API key for `notarytool` at no cost, and its Developer ID Application certificate can sign pf, because the certificate identifies the team rather than an app.
- Paneflow's Azure profile `StriveX-Release` can sign `pf.exe` within the Basic tier's 5,000 monthly signatures, and the publisher shown as `Strivex` is acceptable for pf.
- GitHub Environments with required reviewers are available at no cost on a public repository.
- `std.zip`, `std.tar`, and `std.compress.flate` in Zig 0.16 extract pf's archives correctly; `std.crypto.sign.Ed25519` and `std.crypto.hash.blake2.Blake2b512` implement minisign's `ED` algorithm.
- Renaming a running `pf.exe` aside succeeds on Windows 10 1809 and Windows 11 for a binary in a user-writable directory.
- The npm name `libpf` is unregistered (the registry returned 404 on 2026-10-02).
- The publication path that dry runs and fake-uploader tests cannot reach (creating the tag and GitHub Release, real R2 writes under `agent/`) behaves as tested; it is first exercised by the go-live checklist.

### Hard Constraints
- No release is published by this PRD: no tag, GitHub Release, npm version of `libpf`, or R2 object under `agent/` is created until Arthur decides the CLI is ready and runs the go-live checklist (US-018). Every workflow change is proven with dry runs.
- No added recurring cost: only the existing Apple Developer Program membership and Azure Artifact Signing account may be used.
- Zig standard library only; no new Zig dependency (AGENTS.md).
- The repository's CLAUDE.md reserves distribution, signing, `pf upgrade`, and `.github/workflows/` for Arthur. The decisions recorded as decided in this PRD were made by Arthur on 2026-10-02; every other change in those areas follows Open Questions.
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, Vercel's copyright notice, and attribution in `NOTICE` stay; notable fx modifications are recorded in `NOTICE`.
- Binary format magics (`FXCP`, `FXTP`), the Slack bridge on `fx.sh`, and `vercel-labs/fx` attribution links stay protected in `scripts/rebrand.py`.
- Workflow changes keep the inherited structure where possible, so `python3 scripts/rebrand.py port` merges future fx changes with the fewest conflicts.
- Documentation never describes release downloads or upgrades as available before the first release (AGENTS.md: do not document intended behavior as if it already exists).

## Quality Gates

These commands must pass for every user story:
- `zig build` - build the pf binary
- `zig fmt --check src/` - formatting of all Zig sources
- `python3 scripts/rebrand.py check` - no unexpected fx spelling
- `zig build test -Dtest-filter="<changed area>"` - focused unit tests for the changed path

Additional gates by story type:
- Stories that change `scripts/sign-and-notarize-macos.sh` or signing tests: `python3 -m unittest scripts.tests.test_macos_signing scripts.tests.test_signed_macos -q`
- Stories that change `scripts/publish-release.sh`: `python3 -m unittest scripts.tests.test_publish_release -q`
- Stories that add or change an end-to-end test file: `cd tests/e2e && bun test <file>` and `python3 -m unittest scripts.pgso.tests.test_corpus`
- Stories that change `src/core/upgrade/` on Windows: a native Windows `zig build test -Dtest-filter=upgrade` with Zig on `PATH`
- Stories that change a release workflow: a `workflow_dispatch` run with its dry-run input enabled (`validate_only: true` for `release.yml`, `dry_run: true` for `dev-release.yml` and `cdn-backfill.yml`), observed green, after which `gh release list` shows no release and the R2 bucket holds no object under `agent/`
- Every story that changes the binary: a real run of `./zig-out/bin/pf` exercising the change, per AGENTS.md

## Epics & User Stories

### EP-001: Public CI baseline (Release 0)

Make the public push run only verification workflows, and state the real CI and release state in contributor docs.

**Definition of Done:** On the public repository, a push to `main` triggers no distribution workflow, Full CI is green on a pushed branch including `Full suite (windows-x86_64)`, and AGENTS.md and CONTRIBUTING.md describe no Vercel infrastructure as current.

#### US-001: Gate distribution workflows to manual dispatch
**Description:** As the maintainer, I want `release.yml`, `dev-release.yml`, and `publish-libpf.yml` to run only on manual dispatch so that pushing the public repository triggers no release run.

**Priority:** P0
**Size:** XS (1 pt)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Given `release.yml`, `dev-release.yml`, and `publish-libpf.yml`, when their triggers are read, then each runs only on `workflow_dispatch`, and every other job, input, and step is unchanged.
- [ ] Given `full-ci.yml`, `ci.yml`, `binary-size.yml`, `examples.yml`, `pgso-macos-arm64.yml`, `bench.yml`, `cdn-backfill.yml`, and `prepare-release.yml`, when this story lands, then their triggers are unchanged.
- [ ] Given a push to `main`, when GitHub evaluates workflows, then no run of the three gated workflows starts.
- [ ] Given a manual dispatch of `release.yml` without signing secrets, when it runs, then it fails before the `release` job, so no tag, GitHub Release, or upload is created.
- [ ] Given each gated workflow, when its file is read, then a comment states that an automatic trigger returns only through the go-live checklist (US-018).

#### US-002: Describe the actual CI and release state in contributor docs
**Description:** As a contributor, I want AGENTS.md and CONTRIBUTING.md to describe the CI and release state that exists so that no one follows a Vercel procedure that cannot run.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given the AGENTS.md Benchmarks section, when it is read, then it states that `bench.yml` uploads results as GitHub Actions artifacts and no longer mentions Vercel Blob.
- [ ] Given the CONTRIBUTING.md release section, when it is read, then it no longer states that `paneflow.dev/agent/releases` is backed by Vercel Blob, and states that pf publishes no release until Arthur runs the go-live checklist.
- [ ] Given the AGENTS.md Releasing section, when it is read, then it states that the release workflows run only on manual dispatch and that the steps it describes are the target process.
- [ ] Given AGENTS.md and CONTRIBUTING.md, when they are searched for `Vercel Blob` and `blob.vercel-storage.com`, then no match describes current pf infrastructure.
- [ ] Given the edited files, when `python3 scripts/rebrand.py check` runs, then it passes, and no em dash is introduced.

#### US-003: Obtain a green Full CI run on the public repository
**Description:** As the maintainer, I want Full CI to pass on the public repository so that the Windows PRD's US-026 and EP-005 can be certified and every later story has a CI signal.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given the repository published as public with Actions enabled, when a non-`main` branch is pushed, then Full CI runs and all five `Full suite (...)` jobs succeed on that exact commit.
- [ ] Given that run, when `Full suite (windows-x86_64)` is inspected, then it built `pf.exe` in ReleaseSafe, ran `zig build test`, the Windows E2E subset, and the `pf.exe help` and `pf.exe status --json` smoke tests.
- [ ] Given no `AI_GATEWAY_API_KEY` secret, when `ci.yml` runs on `main`, then the model-backed ACP tests are skipped and the job succeeds.
- [ ] Given a deliberately failing commit on a throwaway branch, when the Windows job fails, then its job summary names the failing step and test file, and the branch is deleted afterward.
- [ ] Given the green run, when `/review-epic tasks/prd-windows-native-support.md EP-005` runs, then US-026 has the run as its evidence.

**Evidence (2026-10-03):** `main` was fast-forwarded to `501e74d` and the push started only `CI` and `Benchmarks`, both green ([CI 37123328390](https://github.com/arthjean/pf/actions/runs/37123328390)); the first push at `389c31c` exposed a Shellcheck SC2016 failure in `scripts/check-public-surface.sh`, fixed by `501e74d`. Full CI passed all five `Full suite (...)` jobs on `389c31c` ([37112614414](https://github.com/arthjean/pf/actions/runs/37112614414)) and on `501e74d` ([37121908724](https://github.com/arthjean/pf/actions/runs/37121908724)). A default dispatch of `release.yml` without secrets ([37120705079](https://github.com/arthjean/pf/actions/runs/37120705079)) failed at both macOS signing steps and skipped the `release` job; no tag or GitHub Release exists. The failure probe ([37112616285](https://github.com/arthjean/pf/actions/runs/37112616285)) failed at `Run Windows E2E subset` naming `windows-tui-smoke.test.ts`, and its branch was deleted. The EP-005 review recorded run 37112614414 as US-026 evidence.

**Evidence (EP-001 review, 2026-10-03):** The repository is public with no tag, GitHub Release, repository secret, or environment secret. The `CI` run on `main` at `501e74d` skipped the 12 model-backed ACP tests and passed. `python3 scripts/rebrand.py check` failed on the fx history in this PRD and the Windows PRD, so both PRDs joined its skip list; `AGENTS.md` no longer cites a `pf upgrade` or CDN install as a way pf reaches `PATH`.

---

### EP-002: Signed release artifacts (Release 1)

Produce signed, attested archives for all five platforms, and implement publication to GitHub Releases and the R2 host behind an explicit dispatch, proven without publishing.

**Definition of Done:** A `validate_only` dispatch of `release.yml` builds, signs, notarizes, minisigns, and attests all five archives and verifies each, and runs the publication as a dry run that logs every destination; afterward no tag, GitHub Release, or R2 object under `agent/` exists. The publishing job exists behind `validate_only: false` and the `release` environment approval, and its upload logic passes `scripts/tests/test_publish_release.py`.

**Status (2026-10-03):** The repository side of US-005 to US-009 is implemented: `scripts/sign-and-notarize-macos.sh` signs with the Developer ID certificate of `APPLE_TEAM_ID` as `dev.paneflow.agent`, `release.yml` gains the `build-windows`, `sign-release`, and `release` jobs, `scripts/sign-release-archives.sh` and `scripts/publish-release.sh` carry the minisign and publication logic, and their tests run in the Full CI step "Test signing and release routing". `publish-release.sh` also refuses an `R2_ENDPOINT` with a path, the mistake the US-004 probe exposed. US-004 passed on 2026-10-03. Arthur then provisioned what only he can: the `release`, `apple-signing`, and `windows-signing` environments, each with Arthur as required reviewer and limited to `main`; their 17 secrets, none at repository level; a Developer ID Application certificate and an App Store Connect API key created for pf; a client secret of the Azure service principal dedicated to pf; and the pf minisign key pair, whose secret key exists only as `PF_MINISIGN_SECRET_KEY` in `release` and in Arthur's offline backup, and whose public key is the `active` slot of `src/core/upgrade/release_keys.zig`. The trusted comment and the R2 path use the release tag, such as `version:v0.1.0` and `agent/v0.1.0/`, because `latest.txt` carries the tag and `pf upgrade` builds its archive URL from it.

**Evidence (validate_only run, 2026-10-03):** A default dispatch of `release.yml` on `main` at `4049d49` ([37146229321](https://github.com/arthjean/pf/actions/runs/37146229321)) succeeded on attempt 2. Attempt 1 failed only in the PGSO job `Heavy ui-activity`, whose benchmark binary exited 1 on round 20 of 20; "Re-run failed jobs" passed it and ran the skipped jobs downstream of it. `Build macos-x86_64` passed `codesign --verify --strict --check-notarization` and notarization (submission `8deb0f0e-4dc1-4ca4-860c-b61f1f452c9d`). `Sign macos-arm64` signed and notarized both arm64 variants (submissions `8769506b-12ab-4c72-8a78-8ffae3d21f66` and `1c929634-e66a-4330-bad1-958877c1c294`). `Build windows-x86_64` passed `signtool verify /pa` with signer `CN=StriveX, O=StriveX, L=Nantes, S=Loire-Atlantique, C=FR`, and `pf-windows-x86_64.zip` holds `pf.exe`, `LICENSE`, and `THIRD_PARTY_NOTICES.md`. `Sign and attest archives` signed and verified the five archives with trusted comments such as `file:pf-windows-x86_64.zip version:v0.0.12 channel:stable`, created one attestation for the 10 archives and signatures ([52472605](https://github.com/arthjean/pf/attestations/52472605)), and logged the 15 dry-run destinations under `agent/v0.0.12/` as `immutable` and `agent/latest.txt` last as `no-cache`. The `release` job was skipped. From the downloaded `release-signed` artifact, `gh attestation verify -R arthjean/pf` succeeded for archives and signatures, `minisign -V` succeeded against the committed public key, and `sha256sum -c` passed for the Linux and Windows sidecars. Afterward `gh release list` and `git ls-remote --tags origin` were empty, and `https://releases.paneflow.dev/agent/latest.txt` and the archive paths returned 404. Full CI on `4049d49` ([37141972805](https://github.com/arthjean/pf/actions/runs/37141972805)) passed the Linux and macOS suites, including the step "Test signing and release routing"; `Full suite (windows-x86_64)` failed twice in timing-sensitive unit tests outside this epic (`mcp_runtime` restart after a stalled discovery, then also `browser_callback` reset preconnect), on Zig sources identical to the green run 37121908724.

**Evidence (EP-002 review, 2026-10-04):** Commits after `4049d49` touch only `tasks/`, so run 37146229321 covers the final workflow and scripts. Its job logs show `Successfully verified` and signer `O=StriveX` for `pf.exe` (the script matches `O=Strivex` without case), `Signed and notarized` for the three macOS binaries, which the script prints only after `notarytool` status `Accepted` and an issue-free log, `valid on disk` from `codesign --verify --strict --check-notarization`, `Attestation created for 10 subjects`, and 16 dry-run destinations with `latest.txt` last. The 17 secrets exist only in the `release`, `apple-signing`, and `windows-signing` environments, each with `arthjean` as required reviewer and limited to `main`; the repository has no secret, tag, or GitHub Release, `releases.paneflow.dev/agent/latest.txt`, `agent/v0.0.12/`, and `probe/probe.txt` return 404 over valid TLS, and the README cites neither the key nor a verification command. The `actions/attest-build-provenance` pin is the `v4.2.2` commit. Locally, the four signing and publication suites passed 46 tests with one skip (real minisign absent; the run exercised it), with `zig fmt --check src/`, `rebrand.py check`, `zig build`, and `pf.exe --version` and `help`. Left for the go-live checklist: the `release` job pushes the tag before it extracts the changelog and runs `publish-release.sh`, and `CHANGELOG.md` has no `release:start` marker, so a publish dispatch today would push `v0.0.12` and then fail, after which `check-version` reports the tag as released; moving "Extract changelog entry" before "Create git tag" closes it. A rerun after a partial R2 upload fails at `gh release create` because the release exists, which US-016 covers. The `release` job installs Ubuntu's `rclone`, older than the 1.74.3 the probe used.

#### US-004: Validate assumption: R2 serves releases.paneflow.dev with per-object cache control
**Description:** As the maintainer, I want to confirm that an R2 bucket can serve `https://releases.paneflow.dev/` with object-level cache headers so that the updater's host is proven before the pipeline depends on it.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-003

**Acceptance Criteria:**
- [ ] Given a new R2 bucket dedicated to pf releases and a custom domain `releases.paneflow.dev`, when `https://releases.paneflow.dev/probe/probe.txt` is requested, then it returns HTTP 200 with the uploaded content over TLS.
- [ ] Given `rclone copyto` with `--header-upload "Cache-Control: no-cache"`, when `probe/manifest.txt` is uploaded twice with different content, then a request right after the second upload returns the new content.
- [ ] Given a probe archive uploaded with `Cache-Control: public, max-age=31536000, immutable`, when it is requested, then the response carries that header.
- [ ] Given an R2 API token scoped to Object Read & Write on that bucket only, when rclone runs with `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`, then uploads succeed, and a write to any other bucket fails.
- [ ] Given the spike ends, when the bucket is listed, then every `probe/` object is deleted and no object exists under `agent/`, so no client can read a manifest.
- [ ] Given the zone is not on Cloudflare, when the custom domain cannot be attached, then the story records the failure and the fallback host chosen with Arthur in Open Questions, and US-008 and US-011 use that host.
- [ ] Given the findings, when they are recorded in this PRD's Assumptions, then the bucket name, the custom domain, and the token scope are written down, and no secret value is.

**Evidence (2026-10-03):** A probe script run by Arthur with rclone 1.74.3, credentials typed without echo, passed every check against `paneflow-agent-releases`. `https://releases.paneflow.dev/probe/probe.txt` returned 200 over verified TLS with the uploaded content. `probe/manifest.txt`, uploaded twice with `Cache-Control: no-cache` and fetched in between, returned the second content right after the second upload (`cf-cache-status: DYNAMIC`). The probe archive was served with `cache-control: public, max-age=31536000, immutable`. A write to `paneflow-media` was refused. The final listing of the bucket was empty, so no object exists under `probe/` or `agent/`. The custom domain attached, so the fallback host case does not apply.

#### US-005: Sign and notarize macOS binaries with the Paneflow developer identity
**Description:** As the maintainer, I want the macOS signing script to use Paneflow's Developer ID instead of Vercel's so that macOS archives are signed and notarized under an identity I own.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-003

**Acceptance Criteria:**
- [ ] Given `scripts/sign-and-notarize-macos.sh`, when it selects a signing identity, then it uses the Developer ID Application certificate whose team matches the `APPLE_TEAM_ID` secret, and no Vercel identity, team ID, or identifier remains in the script.
- [ ] Given the signing identifier, when a binary is signed, then it is `dev.paneflow.agent` unless Arthur chooses another value in Open Questions.
- [ ] Given the certificate's team does not match `APPLE_TEAM_ID`, when the script runs, then it exits nonzero before signing and names the mismatch.
- [ ] Given notarization, when the script submits the binary, then it keeps the App Store Connect API key method (`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_KEY_P8`) and polls until Apple accepts or rejects it.
- [ ] Given `scripts/tests/test_macos_signing.py` and `scripts/tests/test_signed_macos.py`, when this story lands, then their fixtures use the new identity and identifier, and they pass.
- [ ] Given `scripts/rebrand.py`, when this story lands, then the `com.vercel.fx` protection is removed and `python3 scripts/rebrand.py check` passes.
- [ ] Given a `validate_only` dispatch, when the macOS jobs run, then both macOS binaries pass `codesign --verify --strict` and `notarytool` reports `Accepted` for each in the job log, and nothing is published.

#### US-006: Build and sign pf.exe in the release workflow
**Description:** As the maintainer, I want the release workflow to build a Windows archive with an Authenticode-signed `pf.exe` so that Windows users will get a signed binary without SmartScreen's unknown-publisher warning.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-003

**Acceptance Criteria:**
- [ ] Given `release.yml`, when it runs, then a job on `windows-2025` builds `x86_64-windows-gnu` in ReleaseSafe with `-Dupdate-channel=stable` and packages `pf-windows-x86_64.zip` containing `pf.exe`.
- [ ] Given that job, when it signs, then it runs Paneflow's `sign-windows.ps1` logic against `pf.exe` with the `AZURE_*` secrets, the `strivex-signing` account, and the `StriveX-Release` profile, under a protected GitHub Environment.
- [ ] Given the signed `pf.exe`, when `signtool verify /pa` runs, then it succeeds and the signer subject contains `O=Strivex`.
- [ ] Given the Azure secrets are missing or invalid, when the job runs, then it fails before packaging and no unsigned Windows archive reaches a later job.
- [ ] Given the archive, when its `.sha256` sidecar is generated, then it uses the same format as the Linux and macOS archives.
- [ ] Given a `validate_only` dispatch, when it completes, then the signed Windows archive is available only as a workflow artifact.
- [ ] Given the existing four Full CI runners, when this story lands, then their configuration and shard weights are unchanged.

#### US-007: Sign every release archive with a pf minisign key
**Description:** As a security-conscious adopter, I want every release archive signed with a minisign key dedicated to pf so that I and `pf upgrade` can verify that an archive comes from the pf release pipeline.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-005, US-006

**Acceptance Criteria:**
- [ ] Given a new passwordless minisign key pair for pf, when it is created, then the secret key is stored only as `PF_MINISIGN_SECRET_KEY` in the GitHub Environment `release` and in Arthur's offline backup, and the public key is committed to `src/core/upgrade/release_keys.zig` as the active slot, with an empty next slot.
- [ ] Given a `release.yml` run in `validate_only` or publish mode, when the archives are final, then a signing step in the `release` environment gives each archive a `.minisig` created with the `ED` (BLAKE2b-512 prehashed) algorithm and the trusted comment `file:<archive name> version:<version> channel:stable`.
- [ ] Given the signed archives, when `minisign -V -p <public key> -m <archive>` runs in the job, then every verification succeeds before any publication step starts.
- [ ] Given the secret key is missing, when the signing step runs, then it fails, and in publish mode no tag is created.
- [ ] Given the temporary file holding the secret key, when the step ends, then it is deleted, including when signing fails.
- [ ] Given the README, when this story lands, then it does not yet publish the key or a verification command; the go-live checklist (US-018) adds them.

#### US-008: Publish to R2 and GitHub Releases behind an explicit dispatch
**Description:** As the maintainer, I want the publication steps implemented and tested without publishing so that the first release, when I decide the CLI is ready, needs only a dispatch and an approval.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-004, US-007

**Acceptance Criteria:**
- [ ] Given `scripts/publish-release.sh`, when it publishes a version, then it uploads each archive, `.sha256`, and `.minisig` to `agent/<version>/` with `Cache-Control: public, max-age=31536000, immutable` through `rclone copyto`, uploads `agent/latest.txt` last with `Cache-Control: no-cache`, and its `rclone` and `gh` binaries are injectable the way `PF_SIGNING_CODESIGN_BIN` is in `sign-and-notarize-macos.sh`.
- [ ] Given `scripts/tests/test_publish_release.py` with fake `rclone` and `gh`, when it runs, then it proves the upload order and headers, that a failed artifact upload leaves `latest.txt` untouched and names the file, and that missing R2 credentials fail before any upload; the Full CI step "Test signing and release routing" runs it.
- [ ] Given `release.yml`, when it is read, then it runs only on `workflow_dispatch`, `validate_only` defaults to `true`, the `release` job (tag, GitHub Release, R2 upload) runs only with `validate_only: false` and waits for the `release` environment's required reviewer, and no `blob.vercel-storage.com` or `BLOB_READ_WRITE_TOKEN` reference remains.
- [ ] Given a dispatch with default inputs, when it runs, then it is a `validate_only` run that calls `scripts/publish-release.sh` in dry-run mode, logs every destination path and header, and writes nothing.
- [ ] Given that run ends, when `gh release list` and an R2 listing of `agent/` run, then both are empty and no new tag exists.
- [ ] Given the R2 credentials, when a job reads them, then they come only from the `release` environment.

#### US-009: Attest build provenance for release archives
**Description:** As a security-conscious adopter, I want a GitHub provenance attestation for each release archive so that I can verify where and how it was built independently of the minisign key.

**Priority:** P1
**Size:** XS (1 pt)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] Given a `release.yml` run in `validate_only` or publish mode, when archives are final, then `actions/attest-build-provenance` attests every archive and `.minisig` with `id-token: write` and `attestations: write` granted to that job only.
- [ ] Given a `validate_only` run, when an archive is downloaded from its workflow artifacts, then `gh attestation verify <archive> -R <owner>/pf` succeeds.
- [ ] Given the attestation step fails, when the run continues, then no publication step runs and the summary names the step.
- [ ] Given the README, when this story lands, then it does not yet show the verification command; the go-live checklist (US-018) adds it.

---

### EP-003: Verified self-update (Release 1)

Turn on `pf upgrade` and auto-upgrade against the R2 host, with fail-closed minisign verification and self-replacement on every platform, proven against signed fixtures.

**Definition of Done:** On all five Full CI platforms, `pf upgrade` installs a signed fixture release and refuses tampered, unsigned, mis-labeled, off-host, or older archives, leaving the installed binary intact on every failure, proven by unit tests and end-to-end tests. Against `https://releases.paneflow.dev/agent`, where nothing is published, `pf upgrade` reports that no release is published and auto-upgrade stays silent.

**Evidence (EP-003 review, 2026-10-04):** The implementation is `5045b42` plus a fix to the release archive tests: CI on `1ec254f` ([37205652848](https://github.com/arthjean/pf/actions/runs/37205652848)) failed only `release archive extracts the root binary from tar.gz and zip`, which asserted an executable bit that `std.zip` never writes; the review also made the extractor refuse a tar directory entry named `pf`, which previously passed extraction without writing a binary. On Linux after the final change: `zig build`, `zig fmt --check src/`, 74 focused ReleaseSafe unit tests (minisign, extraction, transfer, install, failure messages, app entry relaunch), a Windows x86_64 cross-build, `rebrand.py check`, and the corpus tests passed; `upgrade-verification.test.ts` passed 8 tests with the Windows ConPTY case skipped, `session-title.test.ts` 7 of 7 and `tui-resume.test.ts` 67 of 67 with a tmux configuration at default `base-index` and the C locale. The 15 MB verification budget test passed in ReleaseSafe on the `ubuntu-24.04` runner of run 37205652848. A copy of `./zig-out/bin/pf` outside `zig-out` reported `{"kind":"upgrade","status":"failed","error":"No pf release is published yet; rebuild from source to update."}` with exit 1 and an unchanged binary, and in an interactive session its auto-upgrade connected to the release host (Cloudflare `188.114.96.2`) and the status line stayed silent. The review also moves a `pf.exe.old` that still runs, such as the parent of a ctrl+g relaunch, aside to `pf.exe.old.<id>` so a later upgrade in the same session succeeds, and the startup sweep removes those leftovers. Arthur confirmed option A for test key injection. Full CI on `20cca58` ([37210723899](https://github.com/arthjean/pf/actions/runs/37210723899)) passed all five `Full suite (...)` jobs: the ReleaseSafe native checks and the four E2E shards on Linux and macOS x86_64 and aarch64, and on `windows-x86_64` the ReleaseSafe unit tests, including the running `pf.exe.old` case, and the Windows E2E subset, where `upgrade-verification.test.ts` passed all 9 tests natively, the ConPTY ctrl+g relaunch among them.

#### US-010: Verify minisign signatures in pf
**Description:** As a pf user, I want pf to verify the minisign signature of a downloaded archive so that only archives signed by pf's release key are installed.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-007

**Acceptance Criteria:**
- [ ] Given `src/core/upgrade/minisign.zig`, when it parses a `.minisig`, then it accepts only the `ED` algorithm, reads the key id, the 64-byte signature, the trusted comment, and the 64-byte global signature, and rejects any other layout.
- [ ] Given a signature and archive, when verification runs, then it checks the key id against the active and next public keys in `release_keys.zig`, verifies Ed25519 over BLAKE2b-512 of the archive streamed from disk, and verifies the global signature over the signature and trusted comment.
- [ ] Given the trusted comment, when verification runs, then the archive file name, version, and channel it names must equal the expected values, or verification fails.
- [ ] Given a tampered archive, a tampered trusted comment, a signature from an unknown key, a legacy `Ed` signature, or a truncated file, when verification runs, then each fails with a distinct error and a unit test covers each case.
- [ ] Given a 15 MB archive, when verification runs in ReleaseSafe, then it completes in under 500 ms on the CI Linux runner.
- [ ] Given the implementation, when its imports are read, then it uses only `std.crypto` and `std.base64`.

#### US-011: Fetch upgrades only from the release host
**Description:** As a pf user, I want `pf upgrade` to use the release host and nothing else so that a redirect or misconfiguration cannot make pf install a binary from another server.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-004, US-010

**Acceptance Criteria:**
- [ ] Given `upgrade_helpers.zig`, when this story lands, then `cdn_base` is `https://releases.paneflow.dev/agent`, and the loopback `PF_E2E_UPGRADE_BASE_URL` override keeps its current validation.
- [ ] Given an HTTP response that redirects to any other host, when pf fetches a manifest or archive, then it refuses the redirect and reports that the release host redirected to an unexpected location.
- [ ] Given a download, when it completes, then pf verifies the SHA-256 sidecar and then the minisign signature from `<archive>.minisig`, and installs only when both pass.
- [ ] Given the signature is missing or invalid, when `pf upgrade` runs, then it exits nonzero with a message that it refused an unverified release, the installed binary is unchanged, and `--json` reports `status: failed` with the error.
- [ ] Given `latest.txt` returns 404 because nothing is published, when `pf upgrade` runs, then it reports that no pf release is published yet, and when auto-upgrade checks, then it shows nothing and retries at the next 30-minute interval.
- [ ] Given `latest.txt` names a version older than or equal to the running one, when `pf upgrade` runs on the stable channel, then it reports `up_to_date` and downloads nothing.
- [ ] Given `NOTICE`, when this story lands, then its upgrade line states that pf upgrades only from its own signed release channel, which publishes no release yet, and Vercel's attribution is unchanged.

#### US-012: Extract release archives in-process
**Description:** As a pf user, I want pf to unpack release archives itself so that upgrades do not depend on an external `tar` and work the same on every platform.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Given a `.tar.gz` archive, when pf extracts it, then it uses `std.compress.flate` and `std.tar` and no child process is spawned.
- [ ] Given a `.zip` archive, when pf extracts it, then it uses `std.zip` and no child process is spawned.
- [ ] Given an archive entry with an absolute path, a `..` component, or a link, when pf extracts it, then extraction fails and nothing is written outside the temporary directory.
- [ ] Given an archive that does not contain exactly one `pf` or `pf.exe` executable at its root, when pf extracts it, then it fails with an invalid archive error.
- [ ] Given an archive larger than 100 MB uncompressed, when pf extracts it, then it stops and reports the limit.
- [ ] Given the previous `tar -xzf` call, when this story lands, then it is removed and unit tests cover both formats.

#### US-013: Replace the running binary on Windows
**Description:** As a Windows user, I want `pf upgrade` and auto-upgrade to replace `pf.exe` safely so that Windows gets the same verified updates as Linux and macOS.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-011, US-012

**Acceptance Criteria:**
- [ ] Given Windows x86_64, when pf resolves its platform, then it is `windows-x86_64` and the archive is `pf-windows-x86_64.zip`.
- [ ] Given a verified new `pf.exe`, when pf installs it, then it renames the running `pf.exe` to `pf.exe.old`, moves the new file into place, and on failure of the move renames `pf.exe.old` back.
- [ ] Given a `pf.exe.old` next to the binary, when pf starts, then it deletes it, and a failure to delete is ignored and retried on the next start.
- [ ] Given the binary directory is not writable, such as `C:\Program Files`, when pf upgrades, then it fails before downloading with a message naming the directory and suggesting a user-writable install location.
- [ ] Given auto-upgrade installs a release during an interactive session on Windows, when the user accepts the reload with Ctrl+G, then pf relaunches the new `pf.exe` with `resume <session-id> --upgrade-relaunch`, as it does on POSIX.
- [ ] Given the README Windows section, when this story lands, then it still lists release downloads and `pf upgrade` as unavailable, and the go-live checklist (US-018) carries the README text that removes them and documents the `pf.exe.old` recovery.

#### US-014: Prove the upgrade path end to end with signed fixtures
**Description:** As the maintainer, I want the end-to-end upgrade fixtures signed and the refusal paths tested so that the whole verified update path runs on every Full CI run.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-011, US-012, US-013

**Acceptance Criteria:**
- [ ] Given `startUpgradeServer` (`tests/e2e/tmux-helpers.ts:96`), when it builds its fixture release, then it signs each archive with a test-only minisign key generated per run, serves `<archive>.minisig`, and pf trusts that key only for the loopback `PF_E2E_UPGRADE_BASE_URL` origin, never for `https://releases.paneflow.dev` (mechanism in Technical Considerations).
- [ ] Given the existing upgrade tests in `tests/e2e/tui-resume.test.ts` and `tests/e2e/session-title.test.ts`, when they run against the signed fixtures, then they pass unchanged in intent.
- [ ] Given a new `tests/e2e/upgrade-verification.test.ts` and fixtures with a bad signature, a mismatched trusted-comment version, an older version, and an off-host redirect, when `pf upgrade --json` runs against a copy of the built binary for each, then it fails or reports `up_to_date` as specified in US-011, and the copied binary is byte-identical afterward.
- [ ] Given the new file, when the corpus check runs, then it has exactly one classification in `scripts/pgso/corpus.json` as verification-only, and it appears in `tests/e2e/ci-shard-weights.json`.
- [ ] Given the Windows E2E subset, when this story lands, then `upgrade-verification.test.ts` is in `WINDOWS_E2E_FILES` and passes natively.

---

### EP-004: Release tooling and documentation (Release 1)

Make releases cost $0 to prepare, make R2 rebuildable from GitHub Releases, document the pipeline, and write the go-live checklist that Arthur runs when the CLI is ready.

**Definition of Done:** A release PR can be prepared without the AI Gateway, `cdn-backfill.yml` restores R2 from GitHub Releases in tests and dry runs, CONTRIBUTING, AGENTS.md, and the Windows PRD describe the built pipeline without claiming releases exist, and the go-live checklist lists every remaining step; no release has been published.

**Status (2026-10-04):** US-015 to US-018 are implemented and merged to `main` at `cc788f2`. `prepare-release.yml` takes a `changelog` input (`manual` by default, `ai` opt-in guarded by a first step that names the missing `AI_GATEWAY_API_KEY`), and the `release` job of `release.yml` refuses the `<!-- release:placeholder -->` entry before **Create git tag**. `cdn-backfill.yml` runs `scripts/backfill-release.sh` in the `release` environment, dry run by default; the script verifies every `.minisig` and trusted comment against both key slots and uploads through `scripts/publish-release.sh --r2-only [--no-latest]`. CONTRIBUTING (Releases and the Go-live checklist), the AGENTS.md Releasing section, README, the Windows PRD Q1, and the `releases.fx.sh` rule in `scripts/rebrand.py` are updated. Exercising Prepare Release exposed two defects inherited from fx, both fixed with regression tests: `jq --arg` received the base64 of `src/main.zig` and failed with "Argument list too long", and `gh pr create` without `--head` proposed the dispatch branch instead of `prepare-vX.Y.Z`. The repository setting that lets GitHub Actions create pull requests was enabled; default workflow permissions stay read-only.

**Evidence (2026-10-04):** Prepare Release with `changelog: ai` and no secret failed at its first step without creating a branch (run 37216685054). With `changelog: manual` it bumped `src/main.zig` to 0.0.13, inserted the placeholder entry in a verified commit, and opened PR #2 from `prepare-v0.0.13` (run 37217108250); PR #2 and the misdirected PR #1 were closed unmerged and the branch deleted. A default dispatch of `cdn-backfill.yml` on `main`, approved in `release`, reported "No GitHub Release exists; nothing to backfill." (run 37225247645). Locally, the backfill was also run with the real `minisign`, which accepted a valid release and refused a relabeled archive. `gh release list` and `git ls-remote --tags origin` return nothing, `https://releases.paneflow.dev/agent/latest.txt` returns 404, and Arthur's `rclone lsf -R` of the whole bucket returned no object. A default dispatch of `release.yml` on `main` ran as `validate_only` (run 37225249823): it built, notarized, and signed all five targets, minisigned and verified each archive with the trusted comment `file:<archive> version:v0.0.12 channel:stable`, attested provenance, and dry-ran the publication of 15 assets and `latest.txt`, while the `release` job was skipped; its macOS arm64 PGSO lane needed two reruns because the `ui-activity` timing gate tripped on runner noise, once on the external control binary. Afterward no release, tag, or `latest.txt` existed. Full CI run 37217107666 passed on Linux and macOS, where the release script tests run; its Windows job failed on unit tests unrelated to this epic and flaky on unchanged source (`browser_callback` reset preconnect, MCP discovery stall).

**Evidence (EP-004 review, 2026-10-04):** The epic is `59aa7a4..9dcbecb` and changes no Zig source; `CI` on `9dcbecb` ([37230820134](https://github.com/arthjean/pf/actions/runs/37230820134)) passed `zig fmt --check src/`, the ReleaseSafe build and unit tests, the deterministic E2E suites, and Shellcheck, which covers `scripts/backfill-release.sh`. Every criterion traces from a dispatch entry point: `prepare-release.yml` (`changelog` input, AI key guard first, placeholder step), the `release` job of `release.yml` (placeholder refusal before **Create git tag**), and `cdn-backfill.yml`, which runs `scripts/backfill-release.sh` and through it `scripts/publish-release.sh --r2-only [--no-latest]`; `full-ci.yml` runs `test_prepare_release` with the other release suites. On Ubuntu 26.04 under WSL, `test_publish_release`, `test_prepare_release`, and `test_sign_release_archives` passed 38 tests. With the real `minisign` 0.12, a dry-run backfill of two signed fake releases listed the 15 uploads of `v0.1.0`, refused `v0.2.0` whose Linux archive and signature were relabeled from `v0.1.0` ("belongs to a different release"), left `latest.txt` out because the newest release failed, and exited 1. The CI and PGSO failures on PR #2 came from closing the PR and deleting its branch 29 seconds after creation, not from the workflow. US-015's AI path was not run with a key, which would call the paid Gateway: its steps are byte-identical to `028cbd9` apart from the added `if: inputs.changelog == 'ai'` guards, and the `jq --rawfile` commit payload both modes share was exercised by run 37217108250. US-018's empty R2 rests on Arthur's `rclone lsf -R`; only `CI`, `Benchmarks`, the `validate_only` Release run, and the dry-run backfill ran afterward, and on review `gh release list` and `git ls-remote --tags origin` returned nothing and `latest.txt` returned 404. The review recorded the CDN backfill and the optional AI changelog in `NOTICE`. Not applied: the backfill uploads each `.sha256` without checking it against its archive, so a corrupted sidecar in a GitHub Release would reach R2 and `pf upgrade` would refuse that version (fail-closed); the minisign check already covers authenticity. Full CI on `cc788f2` failed only on Windows unit tests that the epic does not touch.

#### US-015: Make the AI changelog draft optional
**Description:** As the maintainer, I want Prepare Release to work without the Vercel AI Gateway so that preparing a release costs nothing unless I opt into an AI draft.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Given `prepare-release.yml`, when it is dispatched, then a `changelog` input offers `manual` (default) and `ai`.
- [ ] Given `manual`, when the workflow runs, then it bumps `src/main.zig`, inserts a `## <version>` entry with release markers and a placeholder body, and opens the PR, with no request to the AI Gateway.
- [ ] Given `ai` and no `AI_GATEWAY_API_KEY` secret, when the workflow runs, then it fails before any branch is created and names the missing secret.
- [ ] Given `ai` with a valid key, when the workflow runs, then the existing draft, policy lint, and PR steps behave as today.
- [ ] Given `release.yml` in publish mode, when the changelog body still holds the placeholder, then the release job fails before creating the tag and names the placeholder.
- [ ] Given this story's verification, when the workflow is exercised, then its PR is closed unmerged or merged only while `release.yml` is dispatch-only, so nothing is published.

#### US-016: Backfill R2 from GitHub Releases
**Description:** As the maintainer, I want `cdn-backfill.yml` to restore R2 from GitHub Releases so that a lost or corrupted bucket can be rebuilt from the canonical release assets once releases exist.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] Given `cdn-backfill.yml`, when it uploads, then it calls `scripts/publish-release.sh` with the same paths and headers as US-008, and no Vercel Blob reference remains.
- [ ] Given a version, when it backfills, then it uploads the archive, `.sha256`, and `.minisig` and verifies each `.minisig` against the committed public key before upload, proven in `scripts/tests/test_publish_release.py` with fake releases.
- [ ] Given the `dry-run` input, when the workflow is dispatched, then it defaults to `true`, lists the uploads it would make, and writes nothing.
- [ ] Given a release whose `.minisig` fails verification, when the backfill runs, then it skips that release, reports it, and exits nonzero at the end.
- [ ] Given `latest.txt`, when the backfill targets the newest release, then it updates `latest.txt` only when `update-latest` is true and that release passed verification.
- [ ] Given no GitHub Release exists, when the workflow is dispatched, then it reports that there is nothing to backfill and writes nothing.

#### US-017: Document the release pipeline
**Description:** As a contributor, I want the docs to describe the pipeline that is built, without claiming releases exist, so that the documented process matches the repository.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-008, US-013

**Acceptance Criteria:**
- [ ] Given CONTRIBUTING.md and the AGENTS.md Releasing section, when they are read, then they describe Prepare Release, the dispatch-only triggers and dry-run defaults, the protected environments, R2, minisign and key rotation through the next slot, and Apple and Azure signing, and mention no Vercel infrastructure as current.
- [ ] Given README.md, when it is read, then it still states that Paneflow Agent does not publish releases yet, and no section explains downloading or verifying a release.
- [ ] Given `tasks/prd-windows-native-support.md`, when this story lands, then Open Question Q1 records the decision (GitHub Releases and R2, `pf upgrade`, no install script or package manager, first release at Arthur's go decision).
- [ ] Given `scripts/rebrand.py`, when this story lands, then the rule that maps `releases.fx.sh` maps it to `releases.paneflow.dev/agent`, and `python3 scripts/rebrand.py check` passes.
- [ ] Given a feature not shipped, such as install scripts or package managers, when the docs mention it, then they list it as unavailable.

#### US-018: Write the go-live checklist for the first release
**Description:** As the maintainer, I want a written checklist of every step that turns the proven pipeline into a published release so that I can ship the first release in one session when the CLI is ready.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-009, US-014, US-015, US-016, US-017

**Acceptance Criteria:**
- [ ] Given CONTRIBUTING.md, when it is read, then a "Go-live checklist" section lists, each with the file it changes: running Prepare Release and editing the changelog; dispatching `release.yml` with `validate_only: false` and approving the `release` environment; the README install and verification sections with the minisign public key and the `minisign -V` and `gh attestation verify` commands; removing release downloads and `pf upgrade` from the README Windows list and adding the `pf.exe.old` recovery note; upgrading from a previous build on Linux, macOS, and Windows; deciding whether `release.yml` returns to a push trigger; restoring the automatic `dev-release.yml` trigger; and the first `libpf` publish if US-020 ships it.
- [ ] Given each checklist step, when it is read, then it names its rollback, and a bad release is superseded by a higher version, never by moving `latest.txt` backward.
- [ ] Given the end of this PRD's implementation, when `gh release list`, `git ls-remote --tags origin`, and an R2 listing of `agent/` run, then no release, no release tag, and no object exist.
- [ ] Given a dispatch of `release.yml` with default inputs, when it runs, then it is a `validate_only` run and publishes nothing.

---

### EP-005: Dev channel and JavaScript SDK (Release 2)

Prepare signed dev builds as dry runs, and settle whether `libpf` ships.

**Definition of Done:** A `dry_run` dispatch of `dev-release.yml` builds and minisigns all five dev archives and logs its planned uploads without writing, its publication and retention logic pass `scripts/tests/test_publish_release.py`, `pf upgrade --channel dev` refuses mis-labeled dev archives in unit tests, and `libpf` is either configured for a later first publish or its workflow and examples are retired; nothing is published.

#### US-019: Prepare signed dev builds for R2 with retention
**Description:** As the maintainer, I want the dev channel pipeline built and proven as a dry run so that restoring its automatic trigger at go-live publishes verified dev builds.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008, US-013

**Acceptance Criteria:**
- [ ] Given `dev-release.yml`, when it is read, then it runs only on `workflow_dispatch` with a `dry_run` input that defaults to `true`, and its comment states that the automatic trigger after `CI` returns through the go-live checklist.
- [ ] Given a dispatch with `dry_run: true`, when it runs, then it builds all five platforms with `-Dupdate-channel=dev`, signs each archive with minisign using the trusted comment `file:<archive name> version:<version> channel:dev commit:<sha>`, verifies each signature, logs the planned uploads to `agent/dev/<commit>/` and `agent/dev.json`, and writes nothing.
- [ ] Given `scripts/publish-release.sh` in dev mode and its tests, when they run, then `dev.json` is uploaded last with `Cache-Control: no-cache` only when `main` still points at the commit, and retention deletes the oldest builds beyond 30, never the one `dev.json` names.
- [ ] Given dev builds, when they are produced, then they are not Apple- or Azure-signed, and CONTRIBUTING states it.
- [ ] Given the WASM web package and `PF_WEB_DEPLOY_HOOK_URL`, when this story lands, then they are removed from the workflow.
- [ ] Given `pf upgrade --channel dev` with a dev archive whose trusted comment names another commit, when it runs in a unit test, then pf refuses it.

#### US-020: Validate assumption: libpf ships as a pf product
**Description:** As the maintainer, I want a decision on the JavaScript SDK so that `publish-libpf.yml` and the examples either work at go-live or are retired.

**Priority:** P2
**Size:** S (2 pts)
**Dependencies:** Blocked by US-003

**Acceptance Criteria:**
- [ ] Given the npm name `libpf`, when Arthur decides, then the decision to reserve it or not is recorded with the reason; no SDK code is published by this PRD.
- [ ] Given the decision to ship, when this story lands, then `sdk/package.json` points to the pf repository, npm trusted publishing is configured for `publish-libpf.yml` with the `npm` environment, the version restarts at `0.1.0`, and the workflow stays dispatch-only until the go-live checklist.
- [ ] Given the decision not to ship, when this story lands, then `publish-libpf.yml` is removed and the README states that the SDK is not distributed.
- [ ] Given either decision, when this PRD is updated, then Open Questions records it with the date.

#### US-021: Repair or retire the SDK examples
**Description:** As a contributor, I want the `examples/` directory to install and build so that `examples.yml` passes on pull requests that touch it.

**Priority:** P2
**Size:** S (2 pts)
**Dependencies:** Blocked by US-020

**Acceptance Criteria:**
- [ ] Given `libpf` ships, when the examples install, then they depend on the local `sdk/` package through a `file:` dependency until its first publish, and their lockfiles install.
- [ ] Given `libpf` does not ship, when this story lands, then the examples and `examples.yml` are removed and README links to them are deleted.
- [ ] Given a pull request touching `examples/`, when `examples.yml` runs, then it passes, or the workflow no longer exists.
- [ ] Given an example lockfile referencing a version that does not exist on npm, when `npm ci` runs, then the failure is reproduced before the fix and absent after it.

## Functional Requirements

- FR-01: No workflow may create a tag, a GitHub Release, an npm version, or an R2 object under `agent/` without a manual dispatch that explicitly disables its dry run and, for releases, an approval in the `release` environment. Automatic triggers return only through the go-live checklist.
- FR-02: The release pipeline must produce `pf-linux-x86_64.tar.gz`, `pf-linux-aarch64.tar.gz`, `pf-macos-x86_64.tar.gz`, `pf-macos-aarch64.tar.gz`, and `pf-windows-x86_64.zip`, each with a `.sha256` and a `.minisig`, in both `validate_only` and publish modes.
- FR-03: macOS binaries must be signed with a Developer ID Application certificate of the team named by `APPLE_TEAM_ID` and notarized; `pf.exe` must be signed with Azure Artifact Signing under `O=Strivex`.
- FR-04: Every `.minisig` must use the `ED` algorithm and carry the trusted comment `file:<name> version:<version> channel:<channel>` (dev adds `commit:<sha>`).
- FR-05: The publication must upload `latest.txt` or `dev.json` only after every artifact of that release uploaded successfully.
- FR-06: `pf upgrade` and auto-upgrade must fetch only from `https://releases.paneflow.dev/agent` (or the validated loopback test origin) and must refuse redirects to any other host.
- FR-07: pf must install an archive only after the SHA-256 sidecar and the minisign signature both verify against an embedded public key, and the trusted comment matches the expected file, version, and channel.
- FR-08: On the stable channel, pf must not install a version lower than or equal to the running version.
- FR-09: pf must extract archives in-process and must reject entries that escape the extraction directory.
- FR-10: On Windows, pf must replace a running `pf.exe` by renaming it aside and must restore it if the replacement fails.
- FR-11: The system must NOT read the GitHub Releases API from the updater.
- FR-12: Signing keys, R2 credentials, and Azure and Apple secrets must be readable only by jobs that run in a protected GitHub Environment.
- FR-13: When no release is published, `pf upgrade` must report it and auto-upgrade must stay silent.

## Non-Functional Requirements

- **Performance:** Minisign verification of a 15 MB archive completes in under 500 ms in ReleaseSafe on the CI Linux runner; a full `pf upgrade` of a fixture release on a 50 Mbit/s connection completes in under 30 s; the manifest check adds no work to the `pf help` startup path (2 ms Linux CI budget unchanged).
- **Security:** 0 accepted archives in tests for each of: tampered bytes, tampered trusted comment, unknown key, legacy `Ed` algorithm, version mismatch, off-host redirect; secrets reachable by 0 jobs triggered by `pull_request` or by forks; the minisign secret key exists in exactly 2 places (the `release` environment and Arthur's offline backup); 0 objects under `agent/` in R2 and 0 GitHub Releases before the go decision.
- **Cost:** $0 added per month, with R2 usage at or under 10 GB stored and 10 million reads per month and dev retention capped at 30 builds.
- **Scalability:** After go-live, the R2 free tier serves the 30-minute auto-upgrade check for up to 7,000 active installations (48 manifest reads per installation per day).
- **Reliability:** A failed upgrade leaves the installed binary byte-identical in 100% of tested failure cases; an R2 outage makes `pf upgrade` fail with a network error within the existing 30 s no-progress watchdog and never corrupts the binary; a failed publication leaves `latest.txt` unchanged in 100% of `test_publish_release.py` failure cases.
- **Pipeline duration:** A `validate_only` run of `release.yml` completes within 90 minutes, excluding Apple notarization queue time over 30 minutes.

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | No release published yet | `latest.txt` returns 404 | `pf upgrade` fails without touching the binary; auto-upgrade shows nothing | "No pf release is published yet; rebuild from source to update." |
| 2 | Invalid signature | `.minisig` does not verify | Refuse, delete the download, keep the binary | "Refused to install pf <version>: its signature is invalid." |
| 3 | Unknown signing key | Key id matches neither slot | Refuse | "Refused to install pf <version>: it is signed by an unknown key. Download pf from its release page." |
| 4 | Relabeled archive | Trusted comment names another version, file, channel, or commit | Refuse | "Refused to install pf <version>: the signature belongs to a different release." |
| 5 | Older manifest | `latest.txt` is lower than or equal to the running version | Report up to date, download nothing | "pf <version> is up to date." |
| 6 | Off-host redirect | Release host redirects elsewhere | Refuse the request | "The pf release host redirected to an unexpected location; update refused." |
| 7 | Stalled download | No bytes for 30 s | Abort, delete the temporary directory | "Download stalled; try again later." |
| 8 | Read-only install directory | Binary in `C:\Program Files` or `/usr/local/bin` without permission | Fail before downloading | "Cannot write to <dir>; reinstall pf in a user-writable directory or rerun with permission." |
| 9 | Interrupted Windows replacement | Process killed between rename and move | `pf.exe.old` remains; the go-live README text documents recovery | None at runtime; README recovery note after go-live |
| 10 | Concurrent upgrades | Two pf processes upgrade at once | Each installs through an atomic rename; the result is one valid binary | None |
| 11 | Stale manifest at the edge | Cloudflare caches `latest.txt` | `Cache-Control: no-cache` forces revalidation | None |
| 12 | Partial publication | An R2 upload fails mid-release | `latest.txt` is not updated; the summary names the file | Job summary: "Upload failed: <file>; latest.txt unchanged." |
| 13 | Missing signing secret | An Apple, Azure, or minisign secret is unset | The job fails before any publication step | Job log names the missing secret |
| 14 | Malicious archive entry | Archive contains `../` or a link | Extraction fails, nothing written outside the temporary directory | "Refused to install pf <version>: the archive is invalid." |
| 15 | Accidental release dispatch | `release.yml` or `dev-release.yml` dispatched with default inputs | Runs as a dry run and publishes nothing | Job summary lists the planned uploads as a dry run |
| 16 | Leftover spike objects | Probe objects remain in R2 after US-004 | No object exists under `agent/`, so no client reads them; US-004 deletes them | None |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | A release is published before the CLI is ready | Low | High | Dispatch-only triggers, dry-run defaults, `release` environment approval, and automatic triggers restored only by the go-live checklist (US-001, US-008, US-018) |
| 2 | Signing or R2 secrets exfiltrated through a pull request or modified workflow | Low | High | Secrets live only in protected Environments with Arthur as required reviewer; no secret in `pull_request` workflows; R2 token scoped to one bucket (US-004, US-008) |
| 3 | Release host compromised and serves a malicious archive | Low | High | Fail-closed minisign verification bound to file, version, and channel (US-010, US-011); worst case is a frozen update |
| 4 | minisign secret key lost or leaked | Low | High | Offline backup; empty next slot ready for rotation; rotation documented in CONTRIBUTING (US-007, US-017) |
| 5 | The publication path that dry runs cannot reach fails at go-live | Medium | Medium | Upload logic in `scripts/publish-release.sh` tested with fake `rclone` and `gh`; the go-live checklist names each step's rollback; `latest.txt` is written last |
| 6 | Future fx ports conflict with adapted workflows and scripts | Medium | Medium | Parameterize identity and hosts instead of rewriting; keep step structure; record divergences in `scripts/rebrand.py` |
| 7 | The `paneflow.dev` zone is not on Cloudflare | Low | Medium | Spike US-004 proves the custom domain before dependent stories; fallback host decided with Arthur |
| 8 | Windows rename-aside fails under antivirus locks | Medium | Medium | Restore `pf.exe.old` on failure; documented recovery; end-to-end coverage on Windows (US-013, US-014) |
| 9 | macOS PGSO qualification or notarization delays block a `validate_only` run | Medium | Low | The run retries notarization polling within its timeout; delays never publish anything |
| 10 | Freeze attack keeps users on an old version after go-live | Low | Low | Accepted: impact limited to missing updates; revisit with a signed, timestamped manifest if needed |
| 11 | Azure Basic tier signature quota exceeded | Low | Low | pf signs one binary per `release.yml` run and no dev builds |

## Non-Goals

What this version explicitly does NOT include:

- Publishing any release (stable, dev, or npm) or restoring automatic release triggers: deferred until Arthur decides the CLI is ready; US-018 writes the checklist that does it.
- Install scripts (`curl | sh`, `irm | iex`): deferred until after the first signed releases.
- Package managers (winget, Homebrew, Scoop): deferred to a later PRD once releases are signed and stable.
- Apple or Azure signing of dev builds: dev builds carry minisign signatures only.
- A TUF-style signed, timestamped manifest that detects freeze attacks: the risk is accepted.
- `pf upgrade --version` pinning and explicit downgrades.
- Self-update disabling for package-manager installs: no package manager ships in this PRD.
- Any change to the four Linux and macOS Full CI runners or their shard weights.

## Files NOT to Modify

- `src/core/permissions/`: permission policy is unrelated to distribution and security-critical.
- `src/gateway/` and `src/core/gateway/`: provider transport.
- `src/core/terminal/engine.zig`: shared terminal engine.
- `src/main.zig` beyond composition wiring.
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, and Vercel's copyright and attribution in `NOTICE`.
- `.github/workflows/full-ci.yml` matrix entries and `tests/e2e/ci-shard-weights.json` weights of existing files.
- The `scripts/rebrand.py` protections for the Slack bridge on `fx.sh`, `vercel-labs/fx` attribution links, and binary format magics.

## Technical Considerations

Frame as questions for engineering input, not mandates:

- **Architecture:** Should minisign verification live in a new `src/core/upgrade/minisign.zig` with the keys in `release_keys.zig`? Recommended: yes, keeping `upgrade_helpers.zig` focused on transfer. Engineering to confirm the boundary.
- **Publication script:** Should the upload logic shared by `release.yml`, `cdn-backfill.yml`, and `dev-release.yml` live in `scripts/publish-release.sh` with injectable `rclone` and `gh`, tested like `sign-and-notarize-macos.sh`? Recommended: yes, because it is the only way to prove upload order and failure handling before anything is published, and it replaces three inline upload blocks with one.
- **Redirect policy:** Does `std.http.Client` in Zig 0.16 expose redirect handling that lets pf reject off-host redirects, or should pf disable automatic redirects and follow same-host redirects itself? Recommended: disable and follow only same-host redirects.
- **Archive formats:** Keep `.tar.gz` for Linux and macOS, which matches the existing artifact contract (`upgrade_runtime.zig:221`), and `.zip` for Windows, which is the platform convention. Trade-off: two extractors versus one; both are in `std`.
- **Test key injection:** How should the end-to-end fixtures make pf trust a test-only key? Option A: an environment variable honored only together with the loopback `PF_E2E_UPGRADE_BASE_URL` override, which release builds already accept; whoever controls pf's environment can already run code as the user, so the trust boundary does not move, and Full CI keeps testing the same binary it ships. Option B: a build option that only test builds enable, which removes the path from release binaries but makes the end-to-end suite test a different binary. Recommended: A. Engineering and Arthur to confirm, since it touches `pf upgrade`.
- **Workflow structure:** Should the Windows build and Azure signing be a new job in `release.yml` mirroring the macOS jobs, or a reusable workflow? Recommended: a job, to keep the release graph in one file like fx.
- **Dependencies:** No new Zig dependency. CI adds `rclone`, `minisign`, and `actions/attest-build-provenance`, all free; Paneflow's `sign-windows.ps1` is copied with its pinned Azure dlib checksum.
- **Migration:** No user data migration. Rollback for a bad release after go-live: publish a fixed higher version; `latest.txt` never points backward because stable refuses downgrades.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Failing workflow runs per push to `main` | 3 (release, dev-release, publish-libpf would run and fail) | 0 | Month-1 | GitHub Actions history |
| Releases, tags, npm versions, or R2 objects under `agent/` before the go decision | 0 | 0 | Until Arthur's go decision | `gh release list`, `git ls-remote --tags origin`, npm registry, R2 listing |
| `validate_only` archives with valid `.minisig` and attestation | 0% (no pipeline) | 100% | Month-1 | `minisign -V` and `gh attestation verify` in `validate_only` job logs |
| Full CI platforms where the upgrade end-to-end tests pass | 0 of 5 | 5 of 5 | Month-1 | `upgrade-verification.test.ts` and the existing upgrade tests in Full CI |
| Monthly added cost | $0 | $0 | Month-6 | Cloudflare R2 and GitHub billing pages |
| `validate_only` run duration | N/A (new) | Under 90 minutes | Month-1 | Workflow run durations |

## Open Questions

- **Release host (Arthur, before US-004):** This PRD uses `https://releases.paneflow.dev/agent` instead of `paneflow.dev/agent/releases`, because `paneflow.dev` is served by Vercel and a path under it would route release traffic through Vercel. Confirm the subdomain, or choose another Cloudflare host.
- **macOS signing identifier (Arthur, before US-005):** `dev.paneflow.agent` is proposed. Confirm or choose another identifier.
- **AI changelog (Arthur, after US-015):** Keep `ai` as an opt-in with a personal AI Gateway key, or remove it entirely.
- **libpf (Arthur, US-020):** Ship the JavaScript SDK under the `libpf` npm name, or retire `publish-libpf.yml` and the examples.
- **Go decision (Arthur, after US-018):** when the CLI is ready, run the go-live checklist.
- **Decided (Arthur, 2026-10-04):** test key injection uses option A: `PF_E2E_UPGRADE_PUBLIC_KEY` is honored only together with a loopback `PF_E2E_UPGRADE_BASE_URL`, so Full CI tests the binary it ships.
- **Decided (Arthur, 2026-10-02):** public repository; Cloudflare R2 instead of Vercel Blob; Paneflow's Apple Developer ID and Azure Artifact Signing account reused with no added cost; a minisign key dedicated to pf; distribution workflows adapted rather than deleted; no release published until Arthur decides the CLI is ready.
[/PRD]
