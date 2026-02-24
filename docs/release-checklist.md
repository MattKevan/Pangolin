# Pangolin Beta Release Checklist

## 1) Preflight

- [ ] Record release candidate commit SHA: `git rev-parse --short HEAD`.
- [ ] Confirm working tree state is intentional: `git status --short`.
- [ ] Run static gates: `./scripts/quality_gates.sh`.
- [ ] Confirm forbidden entitlement is absent:
  `rg -n "com\\.apple\\.security\\.temporary-exception\\.files\\.absolute-path\\.read-write" Pangolin/Pangolin.entitlements`.
- [ ] Confirm app category is set:
  `/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' Pangolin/Info.plist`.
- [ ] Confirm release versions are correct (currently `1.0.1 (2)`):
  `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -configuration Release -showBuildSettings | rg "MARKETING_VERSION|CURRENT_PROJECT_VERSION"`.

## 2) Build + Test

- [ ] Build succeeds:
  `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`.
- [ ] Tests pass:
  `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`.
- [ ] Archive succeeds:
  `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -configuration Release -destination 'generic/platform=macOS' archive -archivePath build/release/Pangolin.xcarchive`.

## 3) Packaging

- [ ] App Store/TestFlight export succeeds:
  `./scripts/release/archive_appstore.sh`.
- [ ] Developer ID export succeeds from same archive:
  `REUSE_ARCHIVE=1 ./scripts/release/archive_developerid.sh`.
- [ ] Ensure signing identities are correct in exported artifacts:
  `codesign -dv --verbose=4 build/release/developerid/Pangolin.app 2>&1 | rg "Authority|TeamIdentifier"`.

## 4) Notarization (Direct Download Path)

- [ ] Configure notary credentials in keychain profile.
- [ ] Notarize and staple direct artifact:
  `NOTARY_KEYCHAIN_PROFILE="<profile>" ./scripts/release/notarize_and_staple.sh build/release/developerid/Pangolin.app`.
- [ ] Gatekeeper assessment passes:
  `spctl -a -vv -t exec build/release/developerid/Pangolin.app`.

## 5) TestFlight Path

- [ ] Upload build using Xcode Organizer or Transporter.
- [ ] Verify build appears in App Store Connect.
- [ ] Add internal testers first and validate install/launch.
- [ ] Configure external tester group once internal testing is stable.

## 6) Beta QA Exit Criteria

- [ ] Execute `/Users/mattkevan/Dev/Pangolin/docs/beta-test-matrix.md` on release artifacts (not Xcode run target).
- [ ] Resolve all P0/P1 issues before external rollout.
- [ ] Publish only if both channels pass:
  1. TestFlight build available for testers.
  2. Direct download artifact notarized, stapled, and accepted by Gatekeeper.
