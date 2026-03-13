{ config, pkgs, ... }:

{
  # --- ArgoCD via Helm -------------------------------------------------------
  # Un service oneshot qui attend que k3s soit prêt, puis installe ArgoCD.
  # Il ne tourne qu'une fois (RemainAfterExit), et se relance en cas d'échec.

  systemd.services.argocd-bootstrap = {
    description = "Installer ArgoCD via Helm";
    after       = [ "k3s.service" ];
    requires    = [ "k3s.service" ];
    wantedBy    = [ "multi-user.target" ];

    path = with pkgs; [ kubectl kubernetes-helm ];

    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      Restart         = "on-failure";
      RestartSec      = "30s";

      # Attend que k3s soit vraiment prêt avant de lancer Helm
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'until kubectl get nodes 2>/dev/null | grep -q \" Ready\"; do sleep 5; done'";

      ExecStart = "${pkgs.bash}/bin/bash -c '${builtins.concatStringsSep " && " [
        "helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true"
        "helm repo update"
        (builtins.concatStringsSep " " [
          "helm upgrade --install argocd argo/argo-cd"
          "--namespace argocd"
          "--create-namespace"
          "--version 2.13.3"          # Version Helm chart à fixer
          "--set server.service.type=NodePort"
          "--set server.service.nodePortHttps=30443"
          "--wait"
          "--timeout 10m"
        ])
      ]}'";
    };
  };
}

# ---------------------------------------------------------------------------
# Après déploiement :
#
#   # Récupérer le mot de passe admin
#   kubectl -n argocd get secret argocd-initial-admin-secret \
#     -o jsonpath="{.data.password}" | base64 -d && echo
#
#   # Accéder à l'UI : https://<IP>:30443
#   # Login : admin / <mot de passe ci-dessus>
# ---------------------------------------------------------------------------
