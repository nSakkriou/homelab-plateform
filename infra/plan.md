# Plan d'implémentation — Homelab NixOS + k3s + ArgoCD

## TODO — Checklist d'implémentation

### Socle NixOS
- [x] Analyser la configuration existante (`research.md`)
- [x] Ajouter la TODO list dans `plan.md`
- [x] Créer `flake.nix` + `flake.lock`
- [x] Créer `.gitignore` complet
- [x] Mettre à jour `infra/configuration.nix` (SANs TLS, fail2ban, SSH hardening, port 30443 temporaire)
- [x] Mettre à jour `infra/argocd.nix` (values via `pkgs.writeText`, mode insecure, NodePort bootstrap)
- [x] Créer `infra/secrets/.sops.yaml` (structure sops-nix)

### GitOps — ArgoCD Applications
- [x] Créer `apps/app-of-apps.yaml` (Application racine)
- [x] Créer `apps/infrastructure/gateway-api-crds.yaml` (wave 0 — CRDs Gateway API)
- [x] Créer `apps/infrastructure/cert-manager.yaml`
- [x] Créer `apps/infrastructure/cert-manager-issuers.yaml`
- [x] Créer `apps/infrastructure/envoy-gateway.yaml`
- [x] Créer `apps/infrastructure/envoy-gateway-resources.yaml`
- [x] Créer `apps/infrastructure/argocd-config.yaml`

### Manifests Kubernetes
- [x] Créer `apps/k8s/cert-manager/cluster-issuer-staging.yaml`
- [x] Créer `apps/k8s/cert-manager/cluster-issuer-prod.yaml`
- [x] Créer `apps/k8s/envoy-gateway/gatewayclass.yaml`
- [x] Créer `apps/k8s/envoy-gateway/gateway.yaml`
- [x] Créer `apps/k8s/envoy-gateway/certificate.yaml`
- [x] Créer `apps/k8s/argocd/httproute.yaml`

