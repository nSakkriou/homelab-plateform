# homelab-plateform

Dépôt de provisioning d'un nœud k3s Kubernetes sur NixOS, suivi du déploiement d'une plateforme complète via Ansible.

Le repo couvre deux phases distinctes et complémentaires :

- **Phase 1 — Infra** : installation de NixOS + k3s via un Nix Flake reproductible
- **Phase 2 — Plateforme** : déploiement des composants Kubernetes (ingress, TLS, GitOps, monitoring…) via Ansible

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   homelab-plateform                 │
│                                                     │
│  ┌──────────────────────┐  ┌──────────────────────┐ │
│  │   Phase 1 — NixOS    │  │  Phase 2 — Ansible   │ │
│  │                      │  │                      │ │
│  │  flake.nix           │  │  setup_platform.yml  │ │
│  │  infra/              │  │  ansible/roles/      │ │
│  │    configuration.nix │  │    metallb           │ │
│  │    hardware-*.nix    │  │    traefik           │ │
│  │                      │  │    cert_manager      │ │
│  │  → k3s (server)      │  │    argocd            │ │
│  │  → SSH durci         │  │    kube_dashboard    │ │
│  │  → fail2ban          │  │    monitoring        │ │
│  │  → outils kubectl… │  │                      │ │
│  └──────────────────────┘  └──────────────────────┘ │
│                                                     │
│  ┌─────────────────────────────────────────────────┐│
│  │            GitOps — ArgoCD App-of-Apps          ││
│  │  apps/app-of-apps.yaml → apps/infrastructure/  ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

### Composants déployés

| Composant | Rôle | Namespace |
|---|---|---|
| **MetalLB** | Attribution d'IPs LoadBalancer sur le réseau local | `metallb-system` |
| **Traefik** | Ingress controller (reverse proxy + routage HTTP/HTTPS) | `traefik` |
| **cert-manager** | Gestion automatique des certificats TLS (Let's Encrypt) | `cert-manager` |
| **ArgoCD** | GitOps — déploiement continu depuis ce dépôt | `argocd` |
| **Kubernetes Dashboard** | Interface web de supervision du cluster | `kubernetes-dashboard` |
| **Prometheus + Grafana** | Monitoring et métriques *(optionnel)* | `monitoring` |

---

## Prérequis

### Machine cible (serveur homelab)

- Processeur x86_64
- 8 Go RAM minimum (16 Go recommandé avec le monitoring)
- 50 Go disque minimum
- Connexion réseau (IP statique recommandée)
- Clé USB bootable NixOS ≥ 24.11

### Machine de contrôle (votre PC / WSL)

- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html) ≥ 2.14
- Python ≥ 3.9 avec pip
- `kubectl` et `helm` installés
- Accès SSH à la machine cible (clé publique déposée)

### Réseau

