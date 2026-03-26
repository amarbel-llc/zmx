{
  lib,
  stdenv,
  zig_0_15,
  pkg-config,
  makeWrapper,
  libvterm-neovim,
  useLibvterm ? false,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "zmx${lib.optionalString useLibvterm "-libvterm"}";
  version = "0.4.1";

  src = lib.cleanSource ./.;

  postPatch = lib.optionalString useLibvterm ''
    sed -i '/\.dependencies = \.{/,/},/{/\.ghostty/,/},/d;}' build.zig.zon
  '';

  deps = zig_0_15.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = finalAttrs.passthru.depsHash;
  };

  nativeBuildInputs = [
    zig_0_15
    zig_0_15.hook
  ]
  ++ lib.optionals useLibvterm [
    pkg-config
    makeWrapper
  ];

  buildInputs = lib.optionals useLibvterm [ libvterm-neovim ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ]
  ++ lib.optionals useLibvterm [ "-Dbackend=libvterm" ];

  postInstall = lib.optionalString useLibvterm ''
    wrapProgram $out/bin/zmx \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libvterm-neovim ]} \
      --prefix DYLD_LIBRARY_PATH : ${lib.makeLibraryPath [ libvterm-neovim ]}
  '';

  passthru.depsHash = "sha256-mac0B0GuhpQxU/L8clpMm8k2xlDVOT268exNHwAJA0w=";

  meta = {
    description = "Session persistence for terminal processes";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
})
