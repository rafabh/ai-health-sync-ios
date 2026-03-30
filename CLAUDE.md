# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

HealthSync Helper App - HealthKit sync with two modes:
1. **Local P2P:** iPhone↔Mac via mTLS (original)
2. **Direct to VPS:** iPhone→Cockpit Executivo API via HTTP (incremental + manual window)

## Apple Platforms
- For Swift / iOS/iPadOS 26 code, look for info in:
  `/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation`

## Commands

```bash
# Build iOS app
xcodebuild -project "iOS Health Sync App/iOS Health Sync App.xcodeproj" \
  -scheme "iOS Health Sync App" -destination 'generic/platform=iOS' build

# Run iOS tests (all)
xcodebuild test -project "iOS Health Sync App/iOS Health Sync App.xcodeproj" \
  -scheme "HealthSyncTests" -destination 'platform=iOS Simulator,name=iPhone 16'

# Run single iOS test
xcodebuild test -project "iOS Health Sync App/iOS Health Sync App.xcodeproj" \
  -scheme "HealthSyncTests" -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOS_Health_Sync_AppTests/<TestClass>/<testMethod>

# macOS CLI
cd macOS/HealthSyncCLI && swift build && swift test
```

## Gotchas

IMPORTANT - Know these before coding:
- HealthKit READ permissions CANNOT be verified - Apple hides denial for privacy
- Simulator has limited HealthKit data - test on device for real scenarios
- CLI requires macOS 15+ for Network framework TLS features
- All secrets in Keychain via `KeychainStore` - NEVER in config files or UserDefaults
- All health data access MUST be logged via `AuditService`

## Entry Points

| Component | File |
|-----------|------|
| iOS state | `iOS Health Sync App/iOS Health Sync App/App/AppState.swift` |
| HTTP server | `iOS Health Sync App/iOS Health Sync App/Services/Network/NetworkServer.swift` |
| TLS certs | `iOS Health Sync App/iOS Health Sync App/Services/Security/CertificateService.swift` |
| Health queries | `iOS Health Sync App/iOS Health Sync App/Services/HealthKit/HealthKitService.swift` |
| VPS API client | `iOS Health Sync App/iOS Health Sync App/Services/API/CockpitAPIClient.swift` |
| Cockpit sync UI | `iOS Health Sync App/iOS Health Sync App/Features/CockpitSyncView.swift` |
| CLI | `macOS/HealthSyncCLI/Sources/HealthSyncCLI/main.swift` |

## Git Workflow

- Solo developer — commit and push directly to `master`
- Do NOT create git tags, branches, or PRs
- Keep the GitHub repo clean: no extra branches, no tags
- Run lint and tests before pushing, not on every commit

## Deep Dives

- Architecture: `DOCS/learn/02-architecture.md`
- Security: `DOCS/learn/07-security.md`
- Swift 6 patterns: `DOCS/learn/03-swift6.md`
- Testing: `DOCS/learn/10-testing.md`
- CLI usage: `DOCS/learn/09-cli.md`
