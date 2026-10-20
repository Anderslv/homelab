{
  inputs = { utils.url = "github:numtide/flake-utils"; };
  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        secretsTools = with pkgs; [ keepassxc sops age jq git docker-client ];
        # Runs the scripts from the source tree. checkPhase is skipped because
        # the scripts source their libraries by path, which shellcheck cannot
        # follow in the Nix sandbox; the repo's own shellcheck hook covers them.
        secretsApp = name: script: pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = secretsTools;
          checkPhase = "";
          text = ''exec bash "${self}/${script}" "$@"'';
        };
      in {
        packages.homelab-secrets-setup =
          secretsApp "homelab-secrets-setup" "scripts/secrets/setup.sh";
        packages.secrets-setup-tests =
          secretsApp "secrets-setup-tests" "dev/tests/secrets-setup.test.sh";

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
          expect
          dependabot-cli
          gitleaks
          jq
          mkcert
          nssTools
          openssl
          prek
          sops
          age
          yamlfix
          zensical
          ];

          shellHook = ''
          export HOMELAB_MKCERT_ROOT="$(${pkgs.mkcert}/bin/mkcert -CAROOT)"

          if [ ! -f "$HOMELAB_MKCERT_ROOT/rootCA.pem" ]; then
            echo "mkcert CA is not installed yet. Run: mkcert -install"
          fi
          '';
        };

        devShell = self.devShells.${system}.default;
      });
}
