# poppler-utils

[poppler](https://poppler.freedesktop.org/)'s PDF command-line utilities —
`pdfinfo`, `pdftotext`, `pdftoppm`, and nine more. A single self-contained
binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/poppler-utils/actions/workflows/poppler-utils.yml/badge.svg)](https://github.com/unpins/poppler-utils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with
[`unpin`](https://github.com/unpins/unpin): `unpin install poppler-utils`.

## Usage

Run the `poppler-utils` program with [unpin](https://github.com/unpins/unpin) —
a bare `poppler-utils` runs `pdfinfo`:

```bash
unpin poppler-utils document.pdf
```

To install the `pdfinfo`, `pdftotext`, `pdftoppm`, … commands onto your PATH:

```bash
unpin install poppler-utils
pdftotext document.pdf -        # extract text to stdout
```

`unpin info poppler-utils` lists all 12 commands.

## Man pages

Each tool's man page is embedded — read one with
`unpin man poppler-utils <tool>` (e.g. `unpin man poppler-utils pdftotext`).

## Build locally

```bash
nix build github:unpins/poppler-utils
./result/bin/poppler-utils -v
```

Or run directly:

```bash
nix run github:unpins/poppler-utils -- -v
```

The first invocation will offer to add the
[unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come
pre-built.

## Manual download

The [Releases](https://github.com/unpins/poppler-utils/releases) page has
standalone binaries for manual download.

## Build notes

- One multicall binary holds all 12 programs; `poppler-utils` is the canonical
  name (a busybox-style dispatcher) and each tool dispatches on `argv[0]`,
  sharing a single linked copy of `libpoppler`.
- The `poppler-data` CMap / encoding tables (Adobe CJK collections, extended
  Unicode maps) are embedded as a compressed archive, so `-enc Big5`/`GBK`/… and
  predefined CMaps resolve with no on-disk `share/poppler` directory.
- PDF loading over `http(s)` is kept via libcurl — mbedtls on Linux, native curl
  crypto on macOS/Windows; only http/https are wired.
- Windows is cross-built with mingw and macOS links the system frameworks only;
  neither ships a companion DLL or dylib.

### Dropped features

Each is off only because it cannot link into a single static binary:

- **Digital signatures** (`pdfsig`, `pdftocairo -sign`): the NSS and GPGME
  backends need a `dlopen`ed PKCS#11 module / the external `gpgsm` daemon.
- **TIFF output** (`pdftoppm -tiff`, `pdftocairo -tiff`): libtiff's static CMake
  config references an orphan target, so `find_package(TIFF)` fails. PNG / JPEG /
  PPM / PS / EPS / SVG / PDF output are unaffected.
