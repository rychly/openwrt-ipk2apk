# OpenWrt IPK-to-APK Converter Suite

Two tools for converting OpenWrt packages across the IPK → APK v2 → APK v3 pipeline:

| Tool                   | Format conversion | Language | Nix package              |
| ---------------------- | ----------------- | -------- | ------------------------ |
| `openwrt-ipk2apk`      | IPK → APK v2      | Python   | `openwrt-ipk2apk`        |
| `convert-apk-v2-to-v3` | APK v2 → APK v3   | Bash     | `apk-v2-to-v3-converter` |

As OpenWrt transitions its package management from `opkg` to Alpine Linux's `apk`, older `.ipk` packages become incompatible, and the OpenWrt SDK's `apk mkndx` may reject the intermediate APK v2 format. These tools bridge the gap — from legacy IPK all the way to the v3 ADB container format that the SDK accepts.

## 🚀 Features

### `openwrt-ipk2apk` (IPK → APK v2)

- **No external dependencies:** Written in pure Python 3 using only standard libraries.
- **Automatic Metadata Translation:** Converts `control` file properties into the required `.PKGINFO` format, including `Depends`, `Provides`, `Conflicts`, `Replaces`, `Homepage`, and `License`.
- **Dependency Parsing:** Translates IPK/Debian-style version constraints (e.g., `libssl (>= 1.1)`) into APK's inline notation (`libssl>=1.1`); OR-alternatives are preserved.
- **Install Script Mapping:** Automatically renames `preinst`/`postinst`/`prerm`/`postrm` to their APK equivalents (`.pre-install`, etc.).
- **Strict APK v2 Compliance:** Calculates and injects `APK-TOOLS.checksum.SHA1` into PAX extended headers for every data file.
  - Ensures the Control stream is strictly in `GNU_FORMAT` so `.PKGINFO` is perfectly readable by `apk-tools`.
  - Properly strips EOF null blocks between tar streams to allow valid GZIP concatenation.

### `convert-apk-v2-to-v3` (APK v2 → APK v3)

- **SDK-compatible output:** Produces APK v3 (ADB container) packages that `apk mkndx` can process without segfaulting.
- **Batch conversion:** Process multiple `.apk` files in a single invocation.
- **In-place conversion:** By default, replaces the input file with the converted v3 output.
- **Stdin support:** Pipe v2 APKs through stdin (`-s`) for scripting and pipelines.
- **Root ownership preservation:** Works with `fakeroot` to keep `root:root` ownership in the archive.
- **Dependency-aware:** Requires `apk-tools` ≥ 3.0 (for `apk mkpkg`), with built-in `--check-deps` verification.

## 📋 Prerequisites

### `openwrt-ipk2apk`

- Python 3.6 or newer.
- No additional `pip` packages are required.

### `convert-apk-v2-to-v3`

- Bash 4+ with `getopt` (from `util-linux`).
- `apk-tools` ≥ 3.0 (provides `apk mkpkg`).
- Standard Unix utilities: `gzip`, `tar`, `coreutils`, `findutils`.
- Optional: `fakeroot` (to preserve `root:root` ownership without running as root).

> All dependencies are automatically provided when using the Nix package.

## 🛠️ Usage

### Nix (recommended)

```bash
# Run directly from the flake
nix run .#openwrt-ipk2apk -- package.ipk
nix run .#convert-apk-v2-to-v3 -- package.apk

# Or install into your profile
nix profile install .#openwrt-ipk2apk
nix profile install .#convert-apk-v2-to-v3
```

### `openwrt-ipk2apk`

Make the script executable:

```bash
chmod +x openwrt-ipk2apk.py
```

Run the conversion:

```bash
# Basic usage (outputs to the same directory with .apk extension)
./openwrt-ipk2apk.py package_name_1.0.0_arch.ipk

# Specify a custom output path
./openwrt-ipk2apk.py package_name_1.0.0_arch.ipk -o /path/to/output/new_package.apk
```

### `convert-apk-v2-to-v3`

```bash
# In-place conversion (overwrites the original file)
convert-apk-v2-to-v3 package.apk

# Write to a separate output file
convert-apk-v2-to-v3 package.apk -o package-v3.apk

# Batch conversion
convert-apk-v2-to-v3 *.apk

# Pipe from stdin
cat package.apk | convert-apk-v2-to-v3 -s -o package-v3.apk

# Verbose output
convert-apk-v2-to-v3 -v package.apk

# Verify all runtime dependencies are available
convert-apk-v2-to-v3 --check-deps
```

### End-to-end: IPK → APK v3

```bash
# Convert IPK to v2, then v2 to v3
./openwrt-ipk2apk.py package_name_1.0.0_arch.ipk
convert-apk-v2-to-v3 package_name_1.0.0_arch.apk

# Install on the router
apk add --allow-untrusted ./package_name_1.0.0_arch.apk
```

> **Tip:** When installing, use the local path prefix `./` so `apk` knows it's a local file, not a repository query.

## 🧠 How it Works

### IPK → APK v2 (`openwrt-ipk2apk`)

The Alpine/OpenWrt APK v2 format is essentially two separate GZIP streams (Control and Data) concatenated into a single file. However, `apk-tools` is extremely pedantic about how these streams are formatted:

1. **The Control Stream:** Must be in standard `GNU_FORMAT`. The very first file _must_ be `.PKGINFO` without any extended PAX headers, otherwise `apk info` and `apk add` will silently fail to read the metadata.
1. **The Data Stream:** Must be in `PAX_FORMAT`. `apk-tools` requires every single regular file to have a SHA1 checksum. Since standard `tar` doesn't support this, the checksum is injected dynamically into a hidden PAX extended header (`APK-TOOLS.checksum.SHA1`) immediately preceding the file.
1. **Stream Concatenation:** Standard `tarfile` generation appends zero-byte EOF (End of File) blocks at the end of an archive. If these are gzipped and concatenated, `apk` stops reading after the Control stream. This script intercepts the byte stream and surgically removes these EOF blocks before concatenating the Control and Data streams.

### APK v2 → APK v3 (`convert-apk-v2-to-v3`)

The v3 format wraps the package content in an Android Debug Bridge (ADB) container, which the OpenWrt SDK expects. The conversion process:

1. **Decompress** the gzip-concatenated v2 streams into a single tar archive.
2. **Split** the archive into control metadata (`.PKGINFO`, install scripts) and data payload (package files).
3. **Rebuild** the package using `apk mkpkg`, which produces a valid v3 ADB container with the correct checksums, metadata, and directory structure.

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
