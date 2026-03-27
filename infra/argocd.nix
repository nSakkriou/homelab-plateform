{ config, pkgs, ... }:

let
  # Valeurs Helm pour ArgoCD — bootstrap (Phase A).
  # ArgoCD est exposé en NodePort 30443 le temps que le Gateway soit opérationnel.
  # Après la Phase 3, mettre à jour argocdValues vers argocdValuesFinal
  # et relancer nixos-rebuild switch.
  argocdValues = pkgs.writeText "argocd-bootstrap-values.yaml" ''
    configs:
      params:
        # ArgoCD ne termine pas le TLS lui-même : c'est Envoy Gateway qui s'en charge.
        # Ce flag est déjà prêt pour la Phase 3 (l'insecure ne pose pas de problème
        # derrière le NodePort car l'accès est direct depuis ton poste).
        server.insecure: "true"

    server:
      service:
        type: NodePort
        nodePortHttp: 30080
        nodePortHttps: 30443
  '';

in
{
  # ---------------------------------------------------------------------------
  # Bootstrap ArgoCD via Helm
  # Service oneshot : s'exécute après k3s, se relance en cas d'échec.
  # Idempotent : helm upgrade --install est sans effet si la version et les
  # valeurs sont déjà en place.
  # ---------------------------------------------------------------------------

  systemd.services.argocd-bootstrap = {
    description = "Bootstrap ArgoCD via Helm";
    after       = [ "k3s.service" ];
    requires    = [ "k3s.service" ];
    wantedBy    = [ "multi-user.target" ];

    path = with pkgs; [ kubectl kubernetes-helm bash ];

    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      Restart         = "on-failure";
      RestartSec      = "30s";
    };

    script = ''
      # Attendre que le nœud k3s soit Ready
      until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
        echo "Waiting for k3s node to be Ready..."
        sleep 5
      done

      # Ajouter le repo Helm ArgoCD
      helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
      helm repo update

      # Installer ArgoCD
      helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --version 2.13.3 \
        -f ${argocdValues} \
        --wait \
        --timeout 10m

      echo "ArgoCD bootstrapped. UI: https://<IP_SERVEUR>:30443"
      echo "Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    '';
  };
}

# ---------------------------------------------------------------------------
# Phase 3 — Après déploiement du Gateway Envoy :
#
# 1. Remplacer argocdValues par :
#    server:
#      service:
#        type: ClusterIP
#    configs:
#      params:
#        server.insecure: "true"
#
# 2. Retirer le port 30443 de networking.firewall.allowedTCPPorts
#    dans configuration.nix.
#
# 3. nixos-rebuild switch --flake .#k3s-node
#
# ArgoCD sera alors accessible uniquement via :
#   https://argocd.nathansakkriou.com
# ---------------------------------------------------------------------------
