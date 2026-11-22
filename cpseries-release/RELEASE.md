# Vendored: the released cpseries client binaries (CPSeries v1.1.0)

These files come unchanged from the GitHub release `v1.1.0` of the private
repository `JaumeAP/CPSeries` ("cpseries client (C++) 1.1.0 — macOS +
Windows"), built there from `main` at `5ea82b6`. Do not edit or rebuild them
here: refresh them from a newer CPSeries release.

## Release archives

| Archive | SHA-256 (checked against the release notes) |
| --- | --- |
| `cpseries-1.1.0-macos-universal.tar.gz` | `fbd26c2c542846ee6b328f2c182a8caac456b1b70e881e5314e62e5b60d7d133` |
| `cpseries-1.1.0-windows-x64.zip` | `53a828ea0ea211a4341368d3f87676ca0835bbd65327892b1ca7ba4c43fefd68` |

## Layout

1. `Artifacts/macos-universal/` — the macOS archive, extracted as released:
   `libcpseries.a`, `libcpseries.dylib`, `include/cpseries.hpp`,
   `include/cpseries_c.h`, `LICENSE`, `USAGE.md`. macOS 11+, arm64 + x86_64.
2. `Artifacts/windows-x64/` — the Windows archive, extracted as released:
   `libcpseries.dll`, `libcpseries.dll.a`, `cp_client.exe`, `cp_client_c.exe`,
   `cpseries.hpp`, `cpseries_c.h`, `LICENSE`, `USAGE.md`. Not linked by
   SwiftPM; kept for a Windows build.
3. `CPSeries.xcframework/` — the macOS `libcpseries.a` and both headers,
   wrapped so SwiftPM can link them (`binaryTarget` `CPSeriesC`). Its
   `Info.plist` and `Headers/module.modulemap` are the only files written
   here; the module map exposes only the plain-C header, `cpseries_c.h`.
4. `Sources/CPSeries/` — re-exports `CPSeriesC`, and links libc++, which the
   static library needs.
5. `Tests/CPSeriesTests/` — link checks of the C API, with no network.

Each `USAGE.md` describes its platform's contents and how to link them.

## File hashes

| File | SHA-256 |
| --- | --- |
| `macos-universal/libcpseries.a` | `7d8cdfd381a2baf038b3010ad67b853815e60370f725c8181f30815908d74f02` |
| `macos-universal/libcpseries.dylib` | `0ffe8561f7533a7c9011cf5282a0e02254e06599829a0bf7640537e2a8cbb6e2` |
| `windows-x64/libcpseries.dll` | `6487186568395bc9cad1d52204725417ca7cafdf045642438d3b570bb8b31fe4` |
| `windows-x64/libcpseries.dll.a` | `9319cef0fdd4bc746034836281c59a0af7f49c2525b4811488ba509273430718` |
| `windows-x64/cp_client.exe` | `5f4c155738696aee9fe825775569d52bf91a0b107632eeebc52a161cc35de87d` |
| `windows-x64/cp_client_c.exe` | `3013b1a54c21a8fbdf7ee686f1f177bff3d2c1924814291d073dae546a4e4929` |
| `cpseries.hpp` (both platforms) | `18cc1c4f2f36df5124f5c367bd163f29e3c192e6c9c87ebdfa0e6eeede81b908` |
| `cpseries_c.h` (both platforms) | `f827cb72a24f999924ee1f0776ac63692331aec56e981e4268bb490380ad248b` |

The copies inside `CPSeries.xcframework/` are byte-identical to the ones in
`Artifacts/macos-universal/`.

## Build and test

    cd cpseries-release && swift test --scratch-path <scratchpad>/cpseries-release-build

## Refreshing

1. Download the new release's two archives (`gh release download <tag> -R
   JaumeAP/CPSeries`) into the session scratchpad and check their SHA-256
   against the release notes.
2. Replace `Artifacts/macos-universal/` and `Artifacts/windows-x64/` with the
   extracted contents.
3. Copy `libcpseries.a`, `cpseries.hpp` and `cpseries_c.h` into
   `CPSeries.xcframework/macos-arm64_x86_64/` (and `Headers/`), update this
   file (tag, commit, hashes) and run the tests.
