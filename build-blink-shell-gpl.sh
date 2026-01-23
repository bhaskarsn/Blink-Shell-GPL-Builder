#!/bin/bash
set -e

# Blink Shell Build Script
# Builds unsigned .ipa for sideloading via signing services
#
# HELP_START
# Usage:
#   ./build-blink-shell-gpl.sh [options] [version]
#
# Build Options:
#   --build              Build unsigned .ipa (default)
#   --clean              Clean build before building
#   --signed-ipa         Create signed .ipa (requires dev account)
#   --archive            Create signed archive (requires dev account)
#   --setup-only         Only setup/clone, don't build
#
# Device Options:
#   --simulator [NAME]   Build and run in iOS Simulator
#                        Optional: specify simulator by name or UUID
#   --install [NAME]     Build and install to device (requires dev account)
#                        Optional: specify device by name or UUID
#   --devices            List available physical devices and exit
#   --simulators         List available simulators and exit
#
# Source Options:
#   --version <VERSION>  Specify Blink version to build (e.g., v18.4.2)
#   --update             Update existing source to specified version
#   --overwrite          Delete and re-clone source directory
#   --clean-all          Remove source and build directories, then exit
#
# Other Options:
#   --keep-build         Keep build-output/ after a successful build
#   --keep-source        Keep blink-src/ after a successful build
#   --help               Show this help message
#
# Examples:
#   ./build-blink-shell-gpl.sh                         # Build unsigned .ipa
#   ./build-blink-shell-gpl.sh --version v18.4.2       # Build specific version
#   ./build-blink-shell-gpl.sh --simulator "iPhone 16" # Run in specific simulator
#   ./build-blink-shell-gpl.sh --simulators            # List available simulators
#   ./build-blink-shell-gpl.sh --overwrite --clean     # Fresh build from scratch
# HELP_END

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VERSION="v18.4.2"
SOURCE_DIR="${SCRIPT_DIR}/blink-src"
BUILD_DIR="${SCRIPT_DIR}/build-output"
BUILD_LOG="${BUILD_DIR}/build.log"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
OUTPUT_ARCHIVE_PATH=""
OUTPUT_IPA_PATH=""
SCHEME="Blink"
PROJECT="${SOURCE_DIR}/Blink.xcodeproj"

# Options
SETUP_ONLY=false
DO_BUILD=true
DO_CLEAN=false
DO_ARCHIVE=false
DO_INSTALL=false
DO_SIMULATOR=false
DO_SIGNED_IPA=false
DO_LIST_DEVICES=false
DO_LIST_SIMULATORS=false
KEEP_BUILD=false
KEEP_SOURCE=false
SOURCE_UPDATE=false
SOURCE_OVERWRITE=false
TARGET_DEVICE=""
TARGET_SIMULATOR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --setup-only)
            SETUP_ONLY=true
            DO_BUILD=false
            shift
            ;;
        --build)
            DO_BUILD=true
            shift
            ;;
        --clean)
            DO_CLEAN=true
            shift
            ;;
        --archive)
            DO_ARCHIVE=true
            shift
            ;;
        --signed-ipa)
            DO_SIGNED_IPA=true
            shift
            ;;
        --install)
            DO_INSTALL=true
            # Check if next argument is a device name/id (not another flag)
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                TARGET_DEVICE="$2"
                shift
            fi
            shift
            ;;
        --simulator)
            DO_SIMULATOR=true
            DO_BUILD=false
            # Check if next argument is a simulator name/id (not another flag)
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                TARGET_SIMULATOR="$2"
                shift
            fi
            shift
            ;;
        --devices)
            DO_LIST_DEVICES=true
            DO_BUILD=false
            shift
            ;;
        --simulators)
            DO_LIST_SIMULATORS=true
            DO_BUILD=false
            shift
            ;;
        --version)
            if [[ $# -lt 2 ]]; then
                echo "Error: --version requires a version argument (e.g., --version v18.4.2)"
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        --update)
            SOURCE_UPDATE=true
            shift
            ;;
        --overwrite)
            SOURCE_OVERWRITE=true
            shift
            ;;
        --clean-all)
            echo "Removing source and build directories..."
            rm -rf "${SCRIPT_DIR}/blink-src" "${SCRIPT_DIR}/build-output"
            echo "Done."
            exit 0
            ;;
        --keep-build)
            KEEP_BUILD=true
            shift
            ;;
        --keep-source)
            KEEP_SOURCE=true
            shift
            ;;
        --help)
            awk '/^# HELP_START$/,/^# HELP_END$/' "$0" | grep -v '^# HELP_' | sed 's/^# //' | sed 's/^#$//'
            exit 0
            ;;
        v*)
            # Backwards compatibility: positional version argument
            VERSION="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

echo "=================================="
echo "Blink Shell Build Script"
echo "=================================="
echo "Version: $VERSION"
echo "Source directory: $SOURCE_DIR"
echo ""

