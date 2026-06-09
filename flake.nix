{
  description = "Standalone build of poppler-utils (pdfinfo, pdftotext, pdftoppm, …)";

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
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "poppler-utils";
      # A bare `poppler-utils -v` dispatches to pdfinfo (defaultApplet) ->
      # "pdfinfo version 25.10.0". poppler's utils use `-v` for version (a bare
      # `--version` is parsed as a filename), so smoke on `-v`.
      smoke = [ "-v" ];
      smokePattern = "version 2[0-9]\\.";

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
          sp =
            if host.isDarwin
            then pkgs.pkgsStatic.extend (final: prev: {
              glib       = ulib.nativeFixes.glib       prev;
              graphite2  = ulib.nativeFixes.graphite2  prev;
              fontconfig = ulib.nativeFixes.fontconfig prev;
              cairo      = ulib.nativeFixes.cairo      prev;
            })
            else if host.isRiscV
            then pkgs.pkgsStatic.extend (final: prev: {
              libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
            })
            else pkgs.pkgsStatic;
        in
        mkMulti pkgs ({
          inherit pkgs;
          poppler = import ./poppler.nix { inherit pkgs ulib sp; };
        } // pkgs.lib.optionalAttrs host.isDarwin {
          # The static libc++ shim + frameworks are wired into NIX_LDFLAGS in
          # poppler.nix (so the 12 per-app links use them too); the relink just
          # needs -search_paths_first so the implicit -lc++ binds the shim's
          # static .a rather than /usr/lib/libc++.1.dylib.
          extraLinkFlags = "-Wl,-search_paths_first";
        });

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
