# Blink Shell GPL Builder

This repo is a small script that downloads the [Blink Shell](https://github.com/blinksh/blink) GPL source code, removes the paywall, applies a few other build-time fixes, and produces a ready-to-upload IPA.

## What the script does

- Clones the Blink Shell repo into `blink-src/`
- Applies the GPL sideload paywall patch
- Fixes a couple of Swift package pins
- Replaces hardcoded TEAM_ID with configurable value
- Makes the vim runtime fetch repeatable
- Builds the app and places the output in `dist/`
- Cleans up `build-output/` and `blink-src/` by default


## Requirements

- macOS with Xcode installed
- Xcode Command Line Tools:
  ```bash
  xcode-select --install
  ```
- Xcode platform content: install the iOS platform and iOS Simulator runtime
  (Xcode > Settings > Platforms)
- Git, Python 3, and jq:
  ```bash
  brew install jq
  ```

The script runs preflight checks and exits early with clear errors if anything
is missing.

## Quick start

```bash
./build-blink-shell-gpl.sh
```

Output:
`dist/Blink-unsigned-v18.4.2.ipa`

Upload the IPA to your signing service (AltStore, Sideloadly, etc).


## Options

```
./build-blink-shell-gpl.sh [options] [version]

Build Options:
  --build              Build unsigned .ipa (default)
  --clean              Clean build before building
  --signed-ipa         Create signed .ipa (requires dev account)
  --archive            Create signed archive (requires dev account)
  --setup-only         Only setup/clone, don't build

Device Options:
  --simulator [NAME]   Build and run in iOS Simulator
                       Optional: specify simulator by name or UUID
  --install [NAME]     Build and install to device (requires dev account)
                       Optional: specify device by name or UUID
  --devices            List available physical devices and exit
  --simulators         List available simulators and exit

Source Options:
  --version <VERSION>  Specify Blink version to build (e.g., v18.4.2)
  --update             Update existing source to specified version
  --overwrite          Delete and re-clone source directory
  --clean-all          Remove source and build directories, then exit

Other Options:
  --keep-build         Keep build-output/ after a successful build
  --keep-source        Keep blink-src/ after a successful build
  --help               Show this help message
```

## Examples

```bash
# Build unsigned IPA (default)
./build-blink-shell-gpl.sh

# Build a specific version
./build-blink-shell-gpl.sh --version v18.3.0

# List available simulators
./build-blink-shell-gpl.sh --simulators

# Run in a specific simulator
./build-blink-shell-gpl.sh --simulator "iPhone 16"

# List connected devices
./build-blink-shell-gpl.sh --devices

# Install to a specific device (requires dev account)
./build-blink-shell-gpl.sh --install "My iPhone"

# Fresh build from scratch
./build-blink-shell-gpl.sh --overwrite --clean

# Update existing source to a new version
./build-blink-shell-gpl.sh --version v19.0.0 --update

# Create signed IPA (requires Apple Developer account)
./build-blink-shell-gpl.sh --signed-ipa

# Clean up all generated files
./build-blink-shell-gpl.sh --clean-all
```

## Output layout

```
dist/
├── Blink-unsigned-v18.4.2.ipa    # Upload this to signing service
├── Blink-signed-v18.4.2.ipa      # Signed IPA (--signed-ipa)
└── Blink-v18.4.2.xcarchive       # Archive builds only (--archive)

build-output/             # Intermediate build output (removed by default)
├── Products/
├── DerivedData/
└── build.log             # Full xcodebuild output for debugging

blink-src/                # Source checkout (removed by default)
```

## Source management

The script handles existing source directories as follows:

- **Default**: Reuses existing `blink-src/` silently, applying patches
- **--update**: Fetches latest changes and checks out the specified version
- **--overwrite**: Deletes and re-clones the source directory

## Device selection

When using `--simulator` or `--install`, you can optionally specify a device:

- **By name**: `--simulator "iPhone 16"` (partial match, case-insensitive)
- **By UUID**: `--simulator "5FDBDDC9-70FD-4DF4-93E6-92DE570374B8"`
- **Auto-select**: Omit the argument to automatically select a device

The device listing commands (`--devices`, `--simulators`) filter out devices
that don't meet the minimum iOS version required by the project.

## Notes

- Use `--keep-source` if you want to inspect or debug the downloaded Blink source.
- The version defaults to `v18.4.2`. You can override it with `--version`:
  ```bash
  ./build-blink-shell-gpl.sh --version v19.0.0
  ```
- For backwards compatibility, you can also pass the version as a positional argument:
  ```bash
  ./build-blink-shell-gpl.sh v19.0.0
  ```
- Build logs are saved to `build-output/build.log` for debugging failed builds.
- The `--archive`, `--install`, and `--signed-ipa` options require a valid
  provisioning profile. The script checks for this before building and provides
  guidance if none is found.

## Troubleshooting

**Package dependency errors:**
```bash
rm -rf ~/Library/Caches/org.swift.swiftpm
./build-blink-shell-gpl.sh --overwrite --clean
```

**Build failures:**
Check `build-output/build.log` for the full xcodebuild output (use `--keep-build`
to preserve it after the build).

**Finding available versions** (Blink publishes release branches in the repo):
```bash
git ls-remote --heads https://github.com/blinksh/blink.git | grep -E "refs/heads/v[0-9]+"
```

**No provisioning profile found:**
For signed builds, you need an Apple Developer account. Open the project in
Xcode (`open blink-src/Blink.xcodeproj`) and let Xcode manage signing, or
download profiles manually in Xcode > Settings > Accounts.

## License

MIT. See `LICENSE`.
