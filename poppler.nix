# Configured static poppler-utils base, shared by the native `build`
# (pkgsStatic: 6 Linux arches + 2 darwin) and `windowsBuild` (mingwStaticCross)
# paths in flake.nix. Returns the poppler-utils derivation with every CLI util
# built but NOT yet folded — multicall.nix relinks the objects into one binary.
#
# What is turned off and why (each loses at most one capability — see README
# Build notes):
#   - NSS3 + GPGME (signatures): the only static-incompatible path. NSS pulls
#     p11-kit, which declares `badPlatforms = isStatic` (it is a dlopen PKCS#11
#     module loader); even past that, NSPR builds shared-only and nixpkgs strips
#     nss's .a. GPGME's S/MIME backend spawns the gpgsm daemon suite. Dropping
#     both loses only `pdfsig`.
#   - libtiff: its installed static cmake config references an orphan
#     `Deflate::Deflate` target, so find_package(TIFF) fails to configure. Only
#     TIFF *output* (pdftoppm -tiff / pdftocairo -tiff) uses it.
#   - glib / cpp bindings: libpoppler-glib / libpoppler-cpp are for GUI / 3rd
#     party consumers, not the CLI utils (pdftocairo is gated on HAVE_CAIRO, not
#     glib). Off keeps the closure to what the utils need.
#   - tests/demos: not shipped; their extra link targets pull expat symbols the
#     util link line doesn't, so disable to keep the build clean.
#
# curl (URL loading, `pdfXXX http://…`) is kept. Per crypto-backend.md the TLS
# backend is mbedtls on musl-Linux (macOS/Windows satisfy crypto via
# CommonCrypto / CNG inside their native curl), and only http/https are wired —
# none of curl's other protocols are useful to a PDF loader, and the full curl
# would drag gss/krb5/idn2/brotli/zstd/libssh2 (the bulk of its static size).
{ pkgs, sp, ulib }:
let
  host = sp.stdenv.hostPlatform;
  isDarwin = host.isDarwin or false;
  isWindows = host.isWindows or false;
  isLinux = (host.isLinux or false) && !isWindows;

  # http/https-only curl for the PDF URL loader. Base on curlMinimal, NOT the
  # full `curl`: the extras the full build enables (gss, idn2, brotli, zstd,
  # libssh2, ldap) are not http/https and together — not the TLS lib — dominate
  # curl's static footprint. scpSupport off is load-bearing on EVERY platform:
  #  - Linux: curlMinimal defaults it to zlibSupport (=true) -> libssh2, which
  #    uses OpenSSL as its crypto backend, dragging the whole OpenSSL closure
  #    (~6.8 MB) back in even though curl is on mbedTLS.
  #  - Windows (mingw): the libssh2 build fails to link (`__imp_sendto` — its
  #    sockets need -lws2_32), breaking the whole cross build.
  # http3 off: ngtcp2/nghttp3 (QUIC) needs a QUIC-capable TLS. Linux swaps TLS
  # to mbedTLS (per crypto-backend.md); macOS/Windows keep curlMinimal's default
  # (OpenSSL builds on both — native SecureTransport/Schannel would be smaller
  # but the default is what links cleanly cross).
  curlPdf = (sp.curlMinimal.override ({
    http3Support = false;
    scpSupport = false;
  } // pkgs.lib.optionalAttrs (isLinux || isWindows) {
    # Linux -> mbedTLS; Windows -> Schannel (native, no external lib). Turning
    # OpenSSL off avoids curlMinimal's `--with-openssl` (which on mingw fails to
    # detect the cross OpenSSL and is bigger than Schannel anyway). macOS keeps
    # the default (its OpenSSL builds cleanly cross).
    opensslSupport = false;
  } // pkgs.lib.optionalAttrs isWindows {
    # nghttp2's static lib on mingw defaults to __declspec(dllimport) without
    # NGHTTP2_STATICLIB, so the curl.exe link fails on __imp_nghttp2_*. HTTP/1.1
    # is plenty for a PDF URL loader; drop HTTP/2 on Windows.
    http2Support = false;
  })).overrideAttrs (old: {
    pname = "curl-pdf-http";
    # macOS keeps iconv in a standalone libiconv (not libSystem), so nixpkgs
    # curl carries a bare `-liconv` in NIX_LDFLAGS on darwin. nix-lib's
    # darwinIconvFixed/withDarwinIconv wire the static libiconv into the FINAL
    # mkStandaloneFlake link, but not intermediate deps like this curl — and the
    # engine adapter can't bake libiconv into its stdenv (libiconvReal is built
    # BY that stdenv → recursion), which is why the project fixes iconv per-drv.
    # Under the engine the SDK's dynamic libiconv is gone (SDKROOT, static
    # build), so curl's own configure exe-link test fails "library not found for
    # -liconv / C compiler cannot create executables". Put the engine's static
    # GNU libiconv (sp.libiconv = the set-level libiconvReal swap) on curl's link
    # path so the bare `-liconv` resolves; with all charset-using protocols
    # disabled curl calls no iconv, so nothing is pulled — libcurl.a is unchanged.
    buildInputs = (old.buildInputs or [ ])
      ++ pkgs.lib.optional isDarwin sp.libiconv;
    # Propagate mbedtls (not just buildInputs) so a static consumer linking
    # libcurl.a gets its -L; libcurl.pc's Libs.private lists bare -lmbed*.
    propagatedBuildInputs = (old.propagatedBuildInputs or [ ])
      ++ pkgs.lib.optional isLinux sp.mbedtls;
    configureFlags =
      (builtins.filter (f: f != "--without-ssl") (old.configureFlags or [ ]))
      ++ pkgs.lib.optional isLinux "--with-mbedtls"
      ++ pkgs.lib.optional isWindows "--with-schannel"
      ++ [
        "--disable-ftp" "--disable-file" "--disable-ldap" "--disable-ldaps"
        "--disable-rtsp" "--disable-dict" "--disable-telnet"
        "--disable-tftp" "--disable-pop3" "--disable-imap" "--disable-smb"
        "--disable-smtp" "--disable-gopher" "--disable-mqtt"
      ];
  });
