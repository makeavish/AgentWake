# Helper Service Readiness

Check date: May 12, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#27](https://github.com/makeavish/ClawShell/issues/27)

Local artifact: `.build/helper-service-readiness/local-20260512T024849Z`

## Question

Is `SMAppService` a source-backed helper path worth prototyping before ClawShell claims signed helper install/update/uninstall support?

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
scripts/helper-service-readiness.sh --output-dir .build/helper-service-readiness/local-20260512T024849Z
```

Captured result:

```text
validCodeSigningIdentityCount=0
developerIDApplicationIdentityCount=0
developerIDInstallerIdentityCount=0
appleDevelopmentIdentityCount=0
appleDistributionIdentityCount=0
xcodebuildAvailable=false
pkgbuildAvailable=true
productbuildAvailable=true
macosSdkAvailable=true
codesignAvailable=true
notarytoolAvailable=true
signedPrototypeReady=false
metadataRedacted=true
```

The local environment has Command Line Tools, a macOS SDK, `codesign`, `notarytool`, and package builders, but no Developer ID Application identity, no Developer ID Installer identity, and no full Xcode-backed `xcodebuild`. The harness records only redacted identity counts: app-signing identities come from the `codesigning` policy, while installer identities come from a separate `basic` identity query. Therefore this machine cannot complete the signed install/update/uninstall prototype.

## Provisional Design Verdict

`SMAppService` remains the source-backed V1 target to prototype, but #7 cannot claim the signed helper path is validated yet.

The design should keep these constraints:

- App bundle contains the helper and LaunchDaemon plist.
- LaunchDaemon plist lives under `Contents/Library/LaunchDaemons`.
- App and helper are signed with compatible designated requirements.
- Registration is app-initiated after Bag Mode consent.
- LaunchDaemon approval is admin-mediated in System Settings.
- Production Bag Mode stays hidden or unavailable in unsigned public builds.
- A Homebrew cask may install the signed app bundle containing the helper and plist, but it must not call `SMAppService.register()`, run `launchctl`, or execute installer scripts that activate the helper. Onboarding triggers registration after Bag Mode consent, and macOS admin approval happens in System Settings.

## Required Prototype Notes

Follow-up [#27](https://github.com/makeavish/ClawShell/issues/27) must produce the signed SMAppService evidence:

- `codesign -dvvv --entitlements :-` for app and helper
- designated requirements for app and helper
- `spctl -a -vv` assessment of the distributable app
- app bundle layout showing helper and plist locations
- `SMAppService.daemon(plistName:)` register and status outputs
- System Settings approval behavior
- `launchctl` evidence before and after approval
- reboot behavior after approval
- update behavior from helper generation N to N+1
- uninstall behavior via `unregister()` plus helper-owned Bag Mode cleanup
- failure cases for unsigned caller, wrong bundle id, wrong label/plist path, wrong user, stale app version, denied approval, and revoked approval
- Homebrew cask behavior if the prototype is exercised through `brew install --cask`, `brew upgrade --cask`, or `brew uninstall --cask`; otherwise track cask semantics separately from the helper prototype

## Conclusion

The helper path is source-backed but not locally validated as a signed prototype. Production Bag Mode remains blocked until #27 records install/update/uninstall evidence with a real signing identity and full macOS app bundle.
