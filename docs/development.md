# Development

ClawShell is currently a native macOS menu bar app skeleton built with SwiftPM.

## Requirements

- macOS 13 or newer
- Swift 6.0 or newer from Xcode or Command Line Tools

## Run Locally

```sh
swift run ClawShell
```

The app starts as an accessory menu bar process and does not request admin privileges.

## Check

```sh
swift test
swift run ClawShellCoreChecks
swift run ClawShell --smoke-test
```

The first checks cover the state/menu model, lifecycle component boundaries, and a short AppKit launch smoke. AppKit behavior is intentionally thin until the detection, assertion, and integration issues add real behavior.

The local Command Line Tools environment may lack `Testing` and `XCTest`, so `ClawShellCoreChecks` remains the portable assertion gate until the dedicated test-harness issue installs CI.
