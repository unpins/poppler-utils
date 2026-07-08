# poppler ships 12 separate CLI programs (pdfinfo, pdftotext, pdftoppm,
# pdftocairo, pdfimages, pdffonts, pdfdetach, pdfattach, pdfseparate, pdftops,
# pdftohtml, pdfunite). The unpins one-pkg-one-bin rule folds them into a single
# multicall binary at $out/bin/poppler-utils that dispatches on argv[0]; a bare
# invocation runs pdfinfo (defaultApplet) so `--version` smoke is clean.
# `lib.withAliases` embeds the 12 names so `unpin install` recreates the argv[0]
# shims on PATH.
#
# Recipe B (multicall.md — reuse the build system's resolved link line; same as
# srt). Each util is built by CMake as `utils/CMakeFiles/<app>.dir/<app>.cc.o`
# linked against the shared libpoppler.a. The clash situation:
#   - `main` — every app. Renamed to <app>_main (the dispatcher's entry points).
#   - parseargs.cc + Win32Console.cc — `common_srcs`, compiled into EVERY app's
#     own .dir (NOT a shared OBJECT lib), so 12 copies of parseArgs/etc. would
#     collide. Plus per-pair helpers compiled twice (sanitychecks in
#     pdftoppm+pdftops; printencodings in pdfinfo+pdftotext).
# Fix: keep all 12 renamed main TUs, but for every NON-main helper object dedupe
# by basename — link exactly ONE copy of parseargs/Win32Console/sanitychecks/
# printencodings/ImageOutputDev/Cairo*/Html*/InMemoryFile. Each app's main TU
# references e.g. parseArgs -> binds to the single surviving copy (identical
# across apps). A final localize pass over the main TUs catches any other global
# two of them happen to share; the link then converges in one shot.
#
# The lib chain (libpoppler.a + freetype/fontconfig/cairo/jpeg/png/openjpeg/
# lcms2/curl/zlib/expat) is reused from a template app's link.txt verbatim, and
# the base derivation's preBuild already appends the full pkg-config --static
# closure as a --start-group to $NIX_LDFLAGS, so the relink (driven through the
# same $CC wrapper) resolves the static cycle the same way the per-app links did.
{ lib }:
{ pkgs, poppler, extraLinkFlags ? "" }:
let
  isDarwin = poppler.stdenv.hostPlatform.isDarwin or false;
  isWindows = poppler.stdenv.hostPlatform.isWindows or false;

  multicall = poppler.overrideAttrs (old: {
    pname = "poppler-utils-multi";
    outputs = [ "out" ];

    doCheck = false;
    doInstallCheck = false;

    # mingw: the combined multicall link is driven through lld (-fuse-ld=lld in
    # extraLinkFlags) to dodge binutils 2.44's PE-COMDAT/auto-import breakage on
    # heavy C++ (the __imp_cairo_* undefineds); the cross gcc driver finds
    # ld.lld on PATH. Only this combined link uses it — CMake's per-app links
    # keep binutils ld. Same as srt/heif.
    nativeBuildInputs = (old.nativeBuildInputs or [ ])
      ++ lib.optional isWindows pkgs.buildPackages.lld;

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p multicall

      # CMake emits .o on unix, .obj on mingw. Find the utils object dirs.
      objext=o
      [ -d utils/CMakeFiles ] || { echo "multicall: utils/CMakeFiles not found" >&2; exit 1; }
      if find utils/CMakeFiles -name '*.cc.obj' | grep -q .; then objext=obj; fi

      # Apps present (pdftocairo only when HAVE_CAIRO produced its target).
      ALLAPPS="pdfattach pdfdetach pdffonts pdfimages pdfinfo pdfseparate pdftocairo pdftohtml pdftoppm pdftops pdftotext pdfunite"
      apps=""
      for a in $ALLAPPS; do
        [ -f "utils/CMakeFiles/$a.dir/$a.cc.$objext" ] && apps="$apps $a"
      done
      [ -n "$apps" ] || { echo "multicall: no util objects found" >&2; exit 1; }
      printf '%s\n' $apps > multicall/apps.list

      # multicallTableDispatcherC (below) reads multicall/applets.list as a TSV
      # <applet-name>\t<fn-base>, emitting <fn-base>_main. For poppler every
      # applet name IS its fn-base (pdfinfo -> pdfinfo_main, matching the
      # `main -> <app>_main` rename below), so the two columns are identical.
      : > multicall/applets.list
      for a in $apps; do printf '%s\t%s\n' "$a" "$a" >> multicall/applets.list; done

      # Mach-O leads C symbols with '_'; detect once from the first app's main.
      first=$(echo $apps | awk '{print $1}')
      if $NM --defined-only "utils/CMakeFiles/$first.dir/$first.cc.$objext" 2>/dev/null \
          | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Rename each app's main -> <app>_main in its own TU (in place; the
      # template's renamed TU rides along in its reused link command). Record
      # each TU's strong globals for the localize pass.
      : > multicall/mainsyms.list
      for a in $apps; do
        mtu="utils/CMakeFiles/$a.dir/$a.cc.$objext"
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${a}_main" "$mtu"
        $NM --defined-only "$mtu" \
          | awk -v keep="''${up}''${a}_main" '$2 ~ /^[A-Z]$/ && $2 != "W" && $2 != "V" && $3 != keep && index($3,".")==0 {print $3}' \
          >> multicall/mainsyms.list
      done

      # Strong globals defined by >=2 TUs are genuine duplicates; localize them
      # in every app's TU so each keeps a private copy (cf. srt/heif).
      sort multicall/mainsyms.list | uniq -d > multicall/clash.syms
      if [ -s multicall/clash.syms ]; then
        for a in $apps; do
          $OBJCOPY --localize-symbols=multicall/clash.syms "utils/CMakeFiles/$a.dir/$a.cc.$objext"
        done
      fi

      # Dispatcher (shared canonical generator). Applet C symbol = sanitized
      # applet name + _main; poppler util names are already valid identifiers,
      # so pdfinfo -> pdfinfo_main, matching the rename above.
${lib.multicallTableDispatcherC { name = "poppler-utils"; defaultApplet = "pdfinfo"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse a template app's resolved link command VERBATIM up to `-o`
      # (compiler, flags, frameworks, ITS OWN objects, libpoppler + the lib
      # chain) — do NOT strip its objects: on darwin the cairo/CoreText
      # -framework tokens ride in that command and stripping them dropped the
      # CG*/CT* + libiconv symbols. Pick pdftocairo (richest: cairo + freetype +
      # lcms2 + frameworks), else the first app. Make generator writes link.txt;
      # Ninja (nixpkgs default) keeps it in build.ninja -> `ninja -t commands`.
      template=pdftocairo
      echo " $apps " | grep -q " pdftocairo " || template="$first"
      # ninja's executable targets carry the host exe suffix (.exe on mingw).
      tgt="utils/$template"
      [ "$objext" = obj ] && tgt="$tgt.exe"
      if [ -f "utils/CMakeFiles/$template.dir/link.txt" ]; then
        line=$(cat "utils/CMakeFiles/$template.dir/link.txt")
      else
        line=$(ninja -t commands "$tgt" | tail -1)
      fi
      # Ninja's link rule wraps the real command as `: && <cmd> && :` (CMake's
      # RULE_LAUNCH). The trailing ` && :` would TERMINATE the g++ command, so
      # the objects/flags we splice after $libs (-static/-fuse-ld=lld/-no-pie on
      # mingw, the -search_paths_first/unexported list on darwin) would fall onto
      # the `:` no-op instead of the linker. Strip both wrappers. (link.txt has
      # no wrapper, so these are no-ops there.)
      line="''${line#: && }"
      line="''${line% && :}"
      pre="''${line%% -o *}"
      post="''${line#* -o }"
      oldout="''${post%% *}"
      libs="''${post#"$oldout"}"

      # Splice in the OTHER apps: each one's main TU (always) plus any helper
      # object the template's set doesn't already carry. The template provides
      # parseargs/Win32Console (common_srcs) + its own cairo helpers; the rest
      # (sanitychecks, printencodings, ImageOutputDev, Html*/InMemoryFile) are
      # added once, deduped by basename so the shared helpers don't multiply.
      : > multicall/added.list
      find "utils/CMakeFiles/$template.dir" -name "*.cc.$objext" -exec basename {} \; >> multicall/added.list
      EXTRA=""
      for a in $apps; do
        [ "$a" = "$template" ] && continue
        dir="utils/CMakeFiles/$a.dir"
        EXTRA="$EXTRA $PWD/$dir/$a.cc.$objext"
        for o in $(find "$dir" -name "*.cc.$objext"); do
          b=$(basename "$o")
          [ "$b" = "$a.cc.$objext" ] && continue
          if ! grep -qxF "$b" multicall/added.list; then
            echo "$b" >> multicall/added.list
            EXTRA="$EXTRA $PWD/$o"
          fi
        done
      done

      # darwin: fold static libc++ and hide its surface so dyld can't coalesce
      # with the macOS system libc++ (TMO crash); same as heif/srt.
      darwin_link_extra=""
      case "$($CC -dumpmachine)" in *darwin*)
        cat > multicall/unexport.syms <<'EOF'
        __Znw*
        __Zna*
        __Zdl*
        __Zda*
        __ZNSt*
        __ZNKSt*
        __ZNVSt*
        __ZSt*
        __ZTVSt*
        __ZTVNSt*
        __ZTISt*
        __ZTINSt*
        __ZTSSt*
        __ZTSNSt*
        __ZN10__cxxabiv1*
        __ZNK10__cxxabiv1*
        __ZTVN10__cxxabiv1*
        __ZTIN10__cxxabiv1*
        __ZTSN10__cxxabiv1*
EOF
        sed -i 's/^[[:space:]]*//' multicall/unexport.syms
        darwin_link_extra="-Wl,-unexported_symbols_list,$PWD/multicall/unexport.syms"
      ;; esac

      eval "$pre $EXTRA multicall/dispatcher.o -o multicall/poppler-utils $libs $darwin_link_extra ${extraLinkFlags}" 2>multicall/link.err || {
        cat multicall/link.err >&2
        echo "multicall: combined link failed (unexpected strong duplicate left?)" >&2
        exit 1
      }
      [ -f multicall/poppler-utils ] || mv multicall/poppler-utils.exe multicall/poppler-utils
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/man/man1"
      install -m755 multicall/poppler-utils "$out/bin/poppler-utils"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s poppler-utils "$out/bin/$a"
      done < multicall/apps.list
      # ship each applet's man page. poppler ships them as static .1 files in
      # the SOURCE utils/ (not generated into the build dir), so find them under
      # the unpacked source rather than the cmake build dir.
      for m in $(cat multicall/apps.list); do
        src=$(find "$NIX_BUILD_TOP" -name "$m.1" -path '*/utils/*' -not -path '*CMakeFiles*' 2>/dev/null | head -1)
        [ -n "$src" ] && cp "$src" "$out/share/man/man1/$m.1"
      done
      runHook postInstall
    '';

    postInstall = "";
  });

  aliased = lib.withAliases pkgs
    {
      primary = "poppler-utils";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/poppler-utils" ] && mv "$out/bin/poppler-utils" "$out/bin/poppler-utils.exe"
  '';
})
else aliased
