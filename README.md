# OpenWrt IPK to APK Converter (`openwrt-ipk2apk.py`)

A tool to convert binary OpenWrt packages from the old IPK (`opkg`) format to the new strict APK v2 format.

As OpenWrt transitions its package management system from `opkg` to Alpine Linux's `apk`, older `.ipk` packages become incompatible. This script acts as a bridge, repacking the contents and metadata of an `.ipk` into a fully native `.apk` v2 archive, ready to be installed via `apk add`.

## 🚀 Features

- **No external dependencies:** Written in pure Python 3 using only standard libraries.
- **Automatic Metadata Translation:** Converts `control` file properties into the required `.PKGINFO` format, including `Depends`, `Provides`, `Conflicts`, `Replaces`, `Homepage`, and `License`.
- **Dependency Parsing:** Strips legacy version constraints and formats dependencies for `apk`.
- **Install Script Mapping:** Automatically renames `preinst`/`postinst`/`prerm`/`postrm` to their APK equivalents (`.pre-install`, etc.).
- **Strict APK v2 Compliance:** * Calculates and injects `APK-TOOLS.checksum.SHA1` into PAX extended headers for every data file.
  - Ensures the Control stream is strictly in `GNU_FORMAT` so `.PKGINFO` is perfectly readable by `apk-tools`.
  - Properly strips EOF null blocks between tar streams to allow valid GZIP concatenation.

## 📋 Prerequisites

- Python 3.6 or newer.
- No additional `pip` packages are required.

## 🛠️ Usage

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

Install the converted package on your OpenWrt router:

```bash
# Important: Use the local path prefix './' so apk knows it's a local file, not a repository query
apk add --allow-untrusted ./package_name_1.0.0_arch.apk
```

## 🧠 How it Works (The APK v2 Magic)

The Alpine/OpenWrt APK v2 format is essentially two separate GZIP streams (Control and Data) concatenated into a single file. However, `apk-tools` is extremely pedantic about how these streams are formatted:

1. **The Control Stream:** Must be in standard `GNU_FORMAT`. The very first file *must* be `.PKGINFO` without any extended PAX headers, otherwise `apk info` and `apk add` will silently fail to read the metadata.
1. **The Data Stream:** Must be in `PAX_FORMAT`. `apk-tools` requires every single regular file to have a SHA1 checksum. Since standard `tar` doesn't support this, the checksum is injected dynamically into a hidden PAX extended header (`APK-TOOLS.checksum.SHA1`) immediately preceding the file.
1. **Stream Concatenation:** Standard `tarfile` generation appends zero-byte EOF (End of File) blocks at the end of an archive. If these are gzipped and concatenated, `apk` stops reading after the Control stream. This script intercepts the byte stream and surgically removes these EOF blocks before concatenating the Control and Data streams.

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