### Documentation
- [x] Créer `INSTALL.md` (guide d'installation depuis clé USB)

---


## Contexte et objectifs

- Serveur physique chez soi, exposé sur internet
- Cluster Kubernetes mono-nœud (k3s)
- SSH pour la maintenance quotidienne et le rebuild NixOS à distance
- `kubectl` utilisable depuis une machine distante
- ArgoCD comme seul point d'entrée pour les déploiements applicatifs
- Repo GitHub privé pour le code des applications
- Applications exposées via **Gateway API** (pas d'Ingress, pas de NodePort)
- Secrets gérés via **sops-nix**

---

## Vue d'ensemble des problèmes identifiés

| # | Problème | Criticité | Impact |
|---|----------|-----------|--------|
| P1 | `hardware-configuration.nix` absent | Bloquant | `nixos-rebuild` échoue |
| P2 | SANs TLS k3s trop restrictifs | Haute | `kubectl` distant impossible |
| P3 | ArgoCD en NodePort, accès non structuré | Haute | Pas de routing par domaine, pas de TLS propre |
| P4 | Token GitHub pour repo privé non géré | Haute | ArgoCD ne peut pas lire le repo |
| P5 | Pas de `flake.nix` | Moyenne | Reproductibilité non garantie |
| P6 | Helm configuré via `--set` inline | Moyenne | Pas de trace des valeurs dans Git, difficile à maintenir |
| P7 | SSH sans protection brute-force | Moyenne | Exposition directe sur internet |
| P8 | `KUBECONFIG` global pour tous les users | Faible | Surface d'attaque inutile |

---

## Étape 1 — Débloquer le rebuild (P1)

`hardware-configuration.nix` est importé mais absent. Le système ne peut pas être reconstruit.

Générer le fichier sur la machine cible une seule fois, puis le committer :

```bash
# Sur le serveur physique, une fois NixOS installé
nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix

# Copier dans le repo
cp /etc/nixos/hardware-configuration.nix \
   /chemin/vers/homelab-plateform/infra/hardware-configuration.nix
```

Ce fichier est spécifique à la machine (UUIDs, drivers, modules). Il peut et doit être committé — il ne contient aucun secret.

---

## Étape 2 — Adopter Nix Flakes (P5)

Les Flakes sont déjà activés. Introduire `flake.nix` apporte :
- Un `flake.lock` qui fixe exactement les versions de nixpkgs et de sops-nix
- Un rebuild reproductible depuis n'importe quelle machine
- L'intégration propre de sops-nix comme module NixOS

`flake.nix` cible :

```nix
{
  description = "Homelab NixOS configuration";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-24.11";
    sops-nix.url    = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, ... }: {
    nixosConfigurations.k3s-node = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./infra/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };
  };
}
```

Rebuild depuis le serveur :

```bash
sudo nixos-rebuild switch --flake .#k3s-node
```

Rebuild depuis le poste de travail (sans avoir à se connecter en SSH) :

```bash
nixos-rebuild switch --flake .#k3s-node \
  --target-host admin@<IP_OU_DNS_SERVEUR> \
  --use-remote-sudo
```

---

## Étape 3 — Configurer sops-nix et le token GitHub (P4)

### Pourquoi sops-nix ici

ArgoCD doit pouvoir lire le repo GitHub privé des applications. Le token GitHub (Personal Access Token) ne peut pas être committé en clair. sops-nix permet de chiffrer ce secret avec la clé age, le committer dans Git, et le déchiffrer automatiquement au moment du rebuild NixOS.

### Flux de fonctionnement

```
age.key (sur le serveur, hors Git)
  │
  ▼ déchiffre au boot via sops-nix
secrets/secrets.yaml (chiffré, dans Git)
  │
  ▼ NixOS crée un fichier
/run/secrets/argocd_github_token  (en RAM, mode 600)
  │
  ▼ lu par le service argocd-bootstrap
kubectl apply → Secret Kubernetes "argocd-repo-homelab"
  │
  ▼
ArgoCD lit le repo privé
```

### Structure des fichiers secrets

```
infra/
└── secrets/
    ├── .sops.yaml          (règles de chiffrement — committé)
    └── secrets.yaml        (secrets chiffrés — committé)
```

`.sops.yaml` :
```yaml
creation_rules:
  - path_regex: infra/secrets/.*\.yaml$
    age: "<clé_publique_age_du_serveur>"
```

`secrets.yaml` (contenu avant chiffrement) :
```yaml
argocd_github_token: "ghp_xxxxxxxxxxxxxxxxxxxx"
```

Pour chiffrer :
```bash
sops --encrypt --in-place infra/secrets/secrets.yaml
```

### Configuration dans `configuration.nix`

```nix
sops = {
  defaultSopsFile = ./secrets/secrets.yaml;
  age.keyFile     = "/var/lib/sops-nix/key.txt";
  secrets."argocd_github_token" = {
    owner = "root";
    mode  = "0400";
  };
};
```

### Utilisation dans `argocd.nix`

Le service `argocd-bootstrap` lit `/run/secrets/argocd_github_token` et crée le Secret Kubernetes avant d'appliquer ArgoCD :

```bash
# Créer le secret de repo dans Kubernetes
kubectl create secret generic argocd-repo-homelab \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<org>/homelab-plateform \
  --from-literal=username=git \
  --from-file=password=/run/secrets/argocd_github_token \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret argocd-repo-homelab -n argocd \
  argocd.argoproj.io/secret-type=repository
```

---

## Étape 4 — kubectl depuis une machine distante (P2)

### 4a. Étendre les SANs TLS k3s

Pour que le certificat TLS de l'API k3s soit valide depuis une machine distante, ajouter l'IP publique et/ou le nom DNS :

```nix
services.k3s.extraFlags = toString [
  "--disable=traefik"
  "--tls-san=k3s-node"
  "--tls-san=127.0.0.1"
  "--tls-san=<IP_PUBLIQUE>"
  "--tls-san=k3s.tondomaine.fr"
];
```

Le port 6443 doit rester ouvert dans le firewall (déjà le cas).

### 4b. Copier le kubeconfig sur le poste de travail

Après le premier boot du serveur :

```bash
# Sur ton poste de travail
ssh admin@<IP_SERVEUR> "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/<IP_PUBLIQUE_OU_DNS>/g" \
  > ~/.kube/homelab.yaml

export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes   # doit fonctionner sans avertissement TLS
```

---

## Étape 5 — Migrer Helm vers des fichiers de valeurs (P6)

Plutôt que d'empiler des `--set` dans la CLI, chaque déploiement Helm utilise un fichier `values.yaml` versionné dans Git.

### Structure cible

```
infra/
└── helm-values/
    ├── argocd.yaml
    └── envoy-gateway.yaml   (voir étape 6)
```

### Exemple : `infra/helm-values/argocd.yaml`

```yaml
server:
  service:
    type: ClusterIP

configs:
  params:
    server.insecure: false

repoServer:
  resources:
    limits:
      cpu: 200m
      memory: 256Mi
```

### Dans `argocd.nix` — appel simplifié

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 2.13.3 \
  -f /path/to/repo/infra/helm-values/argocd.yaml \
  --wait \
  --timeout 10m
```

Pour que le service systemd puisse trouver le fichier, la variable `REPO_PATH` peut être définie dans l'unité, ou le fichier peut être embarqué via `pkgs.writeText` dans le Nix store :

```nix
# Dans argocd.nix
let
  argocdValues = pkgs.writeText "argocd-values.yaml" ''
    server:
      service:
        type: ClusterIP
    configs:
      params:
        server.insecure: false
  '';
in
# ...
ExecStart = "${pkgs.kubernetes-helm}/bin/helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 2.13.3 \
  -f ${argocdValues} \
  --wait --timeout 10m";
```

L'avantage de `pkgs.writeText` : le fichier est dans le Nix store, immuable, versionné avec le reste de la config.

---

## Étape 6 — Gateway API à la place de l'Ingress (P3)

### Pourquoi Gateway API

Gateway API est le successeur officiel de l'Ingress dans Kubernetes. Plus expressif, plus riche en permissions, il sépare les responsabilités entre l'opérateur infrastructure (qui définit la `Gateway`) et les développeurs applicatifs (qui définissent des `HTTPRoute`).

Pour un homelab, c'est aussi plus simple à opérer : un seul point d'entrée typé, pas de confusion entre les annotations propriétaires de chaque contrôleur Ingress.

### Implémentation recommandée : Envoy Gateway

Envoy Gateway est l'implémentation de référence CNCF de Gateway API. Légère, bien maintenue, documentée.

```
Internet
  │  :80 / :443
  ▼
[Envoy Gateway]  ← déployé via ArgoCD
  │  GatewayClass: envoy
  │  Gateway: homelab-gw (namespace: infra)
  │
  ├── HTTPRoute: argocd.tondomaine.fr   → argocd-server.argocd
  ├── HTTPRoute: app1.tondomaine.fr     → app1-svc.app1
  └── HTTPRoute: app2.tondomaine.fr     → app2-svc.app2

[cert-manager]  ← déployé via ArgoCD
  └── ClusterIssuer Let's Encrypt
      └── certificats TLS automatiques via Gateway API integration
```

### Configuration firewall — aucun changement

Les ports 80 et 443 sont déjà ouverts. NodePort 30443 n'est plus nécessaire (retirer si présent).

```nix
networking.firewall.allowedTCPPorts = [ 22 80 443 6443 ];
```

### Ressources Gateway API cibles

**GatewayClass et Gateway** (déployés par ArgoCD, namespace `infra`) :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: homelab-gw
  namespace: infra
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: homelab-tls
```

**HTTPRoute applicative** (déployée par chaque Application ArgoCD) :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app1
  namespace: app1
spec:
  parentRefs:
    - name: homelab-gw
      namespace: infra
  hostnames:
    - "app1.tondomaine.fr"
  rules:
    - backendRefs:
        - name: app1-svc
          port: 8080
```

### Bootstrap d'Envoy Gateway — valeurs Helm

`infra/helm-values/envoy-gateway.yaml` :

```yaml
deployment:
  envoyGateway:
    resources:
      limits:
        cpu: 500m
        memory: 1024Mi
config:
  envoyGateway:
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

---

## Étape 7 — Durcir SSH (P7)

Exposé sur internet = scanners permanents. Les mesures actuelles (pas de root, pas de mot de passe) sont bonnes. Compléter avec :

### Fail2ban

```nix
services.fail2ban = {
  enable    = true;
  maxretry  = 5;
  bantime   = "1h";
  bantime-increment = {
    enable      = true;
    multipliers = "1 2 4 8 16 32 64";
    maxtime     = "168h";
    overalljails = true;
  };
};
```

### Port SSH non standard (optionnel, réduit le bruit des logs)

```nix
services.openssh.ports = [ 2222 ];
networking.firewall.allowedTCPPorts = [ 2222 80 443 6443 ];
```

Mettre à jour `~/.ssh/config` sur le poste de travail :
```
Host homelab
  HostName <IP_OU_DNS>
  User admin
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

### Algorithmes SSH renforcés

```nix
services.openssh.settings = {
  PermitRootLogin              = "no";
  PasswordAuthentication       = false;
  KbdInteractiveAuthentication = false;
  Ciphers      = [ "chacha20-poly1305@openssh.com" "aes256-gcm@openssh.com" ];
  Macs         = [ "hmac-sha2-512-etm@openssh.com" "hmac-sha2-256-etm@openssh.com" ];
  KexAlgorithms = [ "curve25519-sha256" "curve25519-sha256@libssh.org" ];
};
```

---

## Étape 8 — Correction mineure : KUBECONFIG (P8)

`KUBECONFIG` dans `environment.variables` est global à tous les utilisateurs. Le restreindre à `admin` uniquement via son profil shell :

```nix
# Retirer de environment.variables dans configuration.nix
# Ajouter au profil de l'utilisateur :
users.users.admin.initialHashedPassword = "...";
# Via home-manager ou programs.bash.shellInit :
environment.interactiveShellInit = ''
  if [ "$(id -u)" = "$(id -u admin)" ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi
'';
```

---

## Ordre de bootstrap au premier démarrage

Le problème de la poule et de l'œuf : Envoy Gateway a besoin d'ArgoCD pour être déployé, mais ArgoCD a besoin d'Envoy Gateway pour être exposé proprement.

**Solution : bootstrap en deux phases.**

### Phase A — NixOS gère le bootstrap minimal

Le service `argocd-bootstrap` existant installe ArgoCD avec accès temporaire en NodePort 30443, ouvert uniquement le temps de la phase A.

```nix
# Temporaire dans configuration.nix pendant la phase A
networking.firewall.allowedTCPPorts = [ 22 80 443 6443 30443 ];
```

Une fois ArgoCD accessible :
1. Appliquer l'App-of-Apps (voir ci-dessous)
2. Laisser ArgoCD déployer Envoy Gateway et cert-manager
3. Reconfigurer ArgoCD pour passer en HTTPRoute
4. Fermer le port 30443 + `nixos-rebuild switch`

### Phase B — ArgoCD gère tout le reste (GitOps pur)

ArgoCD lit `apps/` et déploie dans cet ordre (sync waves) :

```
Wave 1 : cert-manager
Wave 2 : Envoy Gateway + GatewayClass + Gateway
Wave 3 : ArgoCD reconfiguration (HTTPRoute argocd.tondomaine.fr)
Wave 4 : Applications métier
```

---

## Structure `apps/` cible

```
apps/
├── bootstrap/
│   └── app-of-apps.yaml            (appliqué manuellement une seule fois)
├── infrastructure/
│   ├── cert-manager/
│   │   ├── application.yaml        (Application ArgoCD)
│   │   ├── values.yaml
│   │   └── cluster-issuer.yaml     (ClusterIssuer Let's Encrypt)
│   ├── envoy-gateway/
│   │   ├── application.yaml
│   │   ├── values.yaml
│   │   ├── gatewayclass.yaml
│   │   └── gateway.yaml
│   └── argocd-config/
│       ├── application.yaml
│       └── httproute.yaml          (argocd.tondomaine.fr)
└── workloads/
    ├── app1/
    │   ├── application.yaml
    │   └── httproute.yaml
    └── app2/
        └── ...
```

`app-of-apps.yaml` — appliqué une seule fois manuellement après le bootstrap :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/homelab-plateform
    targetRevision: main
    path: apps/infrastructure
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Recommandations supplémentaires

### DNS dynamique

Si l'IP publique change (FAI résidentiel), un client DDNS maintient le DNS à jour. Le token API (Cloudflare ou autre) est géré via sops-nix.

```nix
services.ddclient = {
  enable    = true;
  protocol  = "cloudflare";
  zone      = "tondomaine.fr";
  domains   = [ "k3s.tondomaine.fr" "*.tondomaine.fr" ];
  passwordFile = config.sops.secrets."ddclient_token".path;
};
```

Ajouter `ddclient_token` dans `secrets/secrets.yaml`.

### Monitoring

Déployé via ArgoCD en Wave 5 :
- **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager)
- **Loki** + Promtail pour les logs centralisés

### Mises à jour NixOS automatiques

```nix
system.autoUpgrade = {
  enable      = true;
  flake       = "github:<org>/homelab-plateform#k3s-node";
  dates       = "weekly";
  allowReboot = false;
};
```

### Backup etcd

```nix
# Snapshot etcd hebdomadaire
systemd.services.k3s-etcd-snapshot = {
  description = "k3s etcd snapshot";
  serviceConfig.ExecStart = "${pkgs.k3s}/bin/k3s etcd-snapshot save";
};
systemd.timers.k3s-etcd-snapshot = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "weekly";
};
```

---

## Roadmap d'implémentation

```
Phase 0 — Socle (avant ou pendant l'installation physique)
├── [ ] Générer hardware-configuration.nix sur la machine cible
├── [ ] Créer flake.nix + flake.lock
├── [ ] Configurer sops-nix : chiffrer le token GitHub dans secrets.yaml
└── [ ] Créer infra/helm-values/argocd.yaml

Phase 1 — Infrastructure NixOS
├── [ ] Ajouter SANs TLS k3s (IP publique + DNS)
├── [ ] Activer fail2ban
├── [ ] Optionnel : changer port SSH
├── [ ] Intégrer sops-nix dans configuration.nix
└── [ ] nixos-rebuild switch

Phase 2 — Bootstrap ArgoCD (temporaire NodePort)
├── [ ] Ouvrir port 30443 temporairement
├── [ ] Vérifier que argocd-bootstrap crée le repo secret GitHub
├── [ ] Appliquer app-of-apps.yaml manuellement
└── [ ] Vérifier que ArgoCD lit le repo privé

Phase 3 — GitOps : infrastructure (via ArgoCD)
├── [ ] ArgoCD déploie cert-manager (Wave 1)
├── [ ] ArgoCD déploie Envoy Gateway (Wave 2)
├── [ ] Configurer ClusterIssuer Let's Encrypt (staging → prod)
├── [ ] ArgoCD déploie sa propre HTTPRoute (Wave 3)
└── [ ] nixos-rebuild : fermer port 30443, migrer argocd.nix en ClusterIP

Phase 4 — Applicatif
├── [ ] Déployer les premières applications avec HTTPRoute
├── [ ] Valider TLS automatique via cert-manager
└── [ ] Mettre en place le monitoring (optionnel)
```

---

## État cible des fichiers

```
homelab-plateform/
├── flake.nix                           ← nouveau
├── flake.lock                          ← nouveau
├── .gitignore                          (age.key déjà exclu)
├── infra/
│   ├── configuration.nix               ← modifié (SANs, fail2ban, sops, KUBECONFIG)
│   ├── hardware-configuration.nix      ← généré sur la machine
│   ├── argocd.nix                      ← modifié (values file, repo secret via sops)
│   ├── helm-values/
│   │   ├── argocd.yaml                 ← nouveau
│   │   └── envoy-gateway.yaml          ← nouveau
│   └── secrets/
│       ├── .sops.yaml                  ← nouveau
│       └── secrets.yaml                ← nouveau (chiffré, contient github_token)
└── apps/
    ├── bootstrap/
    │   └── app-of-apps.yaml
    ├── infrastructure/
    │   ├── cert-manager/
    │   ├── envoy-gateway/
    │   └── argocd-config/
    └── workloads/
        └── (applications)
```