- Plage d'IPs libre sur votre LAN pour MetalLB (ex. `192.168.1.200–192.168.1.220`)
- Un nom de domaine pointant sur votre IP publique (pour Let's Encrypt via HTTP-01)
- Ports 80 et 443 ouverts en entrée (pour les challenges ACME)

---

## Phase 1 — NixOS + k3s

Toutes les commandes suivantes sont exécutées **sur le serveur**, depuis la session live de la clé USB (connexion internet requise).

### 1.1 Identifier le disque cible

```bash
lsblk
DISK=/dev/nvme0n1   # à adapter selon votre matériel
```

### 1.2 Partitionner (GPT + EFI + ext4)

```bash
parted $DISK -- mklabel gpt
parted $DISK -- mkpart ESP fat32 1MB 512MB
parted $DISK -- set 1 esp on
parted $DISK -- mkpart primary ext4 512MB 100%
```

### 1.3 Formater

```bash
mkfs.fat -F 32 -n boot ${DISK}p1
mkfs.ext4 -L nixos  ${DISK}p2
```

### 1.4 Monter les partitions

```bash
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot  /mnt/boot
```

### 1.5 Générer la configuration matérielle

```bash
nixos-generate-config --root /mnt
```

Cela crée `/mnt/etc/nixos/hardware-configuration.nix`, spécifique à cette machine.

### 1.6 Cloner ce dépôt

```bash
nix-shell -p git

git clone https://github.com/nSakkriou/homelab-plateform /mnt/etc/nixos/homelab

# Copier le hardware-configuration dans le repo
cp /mnt/etc/nixos/hardware-configuration.nix \
   /mnt/etc/nixos/homelab/infra/hardware-configuration.nix
```

> Ajouter `infra/hardware-configuration.nix` au staging git pour versionner la config matérielle.

### 1.7 Adapter la configuration

Éditer `infra/configuration.nix` si nécessaire :

- `networking.hostName` : nom de la machine (défaut : `k3s-node`)
- `services.k3s.extraFlags` : ajouter votre domaine dans `--tls-san`
- `users.users.admin.openssh.authorizedKeys.keys` : remplacer par votre clé publique SSH

### 1.8 Installer NixOS depuis le flake

```bash
nixos-install --flake /mnt/etc/nixos/homelab#k3s-node
```

Saisir le mot de passe root quand demandé (usage unique pour le premier boot).

### 1.9 Reboot

```bash
reboot
```

Après le reboot, vérifier que k3s tourne :

```bash
ssh admin@<IP_SERVEUR>
kubectl get nodes
```

---

## Phase 2 — Plateforme Kubernetes via Ansible

### 2.1 Configuration de l'inventaire

Copier et adapter les fichiers d'inventaire homelab :

```bash
cd ansible/
```

**`inventories/homelab.ini`** — pointer vers votre nœud k3s :

```ini
[k3s_nodes]
k3s-node ansible_host=192.168.1.100 ansible_user=admin
```

**`inventories/host_vars/k3s-node.yml`** — variables spécifiques au nœud :

```yaml
dns:
  base_host: nathansakkriou.com   # votre domaine
```

**`inventories/group_vars/k3s_nodes.yml`** — composants à activer/désactiver et versions Helm :

```yaml
metallb:
  enabled: true
  ip_range: "192.168.1.200-192.168.1.220"   # à adapter à votre réseau

cert_manager:
  enabled: true
  contact_email: "admin@example.com"        # email Let's Encrypt

traefik:
  enabled: true

argocd:
  enabled: true

kube_dashboard:
  enabled: true

monitoring:
  enabled: false   # activer si vous avez ≥ 16 Go RAM
```

### 2.2 Installation des dépendances Ansible

```bash
cd ansible/

# Collections Ansible Galaxy
ansible-galaxy collection install -r requirements.yml

# Dépendances Python
pip install -r python_dependencies.txt
```

### 2.3 Déploiement de la plateforme

```bash
# Depuis le dossier ansible/
ansible-playbook -i inventories/homelab.ini setup_platform.yml
```

Le playbook :
1. Se connecte au nœud k3s via SSH
2. Récupère le kubeconfig et l'adapte avec l'IP réelle du nœud
3. Déploie les composants Kubernetes dans l'ordre

### 2.4 Déploiement par composant (tags)

Pour déployer ou mettre à jour un seul composant :

```bash
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags metallb
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags cert_manager
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags traefik
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags argocd
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags kube_dashboard
ansible-playbook -i inventories/homelab.ini setup_platform.yml --tags monitoring
```

### 2.5 Démantèlement

```bash
ansible-playbook -i inventories/homelab.ini teardown_platform.yml
```

---

## Phase 3 — GitOps avec ArgoCD

Une fois ArgoCD déployé, appliquer le fichier App-of-Apps :

```bash
kubectl apply -f apps/app-of-apps.yaml
```

ArgoCD synchronisera automatiquement les manifestes depuis `apps/infrastructure/` (Traefik, cert-manager, etc.) vers le cluster.

Accès à l'interface ArgoCD :

```
https://argocd.<votre-domaine>
```

Mot de passe initial récupérable avec :

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

---

## Structure du dépôt

```
homelab-plateform/
│
├── flake.nix                        # Nix Flake — point d'entrée NixOS
│
├── infra/
│   ├── configuration.nix            # Config NixOS : k3s, SSH, réseau, paquets
│   └── hardware-configuration.nix   # Généré par nixos-generate-config (gitignored)
│
├── apps/
│   ├── app-of-apps.yaml             # ArgoCD App-of-Apps (point d'entrée GitOps)
│   ├── infrastructure/              # Manifestes ArgoCD des composants infra
│   │   ├── traefik.yaml             # Application ArgoCD — Traefik
│   │   ├── traefik-resources.yaml   # IngressRoute, middlewares Traefik
│   │   └── cert-manager.yaml        # Application ArgoCD — cert-manager
│   └── k8s/
│       ├── argocd/                  # IngressRoute ArgoCD
│       ├── cert-manager/            # ClusterIssuers Let's Encrypt
│       └── traefik/                 # Config Traefik (middlewares, TLS store…)
│
└── ansible/
    ├── ansible.cfg                  # Config Ansible (inventory, roles path…)
    ├── setup_platform.yml           # Playbook principal — déploiement plateforme
    ├── teardown_platform.yml        # Playbook de démantèlement
    ├── requirements.yml             # Collections Ansible Galaxy
    ├── python_dependencies.txt      # Dépendances Python
    ├── Dockerfile                   # Image Docker pour exécuter Ansible en CI
    │
    ├── inventories/
    │   ├── homelab.ini              # Inventaire homelab (nœud k3s unique)
    │   ├── group_vars/
    │   │   └── k3s_nodes.yml        # Variables communes : versions Helm, flags
    │   └── host_vars/
    │       └── k3s-node.yml         # Variables du nœud : domaine, IP pool…
    │
    └── roles/k8s/
        ├── meta/main.yml            # Dépendances et ordre des rôles
        ├── metallb/                 # MetalLB — LoadBalancer L2
        ├── traefik/                 # Traefik — Ingress Controller
        ├── cert_manager/            # cert-manager + ClusterIssuers
        ├── argocd/                  # ArgoCD — GitOps
        ├── kube_dashboard/          # Kubernetes Dashboard
        ├── monitoring/              # Prometheus + Grafana (kube-prometheus-stack)
        ├── ingress_controller/      # nginx ingress (legacy, remplacé par Traefik)
        ├── external_secrets/        # External Secrets Operator (optionnel, AWS)
        ├── eck/                     # Elastic Cloud on Kubernetes (optionnel)
        ├── logging/                 # ELK stack — Elasticsearch/Kibana (optionnel)
        ├── postgres_operator/       # Zalando Postgres Operator (optionnel)
        ├── rancher/                 # Rancher multi-cluster (optionnel)
        └── apps/                    # Namespaces applicatifs (optionnel)
```

---

## Notes importantes

### Ordre de déploiement

Les composants doivent être déployés dans cet ordre (géré automatiquement par Ansible) :

1. **MetalLB** — nécessaire avant tout service de type LoadBalancer
2. **Traefik** — nécessite MetalLB pour obtenir une IP externe
3. **cert-manager** — nécessite Traefik pour les challenges HTTP-01
4. **ArgoCD** — utilise Traefik comme ingress + cert-manager pour TLS
5. **Kubernetes Dashboard** — utilise Traefik + cert-manager
6. **Monitoring** *(optionnel)* — utilise Traefik + cert-manager

### Certificats TLS

Deux ClusterIssuers sont créés :

- `letsencrypt-staging` : pour les tests (certificats non valides en prod)
- `letsencrypt-prod` : pour la production (rate limits Let's Encrypt applicables)

Utiliser `letsencrypt-staging` en développement pour éviter les rate limits.

### kubeconfig

Le kubeconfig est automatiquement récupéré depuis le nœud k3s lors de l'exécution du playbook. Il est sauvegardé temporairement dans `/tmp/k3s-homelab.yaml` sur la machine de contrôle.

Pour utiliser kubectl directement depuis la machine de contrôle :

```bash
export KUBECONFIG=/tmp/k3s-homelab.yaml
kubectl get nodes
```