# Preflight checks
preflight_checks() {
    local missing=0

    if ! command -v git &> /dev/null; then
        echo "Error: git is required but not found."
        missing=1
    fi

    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required but not found."
        missing=1
    fi

    if ! command -v jq &> /dev/null; then
        echo "Error: jq is required but not found."
        echo "Install with: brew install jq"
        missing=1
    fi

    if ! command -v xcodebuild &> /dev/null; then
        echo "Error: Xcode is required. Install Xcode and run xcode-select --install."
        missing=1
    fi

    if ! xcode-select -p &> /dev/null; then
        echo "Error: Xcode Command Line Tools not configured. Run xcode-select --install."
        missing=1
    fi

    if ! xcrun --sdk iphoneos --show-sdk-path &> /dev/null; then
        echo "Error: iOS platform content is missing. Install iOS in Xcode > Settings > Platforms."
        missing=1
    fi

    if [ "$DO_SIMULATOR" = true ] || [ "$DO_LIST_SIMULATORS" = true ]; then
        if ! xcrun --sdk iphonesimulator --show-sdk-path &> /dev/null; then
            echo "Error: iOS Simulator platform content is missing."
            echo "Install it in Xcode > Settings > Platforms."
            missing=1
        fi
    fi

    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

# Get minimum iOS deployment target from project
get_min_ios_version() {
    if [ -f "${PROJECT}/project.pbxproj" ]; then
        grep -m1 'IPHONEOS_DEPLOYMENT_TARGET' "${PROJECT}/project.pbxproj" 2>/dev/null | \
            sed -E 's/.*= ([0-9.]+);.*/\1/' || echo "16.0"
    else
        echo "16.0"
    fi
}

# Compare version strings (returns 0 if $1 >= $2)
version_gte() {
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# List available devices with iOS version filtering
list_devices() {
    local min_ios
    if [ -f "${PROJECT}/project.pbxproj" ]; then
        min_ios=$(get_min_ios_version)
    else
        min_ios="16.0"
    fi

    echo "Available devices (minimum iOS $min_ios):"
    echo ""
    printf "%-40s %-36s %s\n" "NAME" "IDENTIFIER" "iOS VERSION"
    printf "%-40s %-36s %s\n" "----" "----------" "-----------"

    xcrun xcdevice list 2>/dev/null | jq -r '
        .[] | select(.simulator == false and .platform == "com.apple.platform.iphoneos") |
        "\(.name)\t\(.identifier)\t\(.operatingSystemVersion)"
    ' 2>/dev/null | while IFS=$'\t' read -r name id version; do
        # Extract major.minor version for comparison
        ios_ver=$(echo "$version" | sed -E 's/([0-9]+\.[0-9]+).*/\1/')
        if version_gte "$ios_ver" "$min_ios"; then
            printf "%-40s %-36s %s\n" "$name" "$id" "$version"
        fi
    done

    local device_count
    device_count=$(xcrun xcdevice list 2>/dev/null | jq '[.[] | select(.simulator == false and .platform == "com.apple.platform.iphoneos")] | length' 2>/dev/null || echo "0")
    if [ "$device_count" = "0" ]; then
        echo "(No devices connected)"
    fi
}

# List available simulators with iOS version filtering
list_simulators() {
    local min_ios
    if [ -f "${PROJECT}/project.pbxproj" ]; then
        min_ios=$(get_min_ios_version)
    else
        min_ios="16.0"
    fi

    echo "Available simulators (minimum iOS $min_ios):"
    echo ""
    printf "%-40s %-36s %s\n" "NAME" "IDENTIFIER" "iOS VERSION"
    printf "%-40s %-36s %s\n" "----" "----------" "-----------"

    xcrun xcdevice list 2>/dev/null | jq -r '
        .[] | select(.simulator == true and .platform == "com.apple.platform.iphonesimulator") |
        "\(.name)\t\(.identifier)\t\(.operatingSystemVersion)"
    ' 2>/dev/null | while IFS=$'\t' read -r name id version; do
        # Extract major.minor version for comparison
        ios_ver=$(echo "$version" | sed -E 's/([0-9]+\.[0-9]+).*/\1/')
        if version_gte "$ios_ver" "$min_ios"; then
            printf "%-40s %-36s %s\n" "$name" "$id" "$version"
        fi
    done
}

# Search for a device by name or UUID
# Returns device identifier if found
device_search() {
    local search_term="$1"
    local device_type="$2"  # "device" or "simulator"
    local min_ios

    if [ -f "${PROJECT}/project.pbxproj" ]; then
        min_ios=$(get_min_ios_version)
    else
        min_ios="16.0"
    fi

    local platform_filter
    if [ "$device_type" = "simulator" ]; then
        platform_filter='select(.simulator == true and .platform == "com.apple.platform.iphonesimulator")'
    else
        platform_filter='select(.simulator == false and .platform == "com.apple.platform.iphoneos")'
    fi

    # Check if search_term looks like a UUID
    if [[ "$search_term" =~ ^[A-F0-9-]{36}$ ]]; then
        # Search by UUID
        xcrun xcdevice list 2>/dev/null | jq -r --arg id "$search_term" "
            .[] | $platform_filter | select(.identifier == \$id) | .identifier
        " 2>/dev/null | head -1
    else
        # Search by name (case-insensitive partial match)
        xcrun xcdevice list 2>/dev/null | jq -r --arg name "$search_term" "
            .[] | $platform_filter |
            select(.name | test(\$name; \"i\")) |
            \"\(.operatingSystemVersion)\t\(.identifier)\"
        " 2>/dev/null | while IFS=$'\t' read -r version id; do
            ios_ver=$(echo "$version" | sed -E 's/([0-9]+\.[0-9]+).*/\1/')
            if version_gte "$ios_ver" "$min_ios"; then
                echo "$id"
            fi
        done | head -1
    fi
}

# Find provisioning profile for the app
get_profile() {
    local bundle_id="sh.blink.blinkshell"
    local profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"

    if [ ! -d "$profiles_dir" ]; then
        return 1
    fi

    # Find a valid provisioning profile for our bundle ID
    for profile in "$profiles_dir"/*.mobileprovision; do
        [ -f "$profile" ] || continue

        # Extract and check bundle ID from profile
        local profile_bundle_id
        profile_bundle_id=$(security cms -D -i "$profile" 2>/dev/null | \
            plutil -extract Entitlements.application-identifier raw - 2>/dev/null | \
            sed 's/^[A-Z0-9]*\.//')

        # Check for exact match or wildcard
        if [ "$profile_bundle_id" = "$bundle_id" ] || [ "$profile_bundle_id" = "*" ]; then
            # Check if profile is not expired
            local expiry
            expiry=$(security cms -D -i "$profile" 2>/dev/null | \
                plutil -extract ExpirationDate raw - 2>/dev/null)

            if [ -n "$expiry" ]; then
                local expiry_epoch current_epoch
                expiry_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$expiry" "+%s" 2>/dev/null || echo "0")
                current_epoch=$(date "+%s")

                if [ "$expiry_epoch" -gt "$current_epoch" ]; then
                    echo "$profile"
                    return 0
                fi
            fi
        fi
    done

    return 1
}

# Verify provisioning profile exists for signed builds
verify_provisioning_profile() {
    echo "Checking for valid provisioning profile..."

    local profile
    profile=$(get_profile)

    if [ -z "$profile" ]; then
        echo ""
        echo "Error: No valid provisioning profile found for sh.blink.blinkshell"
        echo ""
        echo "To create a provisioning profile:"
        echo "1. Open Xcode and go to Settings > Accounts"
        echo "2. Select your Apple ID and click 'Download Manual Profiles'"
        echo "3. Or open the project in Xcode and let it manage signing automatically"
        echo ""
        echo "For signed IPA builds, you need an Apple Developer account."
        return 1
    fi

    echo "  Found: $(basename "$profile")"
    return 0
}

# Function to fix package dependencies
fix_package_dependencies() {
    echo "Fixing package dependencies..."

    # Fix swiftui-cached-async-image (main branch has broken Package.swift)
    if grep -q 'XCRemoteSwiftPackageReference "swiftui-cached-async-image"' "${PROJECT}/project.pbxproj" 2>/dev/null; then
        sed -i '' '/XCRemoteSwiftPackageReference "swiftui-cached-async-image"/,/};/{
            s/branch = main;/kind = upToNextMajorVersion;/
            s/kind = branch;/minimumVersion = 1.9.0;/
            s/minimumVersion = [0-9.][0-9.]*;/minimumVersion = 1.9.0;/
        }' "${PROJECT}/project.pbxproj"
        echo "  Fixed swiftui-cached-async-image package"
    fi

    # Fix SwiftCBOR (master branch tracking causes issues)
    if grep -q 'XCRemoteSwiftPackageReference "SwiftCBOR"' "${PROJECT}/project.pbxproj" 2>/dev/null; then
        sed -i '' '/XCRemoteSwiftPackageReference "SwiftCBOR"/,/};/{
            s/branch = master;/kind = upToNextMajorVersion;/
            s/kind = branch;/minimumVersion = 0.4.0;/
            s/minimumVersion = [0-9.][0-9.]*;/minimumVersion = 0.4.0;/
        }' "${PROJECT}/project.pbxproj"
        echo "  Fixed SwiftCBOR package"
    fi

    # Clear SPM cache to avoid stale manifests
    rm -rf ~/Library/Caches/org.swift.swiftpm/manifests 2>/dev/null || true
    rm -rf "${SOURCE_DIR}/Blink.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" 2>/dev/null || true
}

# Function to fix hardcoded TEAM_ID in project file
fix_team_id() {
    local PROJECT_FILE="${PROJECT}/project.pbxproj"
    local HARDCODED_TEAM="A2H2CL32AG"

    if grep -q "$HARDCODED_TEAM" "$PROJECT_FILE" 2>/dev/null; then
        echo "Fixing hardcoded TEAM_ID in project..."
        sed -i '' "s/${HARDCODED_TEAM}/\${TEAM_ID}/g" "$PROJECT_FILE"
        echo "  Replaced $HARDCODED_TEAM with \${TEAM_ID}"
    fi
}

# Function to remove paywall (GPL sideload build)
patch_remove_paywall() {
    echo "Patching: Removing paywall for GPL sideload build..."

    local ENTITLEMENTS_FILE="${SOURCE_DIR}/Blink/Subscriptions/EntitlementsManager.swift"

    if [ -f "$ENTITLEMENTS_FILE" ]; then
        python3 - "$ENTITLEMENTS_FILE" << 'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

def replace_func(name, body_lines):
    pattern = re.compile(rf"\bpublic func {re.escape(name)}\b")
    m = pattern.search(data)
    if not m:
        return data, False

    line_start = data.rfind("\n", 0, m.start()) + 1
    line_end = data.find("\n", m.start())
    if line_end == -1:
        line_end = len(data)
    indent = re.match(r"[ \\t]*", data[line_start:line_end]).group(0)

    brace_open = data.find("{", m.end())
    if brace_open == -1:
        return data, False

    depth = 0
    i = brace_open
    in_string = False
    in_line_comment = False
    in_block_comment = False
    while i < len(data):
        ch = data[i]
        nxt = data[i + 1] if i + 1 < len(data) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == "\"":
                in_string = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        if ch == "\"":
            in_string = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                brace_close = i
                break
        i += 1
    else:
        return data, False

    inner_indent = indent + "  "
    new_body = "\n".join([inner_indent + line for line in body_lines])
    new_data = data[:brace_open + 1] + "\n" + new_body + "\n" + indent + "}" + data[brace_close + 1:]
    return new_data, True

changed = False
data, did_change = replace_func(
    "currentPlanName",
    [
        "// BLINK_WRAPPER_PATCH",
        "return \"GPL Sideload Build\"",
    ],
)
changed = changed or did_change

data, did_change = replace_func(
    "customerTier",
    [
        "// BLINK_WRAPPER_PATCH",
        "return CustomerTier.Classic",
    ],
)
changed = changed or did_change

data, did_change = replace_func(
    "hasActiveSubscriptions",
    [
        "// BLINK_WRAPPER_PATCH",
        "return true",
    ],
)
changed = changed or did_change

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data)
PY

        echo "  Paywall removed (function body replacement)"
    else
        echo "  Warning: EntitlementsManager.swift not found"
    fi
}

# Patch to skip Migrator (uses FileProvider APIs that don't work with sideloading)
patch_skip_migrator() {
    echo "Patching: Skipping Migrator for sideload build..."

    local APP_DELEGATE="${SOURCE_DIR}/Blink/AppDelegate.m"

    if [ -f "$APP_DELEGATE" ]; then
        # Comment out [Migrator perform]; call
        if grep -q '^\s*\[Migrator perform\];' "$APP_DELEGATE" 2>/dev/null; then
            sed -i '' 's/^\([[:space:]]*\)\[Migrator perform\];/\1\/\/ [Migrator perform]; \/\/ Disabled for sideload - uses FileProvider APIs/' "$APP_DELEGATE"
            echo "  Migrator disabled in AppDelegate.m"
        elif grep -q '// \[Migrator perform\];' "$APP_DELEGATE" 2>/dev/null; then
            echo "  Migrator already disabled"
        else
            echo "  Warning: Could not find Migrator call in AppDelegate.m"
        fi
    else
        echo "  Warning: AppDelegate.m not found"
    fi
}

# Patch to guard FileProvider APIs when extensions are missing (sideload)
patch_fileprovider_sideload() {
    echo "Patching: Guarding FileProvider APIs for sideload build..."

    local FP_DOMAIN="${SOURCE_DIR}/Settings/Model/FileProviderDomain.swift"
    local MIGRATION_FILE="${SOURCE_DIR}/Blink/Migrator/1810Migration.swift"
    local APP_DELEGATE="${SOURCE_DIR}/Blink/AppDelegate.m"

    if [ -f "$FP_DOMAIN" ]; then
        python3 - "$FP_DOMAIN" << 'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

changed = False

if "FileProviderAvailability.isAvailable" not in data:
    pattern = re.compile(r'(^[ \t]*)@objc static func syncWithBKHosts\(\) \{', re.M)
    match = pattern.search(data)
    if match:
        indent = match.group(1)
        inner_indent = indent + "  "
        guard_block = (
            "\n"
            f"{inner_indent}guard FileProviderAvailability.isAvailable else {{\n"
            f"{inner_indent}  return\n"
            f"{inner_indent}}}\n"
        )
        data = data[:match.end()] + guard_block + data[match.end():]
        changed = True

if "final class FileProviderAvailability" not in data:
    availability_block = (
        "\n\n"
        "@objc final class FileProviderAvailability: NSObject {\n"
        "  @objc static let isAvailable: Bool = {\n"
        "    guard let pluginsURL = Bundle.main.builtInPlugInsURL else {\n"
        "      return false\n"
        "    }\n"
        "    guard let pluginURLs = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) else {\n"
        "      return false\n"
        "    }\n\n"
        "    for url in pluginURLs where url.pathExtension == \"appex\" {\n"
        "      guard\n"
        "        let bundle = Bundle(url: url),\n"
        "        let extensionInfo = bundle.infoDictionary?[\"NSExtension\"] as? [String: Any],\n"
        "        let pointIdentifier = extensionInfo[\"NSExtensionPointIdentifier\"] as? String\n"
        "      else {\n"
        "        continue\n"
        "      }\n\n"
        "      if pointIdentifier == \"com.apple.fileprovider-nonui\" ||\n"
        "         pointIdentifier == \"com.apple.fileprovider\" ||\n"
        "         pointIdentifier == \"com.apple.fileprovider-replicated\" {\n"
        "        return true\n"
        "      }\n"
        "    }\n\n"
        "    return false\n"
        "  }()\n"
        "}\n"
    )
    data = data.rstrip() + availability_block
    changed = True

if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data)
PY
        echo "  FileProviderDomain guards applied"
    else
        echo "  Warning: FileProviderDomain.swift not found"
    fi

    if [ -f "$MIGRATION_FILE" ]; then
        python3 - "$MIGRATION_FILE" << 'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

if "FileProviderAvailability.isAvailable" in data:
    sys.exit(0)

pattern = re.compile(r'(^[ \t]*)private func deleteFileProviderStorage\(\) \{', re.M)
match = pattern.search(data)
if not match:
    sys.exit(0)

indent = match.group(1)
inner_indent = indent + "  "
guard_block = (
    "\n"
    f"{inner_indent}guard FileProviderAvailability.isAvailable else {{\n"
    f"{inner_indent}  return\n"
    f"{inner_indent}}}\n"
)

data = data[:match.end()] + guard_block + data[match.end():]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data)
PY
        echo "  Migrator FileProvider guard applied"
    else
        echo "  Warning: 1810Migration.swift not found"
    fi

    if [ -f "$APP_DELEGATE" ]; then
        python3 - "$APP_DELEGATE" << 'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()

if "FileProviderAvailability isAvailable" in data:
    sys.exit(0)

lines = data.splitlines(keepends=True)
for idx, line in enumerate(lines):
    if "_NSFileProviderManager syncWithBKHosts" in line:
        indent = re.match(r"[ \t]*", line).group(0)
        lines[idx:idx + 1] = [
            f"{indent}if ([FileProviderAvailability isAvailable]) {{\n",
            f"{indent}  [_NSFileProviderManager syncWithBKHosts];\n",
            f"{indent}}}\n",
        ]
        break
else:
    sys.exit(0)

with open(path, "w", encoding="utf-8") as fh:
    fh.write("".join(lines))
PY
        echo "  AppDelegate FileProvider guard applied"
    else
        echo "  Warning: AppDelegate.m not found"
    fi
}

# Function to fix get_resources.sh for repeated runs
fix_get_resources_script() {
    local SCRIPT_FILE="${SOURCE_DIR}/get_resources.sh"

    if [ -f "$SCRIPT_FILE" ] && grep -q 'mv runtime/\*' "$SCRIPT_FILE" 2>/dev/null; then
        echo "Fixing get_resources.sh for repeated runs..."
        sed -i '' 's/unzip runtime.zip && mv runtime\/\* .\/ && rm runtime.zip/unzip -o runtime.zip \&\& cp -rf runtime\/* .\/ \&\& rm -rf runtime runtime.zip/' "$SCRIPT_FILE"
    fi
}

# Inject SideloadFix.dylib from https://github.com/waruhachi/SideloadFix
# Fixes App Group containers and keychain access for sideloaded apps
inject_sideload_fix() {
    local APP_BUNDLE="$1"
    local APP_NAME=$(basename "$APP_BUNDLE" .app)
    local FRAMEWORKS_DIR="$APP_BUNDLE/Frameworks"
    local DYLIB_URL="https://github.com/waruhachi/SideloadFix/releases/download/release/SideloadFix.dylib"
    local DYLIB_PATH="${SCRIPT_DIR}/.cache/SideloadFix.dylib"
    local INSERT_DYLIB="${SCRIPT_DIR}/.cache/insert_dylib"

    echo "Injecting SideloadFix.dylib..."
    mkdir -p "${SCRIPT_DIR}/.cache"

    # Download SideloadFix.dylib if not cached
    if [ ! -f "$DYLIB_PATH" ]; then
        echo "  Downloading SideloadFix.dylib..."
        curl -sL "$DYLIB_URL" -o "$DYLIB_PATH"
    fi

    # Build insert_dylib if not cached
    if [ ! -f "$INSERT_DYLIB" ]; then
        echo "  Building insert_dylib..."
        local TEMP_DIR=$(mktemp -d)
        git clone --depth 1 https://github.com/tyilo/insert_dylib.git "$TEMP_DIR" 2>/dev/null
        clang -o "$INSERT_DYLIB" "$TEMP_DIR/insert_dylib/main.c" -framework Foundation 2>/dev/null
        rm -rf "$TEMP_DIR"
    fi

    # Copy dylib to Frameworks
    mkdir -p "$FRAMEWORKS_DIR"
    cp "$DYLIB_PATH" "$FRAMEWORKS_DIR/"

    # Inject load command
    chmod +x "$INSERT_DYLIB"
    "$INSERT_DYLIB" --strip-codesig --inplace \
        "@executable_path/Frameworks/SideloadFix.dylib" \
        "$APP_BUNDLE/$APP_NAME" 2>/dev/null || true

    echo "  Injected SideloadFix.dylib"
}

# Function to create sideload-friendly entitlements
create_sideload_entitlements() {
    echo "Creating sideload-friendly entitlements..."

    local ENTITLEMENTS_FILE="${SOURCE_DIR}/Blink/Blink-sideload.entitlements"

    cat > "$ENTITLEMENTS_FILE" << 'ENTITLEMENTS_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.default-data-protection</key>
	<string>NSFileProtectionComplete</string>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
</dict>
</plist>
ENTITLEMENTS_EOF

    echo "  Created Blink-sideload.entitlements"
}

# Function to setup/clone repository
setup_repository() {
    if [ -d "$SOURCE_DIR" ]; then
        if [ "$SOURCE_OVERWRITE" = true ]; then
            echo "Removing existing source directory (--overwrite)..."
            rm -rf "$SOURCE_DIR"
        elif [ "$SOURCE_UPDATE" = true ]; then
            echo "Updating existing source directory (--update)..."
            cd "$SOURCE_DIR"

            echo "Fetching latest changes..."
            git fetch --all --tags

            echo "Checking out $VERSION..."
            git checkout "$VERSION"
            git submodule update --init --recursive

            echo "Running framework setup..."
            ./get_frameworks.sh

            fix_get_resources_script
            echo "Running resource setup..."
            ./get_resources.sh

            echo "Cleaning Xcode workspace..."
            rm -rf Blink.xcodeproj/project.xcworkspace/xcshareddata/

            fix_package_dependencies
            fix_team_id
            patch_remove_paywall
            patch_skip_migrator
            patch_fileprovider_sideload
            create_sideload_entitlements
            return 0
        else
            # Default: reuse existing source silently
            echo "Using existing source directory..."
            echo "  (Use --update to fetch latest, --overwrite to re-clone)"
            cd "$SOURCE_DIR"

            # Still apply patches in case they haven't been applied
            fix_package_dependencies
            fix_team_id
            patch_remove_paywall
            patch_skip_migrator
            patch_fileprovider_sideload
            create_sideload_entitlements
            return 0
        fi
    fi

    echo "Cloning Blink repository (version: $VERSION)..."
    git clone --recursive --branch "$VERSION" https://github.com/blinksh/blink.git "$SOURCE_DIR"

    cd "$SOURCE_DIR"

    echo "Running framework setup..."
    ./get_frameworks.sh

    fix_get_resources_script
    echo "Running resource setup..."
    ./get_resources.sh

    if [ ! -f "developer_setup.xcconfig" ]; then
        echo "Creating developer_setup.xcconfig from template..."
        cp template_setup.xcconfig developer_setup.xcconfig
    fi

    echo "Cleaning Xcode workspace..."
    rm -rf Blink.xcodeproj/project.xcworkspace/xcshareddata/

    fix_package_dependencies
    fix_team_id
    patch_remove_paywall
    patch_skip_migrator
    patch_fileprovider_sideload
    create_sideload_entitlements
}

# Function to resolve packages
resolve_packages() {
    echo ""
    echo "Resolving package dependencies..."
    xcodebuild -resolvePackageDependencies \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        2>&1 | grep -E "(Resolved|Fetching|Checking out|error:|warning:)" || true
}

# Function to run xcodebuild with optional xcpretty and logging
run_xcodebuild() {
    mkdir -p "$(dirname "$BUILD_LOG")"
    echo "Build log: $BUILD_LOG"

    if command -v xcpretty &> /dev/null; then
        "$@" 2>&1 | tee "$BUILD_LOG" | xcpretty
    else
        "$@" 2>&1 | tee "$BUILD_LOG"
    fi
}

# Function to build
build_app() {
    local EXTRA_FLAGS=""

    if [ "$DO_CLEAN" = true ]; then
        EXTRA_FLAGS="clean build"
    else
        EXTRA_FLAGS="build"
    fi

    echo ""
    echo "Building Blink Shell..."
    echo ""

    mkdir -p "$BUILD_DIR"

    if [ "$DO_SIMULATOR" = true ]; then
        # Build and run in iOS Simulator
        echo "Building for iOS Simulator..."

        local SIMULATOR_ID=""

        # Check if a specific simulator was requested
        if [ -n "$TARGET_SIMULATOR" ]; then
            SIMULATOR_ID=$(device_search "$TARGET_SIMULATOR" "simulator")
            if [ -z "$SIMULATOR_ID" ]; then
                echo "Error: Could not find simulator matching '$TARGET_SIMULATOR'"
                echo ""
                echo "Available simulators:"
                list_simulators
                exit 1
            fi
            echo "Found simulator: $SIMULATOR_ID"
        else
            # Auto-select a simulator
            SIMULATOR_ID=$(xcrun simctl list devices available | grep -E "iPhone (15|16)" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')

            if [ -z "$SIMULATOR_ID" ]; then
                echo "No suitable iPhone simulator found. Creating one..."
                SIMULATOR_ID=$(xcrun simctl create "iPhone 15" "com.apple.CoreSimulator.SimDeviceType.iPhone-15")
            fi
        fi

        echo "Using simulator: $SIMULATOR_ID"
        xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true

        run_xcodebuild xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "id=$SIMULATOR_ID" \
            -derivedDataPath "${BUILD_DIR}/DerivedData" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            ENABLE_DEBUG_DYLIB=NO \
            $EXTRA_FLAGS

        # Open Simulator and launch app
        open -a Simulator
        sleep 2

        # Find and install the app
        APP_PATH=$(find "${BUILD_DIR}/DerivedData" -name "Blink.app" -path "*Debug-iphonesimulator*" | head -1)
        if [ -n "$APP_PATH" ]; then
            xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
            xcrun simctl launch "$SIMULATOR_ID" sh.blink.blinkshell
            echo "Blink launched in simulator"
        else
            echo "Error: Could not find simulator build"
            exit 1
        fi

    elif [ "$DO_INSTALL" = true ]; then
        # Build and install to connected device
        echo "Building and installing to connected device..."

        # Verify provisioning profile before building
        if ! verify_provisioning_profile; then
            exit 1
        fi

        local DEVICE_ID=""

        # Check if a specific device was requested
        if [ -n "$TARGET_DEVICE" ]; then
            DEVICE_ID=$(device_search "$TARGET_DEVICE" "device")
            if [ -z "$DEVICE_ID" ]; then
                echo "Error: Could not find device matching '$TARGET_DEVICE'"
                echo ""
                echo "Available devices:"
                list_devices
                exit 1
            fi
            echo "Found device: $DEVICE_ID"
        else
            # Auto-select a device
            DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -E "iPhone|iPad" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')

            if [ -z "$DEVICE_ID" ]; then
                echo "Error: No iOS device connected. Please connect a device and try again."
                echo ""
                echo "Use --devices to list available devices."
                exit 1
            fi
        fi

        echo "Installing to device: $DEVICE_ID"

        run_xcodebuild xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "id=$DEVICE_ID" \
            -derivedDataPath "${BUILD_DIR}/DerivedData" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            $EXTRA_FLAGS
    elif [ "$DO_ARCHIVE" = true ]; then
        # Build archive
        # Verify provisioning profile before building
        if ! verify_provisioning_profile; then
            exit 1
        fi

        ARCHIVE_PATH="${BUILD_DIR}/Blink.xcarchive"
        echo "Creating archive at: $ARCHIVE_PATH"

        run_xcodebuild xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "${BUILD_DIR}/DerivedData" \
            -archivePath "$ARCHIVE_PATH" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            archive

        mkdir -p "$OUTPUT_DIR"
        OUTPUT_ARCHIVE_PATH="${OUTPUT_DIR}/Blink-${VERSION}.xcarchive"
        if [ "$KEEP_BUILD" = true ]; then
            cp -R "$ARCHIVE_PATH" "$OUTPUT_ARCHIVE_PATH"
        else
            mv "$ARCHIVE_PATH" "$OUTPUT_ARCHIVE_PATH"
        fi

        echo ""
        echo "Archive created: $OUTPUT_ARCHIVE_PATH"
    elif [ "$DO_SIGNED_IPA" = true ]; then
        # Build signed IPA (requires developer account)
        # Verify provisioning profile before building
        if ! verify_provisioning_profile; then
            exit 1
        fi

        ARCHIVE_PATH="${BUILD_DIR}/Blink.xcarchive"
        echo "Creating signed archive..."

        run_xcodebuild xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "${BUILD_DIR}/DerivedData" \
            -archivePath "$ARCHIVE_PATH" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            archive

        echo ""
        echo "Exporting signed IPA..."

        # Create export options plist
        EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
        cat > "$EXPORT_OPTIONS" << 'EXPORT_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
EXPORT_EOF

        EXPORT_PATH="${BUILD_DIR}/Export"
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportPath "$EXPORT_PATH" \
            -exportOptionsPlist "$EXPORT_OPTIONS"

        # Find the exported IPA
        EXPORTED_IPA=$(find "$EXPORT_PATH" -name "*.ipa" | head -1)
        if [ -n "$EXPORTED_IPA" ]; then
            mkdir -p "$OUTPUT_DIR"
            OUTPUT_IPA_PATH="${OUTPUT_DIR}/Blink-signed-${VERSION}.ipa"
            if [ "$KEEP_BUILD" = true ]; then
                cp -f "$EXPORTED_IPA" "$OUTPUT_IPA_PATH"
            else
                mv "$EXPORTED_IPA" "$OUTPUT_IPA_PATH"
            fi
            echo "Created: $OUTPUT_IPA_PATH"
        else
            echo "Error: Export failed - IPA not found"
            exit 1
        fi
    else
        # Generic iOS build (unsigned .ipa for sideloading)
        # Use sideload-friendly entitlements (no iCloud, Push, etc.)
        run_xcodebuild xcodebuild \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -derivedDataPath "${BUILD_DIR}/DerivedData" \
            CONFIGURATION_BUILD_DIR="${BUILD_DIR}/Products" \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGN_ENTITLEMENTS="${SOURCE_DIR}/Blink/Blink-sideload.entitlements" \
            DEAD_CODE_STRIPPING=NO \
            ENABLE_PREVIEWS=NO \
            $EXTRA_FLAGS

        # Package as unsigned .ipa
        echo ""
        echo "Packaging unsigned .ipa for sideloading..."
        APP_PATH="${BUILD_DIR}/Products/Blink.app"
        IPA_PATH="${BUILD_DIR}/Blink-unsigned.ipa"
        OUTPUT_IPA_PATH="${OUTPUT_DIR}/Blink-unsigned-${VERSION}.ipa"

        if [ -d "$APP_PATH" ]; then
            # Create Payload directory structure
            PAYLOAD_DIR="${BUILD_DIR}/Payload"
            rm -rf "$PAYLOAD_DIR"
            mkdir -p "$PAYLOAD_DIR"
            cp -r "$APP_PATH" "$PAYLOAD_DIR/"

            # Remove app extensions that require entitlements incompatible with sideloading
            echo "Removing incompatible app extensions..."
            rm -rf "$PAYLOAD_DIR/Blink.app/PlugIns"

            # Inject SideloadFix.dylib for App Group and keychain fixes
            inject_sideload_fix "$PAYLOAD_DIR/Blink.app"

            # Create .ipa (which is just a zip file)
            cd "$BUILD_DIR"
            rm -f "Blink-unsigned.ipa"
            zip -r -q "Blink-unsigned.ipa" Payload
            rm -rf "$PAYLOAD_DIR"
            cd "$SCRIPT_DIR"

            mkdir -p "$OUTPUT_DIR"
            if [ "$KEEP_BUILD" = true ]; then
                cp -f "$IPA_PATH" "$OUTPUT_IPA_PATH"
            else
                mv "$IPA_PATH" "$OUTPUT_IPA_PATH"
            fi

            echo "Created: $OUTPUT_IPA_PATH"
        else
            echo "Error: Build failed - Blink.app not found"
            exit 1
        fi
    fi
}

# Main execution
preflight_checks

# Handle device/simulator listing (no source setup needed)
if [ "$DO_LIST_DEVICES" = true ]; then
    list_devices
    exit 0
fi

if [ "$DO_LIST_SIMULATORS" = true ]; then
    list_simulators
    exit 0
fi

setup_repository

if [ "$SETUP_ONLY" = true ]; then
    echo ""
    echo "=================================="
    echo "Setup complete!"
    echo "=================================="
    echo ""
    echo "Next steps:"
    echo "1. Edit developer_setup.xcconfig and update TEAM_ID:"
    echo "   nano $SOURCE_DIR/developer_setup.xcconfig"
    echo ""
    echo "2. Build from command line:"
    echo "   $0 --build"
    echo ""
    echo "3. Or open in Xcode:"
    echo "   open $PROJECT"
    exit 0
fi

resolve_packages

if [ "$DO_BUILD" = true ] || [ "$DO_INSTALL" = true ] || [ "$DO_ARCHIVE" = true ] || [ "$DO_SIMULATOR" = true ] || [ "$DO_SIGNED_IPA" = true ]; then
    build_app
    if [ "$KEEP_BUILD" = false ]; then
        echo ""
        echo "Cleaning build output..."
        rm -rf "$BUILD_DIR"
    fi
    if [ "$KEEP_SOURCE" = false ]; then
        echo "Cleaning source checkout..."
        rm -rf "$SOURCE_DIR"
    fi
fi

echo ""
echo "=================================="
echo "Build complete!"
echo "=================================="
echo ""

if [ "$DO_SIMULATOR" = true ]; then
    echo "Blink is running in the iOS Simulator."
elif [ "$DO_INSTALL" = true ]; then
    echo "App has been installed to your device."
elif [ "$DO_ARCHIVE" = true ]; then
    echo "Archive location: ${OUTPUT_ARCHIVE_PATH}"
elif [ "$DO_SIGNED_IPA" = true ]; then
    echo "Signed IPA: ${OUTPUT_IPA_PATH}"
    echo ""
    echo "This IPA can be installed directly via Xcode, Apple Configurator, or similar tools."
else
    echo "Unsigned IPA: ${OUTPUT_IPA_PATH}"
    echo ""
    echo "Upload this .ipa to your signing service for sideloading."
fi
echo ""
