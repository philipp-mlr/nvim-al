{
  description = "nvim-al: Business Central AL support for Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Microsoft's AL Language extension, fetched from the VS Code marketplace at
      # build time (never stored in this repository). The marketplace serves the
      # .vsix gzip-compressed; the hash is of that raw download.
      alExtension =
        pkgs:
        let
          version = "30.0.2863738";
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "vscode-al-extension";
          inherit version;
          src = pkgs.fetchurl {
            name = "al-${version}.vsix.gz";
            url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-dynamics-smb/vsextensions/al/${version}/vspackage";
            hash = "sha256-21bLOTsAomERikwfmWlyF9agoTN6mKFBQ+/KyN+pAJs=";
          };
          nativeBuildInputs = [
            pkgs.gzip
            pkgs.unzip
          ];
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            gunzip -c $src > al.vsix
            unzip -q al.vsix 'extension/*'
            mkdir -p $out
            cp -r extension/. $out/
            runHook postInstall
          '';
          # Unfree (Microsoft licence). Users opt in like for any unfree package
          # (allowUnfree or allowUnfreePredicate for "vscode-al-extension").
          meta = {
            description = "AL Language extension for VS Code (language server, debug adapter, compiler)";
            homepage = "https://marketplace.visualstudio.com/items?itemName=ms-dynamics-smb.al";
            license = pkgs.lib.licenses.unfree;
          };
        };
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.vimUtils.buildVimPlugin {
          pname = "nvim-al";
          version = "0.1.0";
          src = self;
          # tests and fixtures are not part of the plugin
          postInstall = ''
            rm -rf $out/tests $out/scripts $out/docs/plans
          '';
          doCheck = false;
        };
      });

      # Not in `packages`: `nix flake check` would refuse to evaluate an unfree
      # package. Build with `NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#al-extension`.
      legacyPackages = forAll (pkgs: {
        al-extension = alExtension pkgs;
      });

      # Build the AL extension with your own (unfree-allowing) nixpkgs:
      #   inputs.nvim-al.lib.mkAlExtension pkgs
      lib.mkAlExtension = alExtension;

      checks = forAll (pkgs: {
        unit = pkgs.runCommand "nvim-al-unit-tests" {
          nativeBuildInputs = [
            pkgs.neovim-unwrapped
            pkgs.git
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnused
          ];
        } ''
          cp -r ${self} src && chmod -R u+w src && cd src
          mkdir -p .deps && ln -s ${pkgs.vimPlugins.mini-nvim} .deps/mini.nvim
          export HOME=$TMPDIR
          bash scripts/test
          touch $out
        '';
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.stylua
            pkgs.git
            pkgs.dotnetCorePackages.aspnetcore_10_0
          ];
        };
      });
    };
}