in
sp.poppler-utils.overrideAttrs (old: {
  pname = "poppler-utils";

  # Embed the poppler-data CMap/encoding tree into libpoppler so the utils need
  # no on-disk share/poppler (the directory_iterator enumeration + openFile in
  # GlobalParams.cc are routed to a miniz ZIP compiled into the binary; see
  # ./poppler-data-embed.patch + ./src). poppler-data is arch-independent data,
  # so take it from buildPackages (no target closure on cross).
  patches = (old.patches or [ ]) ++ [ ./poppler-data-embed.patch ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ])
    ++ [ pkgs.buildPackages.zip pkgs.buildPackages.xxd ];

  postPatch = (old.postPatch or "") + ''
    # VFS reader + miniz alongside GlobalParams.cc (its #include "unpin_data_vfs.h"
    # resolves from the same dir).
    cp ${./src/unpin_data_vfs.c} poppler/unpin_data_vfs.c
    cp ${./src/unpin_data_vfs.h} poppler/unpin_data_vfs.h
    cp ${./src/miniz.c}          poppler/miniz.c
    cp ${./src/miniz.h}          poppler/miniz.h
    # Pack the CMap/encoding tree (deterministic order, -X drops extra metadata)
    # and bake it in as a C array (xxd -i, const-ified) — a plain array embeds
    # identically on every target (no per-arch .S section/dialect or .incbin cwd).
    here=$PWD
    ( cd ${pkgs.buildPackages.poppler_data}/share/poppler \
      && zip -9 -X -r -q "$here/poppler/unpin_data.zip" \
           nameToUnicode cidToUnicode unicodeMap cMap )
    xxd -i -n unpin_data_blob poppler/unpin_data.zip \
      | sed 's/^unsigned char/const unsigned char/; s/^unsigned int/const unsigned int/' \
      > poppler/unpin_data_blob.h
    rm -f poppler/unpin_data.zip
    # Add the two C sources to the poppler library target (project enables C).
    substituteInPlace CMakeLists.txt \
      --replace-fail "poppler/GlobalParams.cc" "poppler/GlobalParams.cc
  poppler/unpin_data_vfs.c
  poppler/miniz.c"
  '';

  # static fontconfig.a references expat's XML_* but does not bundle it.
  buildInputs = builtins.filter (x: x != null) (old.buildInputs or [ ]) ++ [ sp.expat ];

  # Drop the static-incompatible deps and swap stock curl for the trimmed
  # http/https-only build (curlPdf) on every platform.
  propagatedBuildInputs =
    let
      kept = builtins.filter
        (x: x != null && !builtins.elem (x.pname or "") [ "nss" "libtiff" ])
        (old.propagatedBuildInputs or [ ]);
    in
    map (x: if (x.pname or "") == "curl" then curlPdf else x) kept;

  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DENABLE_LIBCURL=ON"
    "-DENABLE_NSS3=OFF"
    "-DENABLE_GPGME=OFF"
    "-DENABLE_LIBTIFF=OFF"
    "-DENABLE_GLIB=OFF"
    "-DENABLE_CPP=OFF"
    "-DBUILD_MANUAL_TESTS=OFF"
    "-DBUILD_CPP_TESTS=OFF"
  ];

  # Static fontconfig.a / freetype.a / cairo.a / curl.a leave transitive symbols
  # undefined and freetype<->harfbuzz are mutually recursive; cmake links them in
  # the wrong order with no --static closure. cc-wrapper appends $NIX_LDFLAGS at
  # the END of the link line (passed straight to ld -> bare --start-group, no
  # -Wl,), so drop the full pkg-config --static chain there in one group:
  # resolves ordering + the cycle. preBuild (not preConfigure) so it touches only
  # the ninja link steps, not cmake's own compiler-probe links.
  preBuild = (old.preBuild or "") + ''
    ${pkgs.lib.optionalString isWindows ''
      # cairo's mingw headers default to __declspec(dllimport) unless
      # CAIRO_WIN32_STATIC_BUILD is defined. poppler compiles CairoOutputDev.cc /
      # CairoRescaleBox.cc in the pdftocairo target, which does NOT pick up that
      # define from cairo.pc's Cflags (the mingw-overlay puts it there), so the
      # static cairo link fails on __imp_cairo_*. Define it globally for the
      # whole build.
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -DCAIRO_WIN32_STATIC_BUILD"
    ''}
    pc=''${PKG_CONFIG:-pkg-config}
    mods=""
    for m in fontconfig freetype2 cairo lcms2 libopenjp2 libjpeg libpng16 zlib libcurl; do
      $pc --exists "$m" 2>/dev/null && mods="$mods $m"
    done
    # pkg-config --static may emit driver flags (-pthread, …); NIX_LDFLAGS goes
    # straight to ld, so keep only -l/-L tokens.
    libs=$($pc --libs --static $mods | tr ' ' '\n' | grep -E '^-[lL]' | tr '\n' ' ')
    # GNU ld (Linux/mingw) needs --start-group to absorb the freetype<->harfbuzz
    # back-references; ld64 (darwin) re-scans archives on its own and rejects the
    # group markers, so append the same closure bare there.
    ${if isDarwin
      then ''
        # darwin (engine self-fold): libc++ is linked statically by the engine
        # stdenv itself (cxx=true), so no libc++ shim is needed — a second copy
        # would only collide. Just add the cairo Quartz/CoreText frameworks
        # (cairo-quartz-font.c.o needs CG*/CT*; poppler's per-app links don't pull
        # them) so the per-app links — captured and replayed by the self-fold —
        # resolve them. All four are public, allow-list OK. ld64 re-scans archives
        # on its own, so the closure goes in bare (no --start-group). iconv is
        # wired by nix-lib's darwinIconvFixed on the final drv.
        export NIX_LDFLAGS="$NIX_LDFLAGS $libs -framework ApplicationServices -framework CoreGraphics -framework CoreText -framework CoreFoundation"''
      else ''export NIX_LDFLAGS="$NIX_LDFLAGS --start-group $libs --end-group"''}
  '';
})
