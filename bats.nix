# bats integration test lanes for zmx.
#
# Wraps the `batsLane` builder from amarbel-llc/bats with
# project-specific defaults: `bats-libs` on `BATS_LIB_PATH`, the zmx
# binary exported via the `binaries` map, and a `BATS_TEST_TIMEOUT`
# mirroring zz-tests_bats.
#
# Auto-discovers `# bats file_tags=foo,bar` directives at flake-eval
# time and produces one `bats-${tag}` derivation per unique tag plus
# `bats-default` (no filter).
{
  pkgs,
  batsLane,
  bats-libs,
  zmxBin, # the zmx binary derivation (wrapped with libvterm LD_LIBRARY_PATH)
  batsSrc,
  batsTestTimeout ? "10",
}:
let
  inherit (pkgs) lib;

  mkBatsLane =
    {
      filter ? "",
      base ? zmxBin,
    }:
    batsLane {
      inherit base filter batsSrc;
      binaries = {
        ZMX_BIN = {
          inherit base;
          name = "zmx";
        };
      };
      batsLibPath = [ bats-libs.batsLibPath ];
      extraEnv = {
        BATS_TEST_TIMEOUT = batsTestTimeout;
      };
      # bats-island's setup_test_home shells out to git to populate
      # GIT_CONFIG_GLOBAL with a deterministic identity. fish, bash,
      # and zsh power the completion-syntax smoke tests in
      # zz-tests_bats/completions.bats.
      nativeBuildInputs = [
        pkgs.git
        pkgs.fish
        pkgs.bash
        pkgs.zsh
      ];
    };

  batsFiles = lib.filter (f: lib.hasSuffix ".bats" f) (
    builtins.attrNames (builtins.readDir batsSrc)
  );

  trimWhitespace =
    s:
    let
      m = builtins.match "[[:space:]]*(.*[^[:space:]]|)[[:space:]]*" s;
    in
    if m == null then s else builtins.head m;

  extractFileTags =
    file:
    let
      content = builtins.readFile (batsSrc + "/${file}");
      lines = lib.splitString "\n" content;
      tagLines = lib.filter (l: lib.hasPrefix "# bats file_tags=" l) lines;
    in
    if tagLines == [ ] then
      [ ]
    else
      map trimWhitespace (
        lib.splitString "," (lib.removePrefix "# bats file_tags=" (builtins.head tagLines))
      );

  allFileTags = lib.unique (lib.concatMap extractFileTags batsFiles);

  batsLaneOutputs =
    lib.listToAttrs (
      map (tag: lib.nameValuePair "bats-${tag}" (mkBatsLane { filter = tag; })) allFileTags
    )
    // {
      bats-default = mkBatsLane { };
    };
in
{
  inherit mkBatsLane batsLaneOutputs;
}
