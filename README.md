# poppler-utils

[poppler](https://poppler.freedesktop.org/) PDF command-line utilities —
`pdfinfo`, `pdftotext`, `pdftoppm`, `pdftocairo`, `pdfimages`, `pdffonts`,
`pdfdetach`, `pdfattach`, `pdfseparate`, `pdftops`, `pdftohtml` and `pdfunite` —
in a single self-contained binary built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/poppler-utils/actions/workflows/poppler-utils.yml/badge.svg)](https://github.com/unpins/poppler-utils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with
[`unpin`](https://github.com/unpins/unpin): `unpin install poppler-utils`.

## Usage

Run it with [unpin](https://github.com/unpins/unpin) — a bare `poppler-utils`
runs `pdfinfo`:

```bash
unpin poppler-utils document.pdf
```

To install the `pdfinfo`, `pdftotext`, `pdftoppm`, … commands onto your PATH:

```bash
unpin install poppler-utils
pdftotext document.pdf -        # extract text to stdout
pdfimages -all document.pdf img # extract images
pdftoppm -png -r 150 document.pdf page
```

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

- One multicall binary holds all 12 programs. `poppler-utils` is the canonical
  name (a busybox-style dispatcher); each tool dispatches on `argv[0]`. They
  share one copy of `libpoppler` and its dependency chain, linked once — the
  per-tool overhead is only each `main` plus a handful of helper objects.
- The CMap / encoding data (the separate `poppler-data` package — Adobe CJK
  character collections and the extended Unicode maps) is **embedded** in the
  binary as a compressed archive, so there is no companion `share/poppler`
  directory; the utils resolve predefined CMaps and `-enc Big5`/`GBK`/`Shift-JIS`
  /… with no on-disk data. Each tool's man page is embedded too —
  `unpin man poppler-utils pdftotext`.
- Loading PDFs over `http://` / `https://` is kept (libcurl); on Linux the TLS
  backend is mbedtls and only http/https are wired (the rest of curl's protocols
  are not useful to a PDF loader and would bloat the static binary). macOS and
  Windows use their native curl crypto.
- Windows is cross-built with mingw; the `.exe` has no companion DLLs. macOS
  links the system frameworks only (no `libc++.1.dylib` — static libc++ is
  folded in).
- `pdftops doc.pdf '|command'` still pipes PostScript to an external command
  when the output path starts with `|` (the xpdf-legacy feature); that is the
  only case any util shells out, and only when you ask for it explicitly.

### Dropped features

Each is off only because it cannot be built into a single static binary, and
each loses at most one capability:

- **Digital signatures** (`pdfsig`, and `-sign` in `pdftocairo`). The signature
  backends are NSS or GPGME: NSS cannot link static (its NSPR base builds
  shared-only and its crypto core is a `dlopen`ed PKCS#11 module), and GPGME
  validates by spawning the GnuPG `gpgsm` daemon suite. `pdfsig` is therefore
  not shipped.
- **TIFF output** (`pdftoppm -tiff`, `pdftocairo -tiff`). libtiff's installed
  static CMake config references an orphan target, so `find_package(TIFF)` fails
  to configure. PNG / JPEG / PPM / PS / EPS / SVG / PDF output are unaffected.
