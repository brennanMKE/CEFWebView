# Updating CEF and releasing

How to move the package to a new CEF build and publish it. Maintainers only; apps that use the
package just pick up the new version.

## Versions

Package versions are `<CEF major>.<CEF patch>.<revision>`: CEF 154.0.34 ships as `154.34.0`, and a
package-only fix on the same CEF as `154.34.1`. Not `154.0.34-1`: SwiftPM's normal version
requirements skip pre-release versions.

`Package.swift` has two constants:

- `releaseTag` names the GitHub release that **holds the CEF zip**. A package-only release reuses the
  previous zip, so `releaseTag` stays put while the git tag moves on.
- `cefChecksum` is that zip's SwiftPM checksum.

## Package-only release (same CEF)

1. Commit the change. Run the tests: `swift test` on the host, `Scripts/run-tests-vm.sh` for the
   demo's integration tests (never on the host; see [TESTING_IN_TART.md](TESTING_IN_TART.md)).
2. Tag the next revision and push the tag: `git tag 154.34.2 && git push origin main 154.34.2`.
3. Optionally create a GitHub release for the tag with notes. No upload is needed.

## New CEF version

1. **Pick the build.** On <https://cef-builds.spotifycdn.com/index.html>, take the macOS ARM64
   "Standard Distribution" of a stable branch. Copy its full version, such as
   `155.0.12+gabc1234+chromium-155.0.8100.50`.

2. **Vendor and build locally.** Set `CEF_VERSION` in `Scripts/update_cef.sh` to it, then run:

   ```sh
   Scripts/update_cef.sh
   ```

   It downloads the distribution into `CEF/` (gitignored), replaces `Sources/CEFDLLWrapper`'s headers
   and wrapper sources, builds `Frameworks/ChromiumEmbeddedFramework.xcframework` (gitignored, which
   `Package.swift` prefers over the download), and zips it with its checksum.

3. **Fix the build.** `swift build`, then build the demo app. CEF changes its C++ API between major
   versions; the usual places to adjust are the handler overrides in `Sources/CEFWrapper/CEFWrapper.mm`
   and `CEFRenderProcess.mm`. A virtual method whose signature changed stops being an override and
   is silently never called, so compare each `override` against the new headers (CEF 154 changed
   `OnRenderProcessTerminated` this way). `include/cef_api_versions.h` lists the API versions the new build supports.

4. **Test.** `swift test`, then `Scripts/run-tests-vm.sh`. Also run the demo app once and load a few
   real sites.

5. **Commit** the vendored sources, the new `CEF_VERSION` and any code changes.

6. **Publish the zip.** Either:
   - Run the **CEF release artifact** workflow in GitHub Actions with the new tag (for example
     `155.12.0`). It rebuilds the zip from the commit, attaches it to a draft release and prints the
     `releaseTag` and `cefChecksum` lines in the job summary. Or:
   - Create the release by hand: `gh release create 155.12.0 .build/release/ChromiumEmbeddedFramework.xcframework.zip --draft`.

7. **Point Package.swift at it.** Set `releaseTag` and `cefChecksum` to the values from the zip you
   uploaded (the workflow's or `update_cef.sh`'s output; they differ, because the zip is not
   byte-for-byte reproducible). Commit.

8. **Verify the download.** Move `Frameworks/` aside so the package uses the release URL, then:

   ```sh
   mv Frameworks /tmp/Frameworks.local && swift package reset && swift test; mv /tmp/Frameworks.local Frameworks
   ```

   A wrong checksum fails here with `checksum of downloaded artifact … does not match`.

9. **Release.** Tag the commit from step 7 with the same version, push the branch and tag, and
   publish the draft release.

## Signing and notarization after an update

Nothing changes for apps: Xcode signs the framework, and `Scripts/cef-embed` signs the helpers and
the framework's `Libraries/*.dylib` with the app's identity. Check a new CEF with a notarized build
of the demo app:

```sh
Scripts/notarize.sh
```

It archives with Developer ID, notarizes through the Apple account Xcode is signed into (no
`notarytool` credentials), staples the ticket and checks the result with `spctl`. New files in the
framework that need signing (another dylib in `Libraries/`, say) show up here as a notarization
rejection.
