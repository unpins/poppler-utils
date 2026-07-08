{
  description = "poppler-utils (pdfinfo, pdftotext, pdftoppm, …) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # poppler's 12 CLI utilities folded into one argv[0]-dispatching binary
  # (./multicall.nix), built fully static for 6 Linux arches + Windows + 2
  # macOS. The base poppler config (./poppler.nix) turns off only the
  # static-incompatible bits (NSS/GPGME signatures, libtiff) and the unused
  # glib/cpp bindings; curl URL-loading is kept (mbedtls TLS on Linux). The CMap/
  # encoding data (poppler-data) is embedded in the binary via a miniz ZIP
  # (./src + ./poppler-data-embed.patch), so there is no companion data file.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      mkMulti = pkgs: extra:
        import ./multicall.nix { lib = pkgs.lib // ulib; } extra;

      # Engine path (native Linux): poppler's utils are C++, but ALL external
      # deps are C (cairo/freetype/fontconfig/jpeg/openjpeg/lcms2/curl/expat) —
      # the only C++ is poppler's OWN in-derivation code. So this is a "true
      # aom-like" tier-2: just engine-build poppler-utils itself (→ libc++) and
      # let the bitcode self-fold pack the 12 utils into one binary; no codec
      # chain to rebuild, no external libstdc++ to defeat. One stdenv (lto, with
      # link capture) suffices — there are no asm-carrying C++ codec libs that
      # would need the no-lto ELF stdenv (cf. avif).
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          lto = true;
          captureLinks = true;
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "poppler-utils";
      # A bare `poppler-utils -v` dispatches to pdfinfo (defaultApplet) ->
      # "pdfinfo version 25.10.0". poppler's utils use `-v` for version (a bare
      # `--version` is parsed as a filename), so smoke on `-v`.
      smoke = [ "-v" ];
      smokePattern = "version 2[0-9]\\.";

      # Engine + bitcode self-fold (native Linux): build poppler-utils with the
      # unpin-llvm engine (→ libc++) and self-fold the 12 pdf* utils into one
      # binary. C++ → requires.cxx; pdfinfo is the bare-invocation default.
      engine = "unpin-llvm";
      multicall = {
        defaultProgram = "pdfinfo";
        programs = [
          { name = "pdfattach"; }
          { name = "pdfdetach"; }
          { name = "pdffonts"; }
          { name = "pdfimages"; }
          { name = "pdfinfo"; }
          { name = "pdfseparate"; }
          { name = "pdftocairo"; }
          { name = "pdftohtml"; }
          { name = "pdftoppm"; }
          { name = "pdftops"; }
          { name = "pdftotext"; }
          { name = "pdfunite"; }
        ];
        requires.cxx = true;
        # darwin: the bitcode self-fold relinks the 12 utils from the captured
        # link inputs, but the capture records only `-l`/`-L` (not `-framework`),
        # so the Quartz frameworks cairo-quartz-font.c.o references (CGContext*,
        # CoreText) must be named here for the final fold link too — same list
        # poppler.nix's per-util NIX_LDFLAGS carries. darwin-only in effect (the
        # fold gates `-framework` on isDarwinHost); a no-op on Linux/Windows.
        requires.frameworks = [
          "ApplicationServices"
          "CoreGraphics"
          "CoreText"
          "CoreFoundation"
          # curl's darwin proxy resolver (SCDynamicStoreCopyProxies) +
          # CoreServices, which its per-util link names via libcurl's deps.
          "CoreServices"
          "SystemConfiguration"
        ];
      };

      # The utils are C++. Linux pkgsStatic already links libstdc++ statically.
      # On darwin clang++ would link /usr/lib/libc++.1.dylib (allowlist forbids
      # it), so fold static libc++/libc++abi into the multicall link.
      #
      # The cairo/text-render chain needs nix-lib's cross-within-darwin fixes on
      # macOS (glib/cairo/fontconfig/graphite2 — same set rsvg-convert/ffmpeg
      # use; each short-circuits to prev off darwin), and the libjpeg-turbo RVV
      # fix on riscv64 (its SIMD coverage helper won't compile). Both no-ops
      # elsewhere, so the other arches keep the unmodified (cache-hit) deps.
      build = pkgs:
        let
          host = pkgs.stdenv.hostPlatform;
          # aarch64-darwin is built NATIVELY on macos-14 CI (canExecute → no cross
          # cairo throw), but the local pre-CI check cross-builds it on the Intel
          # Mac (x86_64→aarch64); that cross path needs cairo's ipc fix (below).
          isCrossDarwin = host.isDarwin
            && !(pkgs.stdenv.buildPlatform.canExecute host);
        in
        # Engine path (native Linux AND darwin): build poppler-utils with the
        # unpin-llvm engine stdenv (bitcode LTO + link capture) and return it
        # directly — mkStandaloneFlake's bitcode self-fold packs the 12 utils into
        # one binary. Both platforms self-fold identically; only the per-platform
        # dep fixes below differ. Windows (mingw, no engine → native objects) uses
        # windowsBuild's multicall.nix objcopy fold instead — objcopy cannot
        # rewrite bitcode, so it must NOT run over an engine build.
        let
          eng = engStdenv pkgs;
          sp = (if host.isRiscV
                then pkgs.pkgsStatic.extend (final: prev: {
                  libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
                })
                else pkgs.pkgsStatic).extend (final: prev: {
            poppler-utils = prev.poppler-utils.override { stdenv = eng; };

            # libjpeg-turbo's `bmpsizetest` feeds a crafted BMP header with
            # near-INT_MAX dimensions to check the size-overflow guard rejects it;
            # under the engine (-flto + static) that subprocess is OOM-killed
            # ("Subprocess killed") — it exercises the BMP *reader* (rdbmp.c,
            # tools-only) which never enters the libjpeg.a poppler links (JPEG
            # decode only, covered by the 331 passing codec tests). Same call
            # jpeg-tools makes: build no test suite. Platform-independent (the OOM
            # is engine+static, not arch), so applied on Linux and darwin alike;
            # composes over the riscv64 nativeFixes base above.
            libjpeg = prev.libjpeg.overrideAttrs (o: {
              doCheck = false;
              doInstallCheck = false;
              cmakeFlags = (o.cmakeFlags or [ ]) ++ [ "-DWITH_TESTS=0" ];
            });
          } // (if host.isDarwin then {
            # darwin: the cairo/text-render chain needs nix-lib's cross-within-
            # darwin fixes (glib/graphite2/fontconfig — same set rsvg-convert/ffmpeg
            # use; each short-circuits to prev off the cross-darwin path).
            glib       = ulib.nativeFixes.glib       prev;
            graphite2  = ulib.nativeFixes.graphite2  prev;
            fontconfig = ulib.nativeFixes.fontconfig prev;
            # poppler renders to cairo's image/pdf/ps/svg surfaces, never the X11
            # (xlib) surface — and macOS has no X server — so drop cairo's xlib/xcb
            # backends on darwin. This removes libX11/libxcb from the closure
            # entirely (they otherwise build X11 host tools like makekeys, which the
            # engine mislinks through ld.lld instead of ld64.lld). libcairo.a keeps
            # every surface poppler uses.
            #
            # `x11Support=false;xcbSupport=false` drops libX11/libxcb from cairo's
            # buildInputs (not just its meson backends) — load-bearing: libX11's
            # configure runs a `cpp -undef` probe that aborts under the engine's
            # clang ("defines unix … I don't know what to do"), so it must not enter
            # the closure at all.
            #
            # Native darwin (x86_64 local, aarch64 CI): that override alone is enough
            # — no cross meson-file, so nixpkgs cairo's `ipc_rmid_deferred_release`
            # lookup (which throws on darwin, absent from its kernel map) is never
            # evaluated. The LOCAL aarch64 cross-check DOES cross-eval it, so there
            # also REPLACE mesonFlags with a fresh list (never read the throwing
            # original) — cairo.nix's reconstruction, but xlib/xcb OFF to match the
            # override — with the ipc value forced to 'false'. The [host_machine]
            # cross-file is re-added by the meson setup hook (as in cairo.nix).
            cairo =
              let base = prev.cairo.override { x11Support = false; xcbSupport = false; };
              in
              if !isCrossDarwin then base
              else base.overrideAttrs (_: {
                mesonFlags = [
                  "-Dgtk_doc=true"
                  "-Dsymbol-lookup=disabled"
                  "-Dspectre=disabled"
                  "-Dglib=enabled"
                  "-Dtests=disabled"
                  "-Dxlib=disabled"
                  "-Dxcb=disabled"
                  "-Ddefault_library=static"
                  "-Ddefault_both_libraries=static"
                  "--cross-file=${builtins.toFile "cairo-darwin-ipc.conf" ''
                    [properties]
                    ipc_rmid_deferred_release = 'false'
                  ''}"
                ];
              });
          } else {
            # Linux cross fixes (no-ops / not pulled on darwin):
            #
            # libx11 (pulled by cairo's xlib backend, kept on Linux) has a configure
            # probe checking whether its cpp needs -undef to stop predefining `unix`;
            # the engine's clang cpp keeps `unix` defined even under -undef, so the
            # probe aborts ("defines unix with or without -undef. I don't know what
            # to do."). RAWCPP only preprocesses X11's host-independent locale text
            # at build time — hand it the build-host gcc cpp (which honors -undef);
            # libX11 links as a plain static .a regardless. Same fix as ddcutil.
            libx11 = prev.libx11.overrideAttrs (_: {
              RAWCPP = "${final.buildPackages.stdenv.cc}/bin/cpp";
            });
            # libtiff is NOT linked into poppler (-DENABLE_LIBTIFF=OFF, dropped from
            # the inputs); it is only a transitive build-dep of openjpeg/lcms2. Its
            # auxiliary EXECUTABLES (tools/test/contrib) fail the engine CROSS link —
            # ld.lld resolves the build host's x86-64 emulation and rejects the
            # target objects ("incompatible with elf64-x86-64"). poppler ships/refs
            # none of them, so don't build them; libtiff.a is untouched.
            libtiff = prev.libtiff.overrideAttrs (o: {
              doCheck = false;
              doInstallCheck = false;
              cmakeFlags = (o.cmakeFlags or [ ])
                ++ [ "-Dtiff-tools=OFF" "-Dtiff-tests=OFF" "-Dtiff-contrib=OFF" ];
              # With the tools off nothing lands in the multi-output `bin`, and nix
              # errors "failed to produce output path for output 'bin'". Create it.
              postInstall = (o.postInstall or "") + "\nmkdir -p $bin\n";
            });
            # pixman (pulled by cairo) builds a test/ suite; on i686 its matrix-test
            # uses `__float128`, whose soft-float builtins (__floatditf/__divtf3/…)
            # the engine's compiler-rt/musl bitcode doesn't provide, so ld.lld fails
            # undefined. poppler links only libpixman-1.a; disable the tests.
            pixman = prev.pixman.overrideAttrs (o: {
              mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
            });
            # cairo's meson unconditionally builds the cairo-script debug utility
            # whenever zlib is present (no meson option to disable it). poppler links
            # only libcairo.a; under the engine those tool links fail on `undefined
            # symbol: malloc` (bitcode-musl's weak malloc, forced with -Wl,-u,malloc
            # in the multicall post-link but not cairo's own meson link). Skip the
            # subdir; libcairo.a is untouched. (Not needed on darwin: xlib is off.)
            cairo = prev.cairo.overrideAttrs (o: {
              postPatch = (o.postPatch or "") + ''
                substituteInPlace util/meson.build \
                  --replace-fail "subdir('cairo-script')" ""
              '';
            });
          }));
        in
        import ./poppler.nix { inherit pkgs ulib sp; };

      # mingw: heavy C++ combined link → force the runtime static so the .exe
      # carries no libstdc++-6/libgcc_s/libmcfgthread DLL, and drive it through
      # lld (binutils 2.44 drops cxx11 COMDAT members in the combined PE link;
      # same fix as heif/srt). `-no-pie` is load-bearing: the mingw gcc driver
      # passes `-pie` (hardening default), which ld.lld rejects in PE mode
      # (`unknown argument: -pie`) and silently falls back to binutils ld — the
      # very linker we are routing around. -no-pie keeps the combined link on lld.
      windowsBuild = pkgs:
        let sp = ulib.mingwStaticCross pkgs; in
        mkMulti pkgs {
          inherit pkgs;
          poppler = import ./poppler.nix { inherit pkgs ulib sp; };
          extraLinkFlags = "-static -static-libgcc -static-libstdc++ -fuse-ld=lld -no-pie";
        };
    };
}
