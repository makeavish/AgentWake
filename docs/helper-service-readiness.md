# Helper Service Readiness

Check date: May 13, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#27](https://github.com/makeavish/ClawShell/issues/27)

Local readiness artifact: `.build/helper-service-readiness/recheck-20260512T105510Z`

Latest SMAppService register artifact:
`.build/helper-service-prototype/smappservice-register-stdout-20260513T040749Z`

## Question

Is `SMAppService` a source-backed helper path worth trying before ClawShell proves a no-membership Bag Mode helper install/update/uninstall path?

## Source Findings

Apple's Service Management docs and sample establish the intended modern shape:

- `SMAppService` controls helper executables that live inside an app's main bundle.
- `SMAppService.daemon(plistName:)` expects the LaunchDaemon plist in the calling app's `Contents/Library/LaunchDaemons` directory.
- `register()` registers the service so it can launch subject to user approval.
- For a LaunchDaemon, registration alone is not enough: the system does not bootstrap it until an admin approves it in System Settings.
- `unregister()` unregisters the service, and for LoginItems, LaunchAgents, and LaunchDaemons the system terminates a running service.
- Apple's package-installer sample keeps `launchd` property lists in the signed app bundle rather than shared `/Library/LaunchDaemons`, so tampering breaks the code signature and users can see the providing app in System Settings.

Sources:

