# Release Checklist

- [ ] Run `./scripts/quality_gates.sh` locally.
- [ ] Confirm `Pangolin/Pangolin.entitlements` does **not** include `com.apple.security.temporary-exception.files.absolute-path.read-write`.
- [ ] Build succeeds: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build`.
- [ ] Tests pass: `xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test`.
