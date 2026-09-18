{
  description = "inference-platform dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAll (pkgs:
        let
          # helm with the plugins the chart tests depend on
          helm = pkgs.wrapHelm pkgs.kubernetes-helm {
            plugins = with pkgs.kubernetes-helmPlugins; [
              helm-unittest
              helm-diff
            ];
          };

          # glue-language runtime for the mock engine, benchmark parsing, cost model
          # Skip build-time test suites for packages whose *test-only* deps are
          # broken on darwin at the pinned nixpkgs revision (so no binary-cache hit):
          #   fastapi           -> inline-snapshot (tests/test_docs.py fails)
          #   prometheus-client -> twisted (reactor test hangs, 120s timeout)
          # Tests are skipped only for these two; runtime code is unchanged.
          python312 = pkgs.python312.override {
            packageOverrides = _final: prev: {
              fastapi = prev.fastapi.overridePythonAttrs (_: { doCheck = false; });
              prometheus-client = prev.prometheus-client.overridePythonAttrs (_: { doCheck = false; });
            };
          };
          python = python312.withPackages (ps: with ps; [
            fastapi
            uvicorn
            prometheus-client
            httpx
            pyyaml
            pandas
          ]);

          tools = with pkgs; [
            # --- step 1: kubernetes core + helm + kind ---
            kubectl
            helm
            kind
            kubeconform
            kustomize
            docker-client        # CLI only; the daemon comes from the host
            just
            yq-go
            jq
            python
            uv                   # for python tools not in nixpkgs (guidellm)

            # --- step 2: observability + scaling ---
            prometheus           # promtool for validating PrometheusRule files
            grafana-loki         # optional; logcli for local log queries

            # --- step 3: gitops + iac ---
            argocd
            opentofu             # swap for `terraform` if you accept the unfree license
            tflint

            # --- step 5: policy + ci ---
            conftest
            kyverno
            actionlint

            # --- quality of life ---
            k9s
            kubectx
            gh
          ];
        in
        {
          default = pkgs.mkShell {
            packages = tools;

            shellHook = ''
              export KUBECONFIG="$PWD/local/kubeconfig"
              export UV_PROJECT_ENVIRONMENT="$PWD/.venv"
              echo "inference-platform dev shell"
              echo "  kubectl  $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)"
              echo "  helm     $(helm version --short)"
              echo "  kind     $(kind version | cut -d' ' -f2)"
              echo "  tofu     $(tofu version | head -1 | cut -d' ' -f2)"
              echo "  argocd   $(argocd version --client --short 2>/dev/null | cut -d' ' -f2)"
            '';
          };
        });
    };
}