- [SMAppService register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
- [SMAppService daemon(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon%28plistname%3A%29)
- [SMAppService unregister()](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister%28%29)
- [Updating your app package installer to use the new Service Management API](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)

## Local Readiness Check

Command used:

```bash
scripts/helper-service-readiness.sh --output-dir .build/helper-service-readiness/recheck-20260512T105510Z
```

Captured result:

```text
validCodeSigningIdentityCount=0
developerIDApplicationIdentityCount=0
developerIDInstallerIdentityCount=0
appleDevelopmentIdentityCount=0
appleDistributionIdentityCount=0
xcodeDeveloperDirSource=applications
xcodebuildActiveAvailable=false
xcodebuildDiscoveredAvailable=true
xcodebuildAvailable=true
pkgbuildAvailable=true
productbuildAvailable=true
macosSdkAvailable=true
codesignAvailable=true
notarytoolAvailable=true
signedPrototypeReady=false
metadataRedacted=true
```

The local environment now has full Xcode installed under `/Applications/Xcode.app`, even though the active `xcode-select` developer directory still points at Command Line Tools. The readiness harness detects that installed Xcode separately from the active selection and records `xcodebuildAvailable=true`.

This still is not enough to complete a Developer ID signed prototype: the keychain has no Developer ID Application identity and no Developer ID Installer identity. The harness records only redacted identity counts: app-signing identities come from the `codesigning` policy, while installer identities come from a separate `basic` identity query.

The product plan now treats Apple Developer Program membership as deferred until traction or donations justify the cost, so #27 must first prove a no-membership helper path instead of waiting on Developer ID identities.

## Provisional Design Verdict

`SMAppService` remains the source-backed first target to prototype, and the
latest no-membership helper artifact moved past the earlier approval-pending
state. The fresh ad-hoc helper reached `enabled`, launchd submitted the
ServiceManagement daemon, readable stdout captured a root-owned dry-run ledger
sample, and a later unregister capture removed the service. That proves the
local SMAppService root bootstrap and unregister path is viable on this machine,
but #7 still cannot claim the helper path is complete: #27 still needs the
approved fixed-command API row, admin-approval/password-flow evidence,
post-approval status/bootstrap/log/launchctl row promotion, root-ledger
schema/ownership promotion, reboot, update, repair, CLI, failure-case, and
helper-owned Bag Mode state cleanup evidence before production Bag Mode can
depend on it.

The design should keep these constraints:

- App bundle contains the helper and LaunchDaemon plist.
- LaunchDaemon plist lives under `Contents/Library/LaunchDaemons`.
- App and helper use the strongest available local signing/auth model; Developer ID designated requirements are a later distribution upgrade.
- Registration is app-initiated after Bag Mode consent.
- LaunchDaemon approval is admin-mediated in System Settings.
- Non-Developer-ID public builds may expose Bag Mode only after the local/ad-hoc signed and hash/pairing-pinned helper path passes real validation and the UI clearly labels the local helper trust model. Truly unsigned helper experiments stay development-only.
- A Homebrew cask may install the app bundle containing the helper and plist, but it must not silently activate the helper. Onboarding triggers `SMAppService` registration or a local admin-approved fallback install after Bag Mode consent.

## Required Prototype Notes

Follow-up [#27](https://github.com/makeavish/ClawShell/issues/27) must produce no-membership helper evidence:

- `codesign -dvvv --entitlements :-` for app and helper
- local signing/auth model for app and helper; Developer ID designated requirements only when available
- `spctl -a -vv` assessment of the distributable app when meaningful for the chosen path
- app bundle layout showing helper and plist locations
- `SMAppService.daemon(plistName:)` register and status outputs, or the exact failure proving fallback is needed
- System Settings approval behavior for `SMAppService`, or fallback local admin password flow with exact fixed `launchctl bootstrap`, `launchctl bootout`, file install/remove, repair, and uninstall commands
- `launchctl` evidence before and after approval
- reboot behavior after approval
- update behavior from helper generation N to N+1
- uninstall behavior via `unregister()` or fallback `launchctl bootout` plus helper-owned Bag Mode cleanup
- fixed command API evidence for `status`, `enableBagMode`, `disableBagMode`, `repair`, and `uninstall`
- root-owned ledger schema, file ownership/mode, sample owner token/generation/boot state, restore conflict behavior, and repair output
- CLI evidence for `clawshell helper status`, `clawshell helper repair`, and `clawshell uninstall --remove-helper --remove-integrations`
- failure cases for unpaired caller, wrong bundle id, wrong label/plist path, wrong user, stale app version, denied approval, and revoked approval
- Homebrew cask behavior if the prototype is exercised through `brew install --cask`, `brew upgrade --cask`, or `brew uninstall --cask`; otherwise track cask semantics separately from the helper prototype

Before attaching a helper prototype evidence package to #27, run the structural
verifier:

```bash
scripts/helper-service-prototype-verify.sh \
  --manifest .build/helper-service-prototype/<case-id>/prototype-manifest.tsv
```

To start the package layout without inventing rows by hand, generate a
non-mutating scaffold:

```bash
scripts/helper-service-prototype-scaffold.sh \
  --output-dir .build/helper-service-prototype/<case-id>
```

The scaffold is not evidence. It intentionally omits `validation-config.txt`
and `manual-result.md`, and writes `TODO` manifest rows so the verifier fails
until real helper output is captured.

To build the first no-membership `SMAppService` candidate without registering
anything, use:

```bash
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

The default run builds an ad-hoc signed app/helper bundle, captures local
layout/signing/status evidence, and captures dry-run command parser smoke output
for `status`, `enableBagMode`, `disableBagMode`, `repair`, and `uninstall`.
That parser smoke does not satisfy the required `fixed-command-api` manifest
row; registration, approved helper command API, and lifecycle rows remain
`TODO`. To attempt registration during an intentional interactive prototype,
rerun with `--register --i-understand-this-registers-helper`; that may require
System Settings approval before the helper bootstraps.

The first May 13, 2026 register attempt used a fresh unique identity:

```bash
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/smappservice-register-20260513T033434Z \
  --register \
  --i-understand-this-registers-helper
```

Captured result:

```text
appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.h06c22500e1
helperLabel=com.makeavish.ClawShell.HelperPrototype.h06c22500e1.daemon
identitySuffix=h06c22500e1
registerAttempted=true
result=fail
statusBeforeRaw=3 (notFound)
error=Error Domain=SMAppServiceErrorDomain Code=1 "Operation not permitted"
statusAfterRaw=2 (requiresApproval)
```

This artifact records the current no-membership `SMAppService` register
behavior for the ad-hoc app/helper bundle shape. It is not a hard rejection yet:
the command returned `Operation not permitted`, but the service status moved to
`requiresApproval`. Approve the helper in System Settings, then run
`--capture-post-approval` against this same artifact before deciding whether
fallback evidence is required. The verifier is still expected to fail because
lifecycle rows such as approved bootstrap, reboot, update, uninstall cleanup,
CLI helper commands, and failure cases are not yet complete.

A later fresh artifact from the PR #75-era harness reached the enabled state
in post-approval capture:

```bash
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/smappservice-register-stdout-20260513T040749Z \
  --register \
  --i-understand-this-registers-helper
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/smappservice-register-stdout-20260513T040749Z \
  --capture-post-approval
```

Captured result:

```text
appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.h5dba3aad54
helperLabel=com.makeavish.ClawShell.HelperPrototype.h5dba3aad54.daemon
identitySuffix=h5dba3aad54
statusAfterApprovalRaw=1 (enabled)
launchctlManagedBy=com.apple.xpc.ServiceManagement
launchctlRuns=1
launchctlLastExitCode=0
helperRuntimeUid=0
helperRuntimeEuid=0
helperStdoutLedgerEvent=bagModeHelperLedgerSample
rootLedgerMode=-rw-------
rootLedgerOwner=root
unregisterStatusBeforeRaw=1 (enabled)
unregisterResult=success
unregisterStatusAfterRaw=0 (notRegistered)
statusAfterUnregisterRaw=0 (notRegistered)
launchctlAfterUnregister=service-not-found
```

This artifact proves the no-membership/ad-hoc SMAppService helper can bootstrap
as root, can expose reviewable stdout ledger evidence even when the real
root-owned ledger is unreadable to the normal user, and can unregister so
launchctl no longer finds the daemon. The artifact does not prove which System
Settings UI, if any, was shown before the status became enabled; it only proves
the observed `requiresApproval`/`enabled`/`notRegistered` state transitions,
root runtime behavior, and ServiceManagement cleanup. Treat this as successful
local bootstrap and unregister evidence, not a complete #27 proof: the verifier
still fails until the remaining fixed-command API, admin-approval/password-flow,
post-approval status/bootstrap/log/launchctl, root-ledger schema/ownership,
reboot, update, repair, CLI command, failure case, and helper-owned Bag Mode
state cleanup rows are completed and reviewed.

By default, the approved LaunchDaemon runs the fixed `status` command in
dry-run mode. To prepare one artifact for a different approved-helper dry-run
command dispatch probe, set
`CLAWSHELL_HELPER_PROTOTYPE_DAEMON_COMMAND` to one of `status`,
`enableBagMode`, `disableBagMode`, `repair`, or `uninstall` before creating and
registering the artifact. The selected command is written to
`daemonCommand=<command>` and into the LaunchDaemon `ProgramArguments`.
The config records `rootLedgerPath=runtime/helper-ledger.jsonl`, and the
LaunchDaemon receives the resolved absolute artifact path. After approval,
post-approval capture records ledger permissions and contents when readable.
Because the helper writes root-owned `0600` log and ledger files, the helper
also mirrors dry-run ledger JSON to `runtime/helper.stdout.log`, which launchd
creates as a readable capture surface. This is not the final production
root-owned ledger implementation.

Each artifact gets a unique SMAppService bundle/helper identity derived from its
output path. This avoids reusing stale macOS approval/code-signing state between
ad-hoc helper prototype attempts. To force a deterministic suffix for
comparison runs, set `CLAWSHELL_HELPER_PROTOTYPE_ID_SUFFIX=<lettersAndDigits>`.
Append modes read the stored `helperLabel` and `identitySuffix` from the same
artifact and reject mismatched LaunchDaemon plist labels or controller
`plistName` output.

After macOS approval, append non-mutating status evidence to the same artifact
directory rather than starting a fresh app bundle:

```bash
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/<same-smappservice-register-artifact> \
  --capture-post-approval
```

The append mode captures `SMAppService` status, `launchctl` state, helper
runtime logs, helper stdout/stderr, and unified log output. It does not promote
manifest rows automatically; review the captured output, update the manifest
and manual result deliberately, then run the verifier before attaching the
artifact to #27.

After cleanup approval, append mutating unregister evidence to the same
artifact directory:

```bash
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/<same-smappservice-register-artifact> \
  --capture-unregister \
  --i-understand-this-registers-helper
```

This cleanup mode calls `unregister()` from the existing app bundle and records
follow-up `status`, `launchctl`, and unified log output without auto-promoting
manifest rows. The current artifact captured `unregisterResult=success`, status
`1 -> 0`, follow-up status `0`, and `launchctl` service-not-found. Review the
captured output before mapping it to `helper-uninstall`; keep
`helper-uninstall-state-cleanup` incomplete until helper-owned Bag Mode state
cleanup is exercised, then run the verifier.

The verifier expects three files at the manifest root:

- `validation-config.txt`
- `manual-result.md`
- `prototype-manifest.tsv`

`validation-config.txt` must record the machine-readable prototype shape:

```text
evidenceFormat=helper-prototype-v1
metadataRedacted=true
macOSVersion=15.0
appBundleIdentifier=com.makeavish.ClawShell.HelperPrototype.h123abc4567
helperLabel=com.makeavish.ClawShell.HelperPrototype.h123abc4567.daemon
identitySuffix=h123abc4567
launchDaemonPlist=ClawShellHelperPrototype.app/Contents/Library/LaunchDaemons/com.makeavish.ClawShell.HelperPrototype.h123abc4567.daemon.plist
helperInstallPath=smappservice
daemonCommand=status
rootLedgerPath=runtime/helper-ledger.jsonl
localAuthModel=ad-hoc app/helper signature plus binary hash capture; pairing token not implemented in this prototype harness
developerIDApplicationSigned=false
packageInstallerUsed=false
homebrewCaskUsed=false
result=inconclusive
```

For `helperInstallPath=smappservice`, `identitySuffix` must start with a letter
and contain only letters/digits. The `appBundleIdentifier`, `helperLabel`, and
LaunchDaemon plist filename must use the same suffix.

`manual-result.md` must use filled checklist fields:

```markdown
# Helper Service Prototype Result

## Prototype Case
- Case ID: apple-silicon-smappservice-local
- macOS: 15.0
- App bundle: /Applications/ClawShell.app
- LaunchDaemon plist: ClawShell.app/Contents/Library/LaunchDaemons/com.example.ClawShell.Helper.plist
- Helper install path: smappservice
- Helper install API/path: SMAppService.daemon(plistName:)

## Signing
- App signed: yes
- Helper signed: yes
- Local auth model recorded: yes
- Developer ID designated requirements recorded: N/A - no Apple Developer Program membership
- Package installer used: no
- Package signed with Developer ID Installer: N/A - no package installer used

## Lifecycle
- Install/status transition: requiresApproval -> enabled
- Admin approval/password flow confirmed: yes
- Helper bootstraps after approval: yes
- Helper bootstraps after reboot: yes
- Old helper inactive after update: yes
- Ledger compatibility or repair checked: yes
- Uninstall unloaded helper: yes
- Helper-owned Bag Mode state removed: yes

## Failure Cases
- Failure cases recorded: yes
- Homebrew cask used: no
- Homebrew cask registers helper during install: N/A - cask not used

## Conclusion
- Result: inconclusive
```

The verifier compares `manual-result.md` against `validation-config.txt`.
`macOS`, `LaunchDaemon plist`, helper install path, Developer ID status, and
`Result` must match the corresponding config fields.

`prototype-manifest.tsv` must use this tab-separated header:

```tsv
checkId	status	evidencePath	note
```

Required rows must use `status=evidence` and point to relative, non-empty files
or directories inside the evidence package. Evidence paths and evidence
directories must not contain symlink components, and evidence files must contain
real captured output rather than `TODO`, `<paste output>`, or placeholder text.
Optional rows are `smappservice-rejection`, `package-installer-signing`, and
`homebrew-cask-semantics`; use `status=n/a` with an explicit note when those
paths were not exercised. If `helperInstallPath=launchdaemon-fallback`, the
verifier requires package-relative `smappservice-rejection` evidence, such as
`evidence/smappservice-rejection.txt`, copied or captured into the fallback
package. The current SMAppService register artifact reached enabled status and
bootstrapped the helper, so it does not justify fallback by itself; fallback
evidence would need a later post-approval denial, lifecycle failure, or other
captured reason that the `SMAppService` path cannot satisfy #27. The
`launchDaemonPlist` config value must point to the installed
`/Library/LaunchDaemons/<label>.plist` artifact. Verifier success means the
evidence package is structurally complete only. It does not prove the helper
prototype passed or close #27 by itself.

Required manifest `checkId` rows:

- `app-bundle-or-install-layout`
- `launchdaemon-plist`
- `app-signing-or-auth-model`
- `helper-signing-or-auth-model`
- `caller-auth-model`
- `fixed-command-api`
- `spctl-or-gatekeeper-assessment`
- `helper-install-or-register`
- `helper-status-after-approval`
- `admin-approval-or-password-flow`
- `helper-bootstrap-after-approval`
- `post-reboot-helper-bootstrap`
- `root-ledger-schema-and-permissions`
- `root-ledger-ownership-sample`
- `helper-update-old-inactive`
- `helper-update-ledger-compatibility`
- `helper-repair-conflict`
- `helper-uninstall`
- `helper-uninstall-state-cleanup`
- `cli-helper-status-repair-uninstall`
- `failure-unpaired-caller`
- `failure-wrong-bundle-id-or-label`
- `failure-wrong-user`
- `failure-stale-app-version`
- `failure-denied-or-revoked-approval`
- `launchctl-status`
- `log-evidence`

Optional manifest `checkId` rows:

- `smappservice-rejection` when `helperInstallPath=launchdaemon-fallback`;
  otherwise include an `n/a` row with the reason `SMAppService` was used.
- `package-installer-signing` when `packageInstallerUsed=true`; otherwise
  include an `n/a` row with the reason no package installer was used.
- `homebrew-cask-semantics` when `homebrewCaskUsed=true`; otherwise include an
  `n/a` row with the reason no cask path was exercised.

## Conclusion

The current no-membership `SMAppService` helper shape reached enabled status,
bootstrapped as root with readable stdout ledger evidence, and unregistered so
launchctl no longer finds the service. The local ad-hoc SMAppService path
remains viable before Developer ID funding. Bag Mode still remains blocked until
#27 records the rest of the verifier-required helper proof: fixed command API,
admin approval/password flow, post-approval status/bootstrap/log/launchctl,
root-ledger schema/ownership, reboot, update, repair, CLI helper commands,
failure cases, and helper-owned Bag Mode state cleanup. Developer ID signing
remains a later distribution/trust milestone.
