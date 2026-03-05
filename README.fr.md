---
title: POC Redémarrage de nœuds AKS sans interruption avec Kured
description: Preuve de concept démontrant le redémarrage de nœuds sans interruption sur AKS à l'aide de Kured et des PodDisruptionBudgets
author: devopsabcs-engineering
ms.date: 2026-03-04
---

> **Note :** This document is a French translation of [README.md](README.md).
> The English version is the source of truth.

## Vue d'ensemble

Cette preuve de concept démontre le redémarrage de nœuds sans interruption sur Azure Kubernetes Service (AKS) à l'aide de [Kured](https://kured.dev/) (KUbernetes REboot Daemon) combiné aux PodDisruptionBudgets. Lorsque les nœuds Ubuntu installent des mises à jour de sécurité automatiques nécessitant un redémarrage, Kured détecte le redémarrage en attente, draine chaque nœud un par un tout en respectant les contraintes PDB, redémarre le nœud, puis passe au suivant -- le tout sans perdre une seule requête vers la charge de travail en cours d'exécution.

## Architecture

```text
+---------------------+       +----------------+       +-----------------+
| Nœud Ubuntu         |       | DaemonSet Kured|       | API Kubernetes  |
| (unattended-upgrade)|       | (par nœud)     |       |                 |
+---------------------+       +----------------+       +-----------------+
         |                            |                         |
   1. Installe les mises à jour       |                         |
      de sécurité, écrit              |                         |
      /var/run/reboot-required         |                         |
         |                            |                         |
         +---> 2. Kured sonde --------+                         |
               le fichier sentinelle                            |
                      |                                         |
                3. Acquiert le verrou global (un nœud à la fois)
                      |                                         |
                4. Cordon + drain du nœud (respecte le PDB) --->|
                      |                                         |
                5. Redémarre le nœud                            |
                      |                                         |
                6. Le nœud rejoint, décordonné ---------------->|
                      |                                         |
                7. Libère le verrou, le prochain nœud continue  |
```

## Fonctionnement

1. **Détection de la sentinelle** -- Ubuntu `unattended-upgrades` installe les correctifs de sécurité et écrit `/var/run/reboot-required` lorsqu'un redémarrage est nécessaire.
2. **Boucle de sondage** -- Kured s'exécute en tant que DaemonSet sur chaque nœud et vérifie le fichier sentinelle à intervalle configurable (1 minute dans cette POC).
3. **Verrou distribué** -- Avant d'agir, le pod Kured acquiert un verrou global pour que seul un nœud redémarre à la fois.
4. **Cordon et drainage** -- Kured cordonne le nœud et draine tous les pods de charge de travail. Le drainage respecte les PodDisruptionBudgets, garantissant que le nombre minimum de pods reste disponible.
5. **Redémarrage** -- Une fois le nœud drainé, Kured déclenche le redémarrage.
6. **Réintégration** -- Après le redémarrage, Kubernetes marque le nœud comme Ready. Kured décordonne le nœud pour que de nouveaux pods puissent y être planifiés.
7. **Libération et répétition** -- Kured libère le verrou global et le prochain nœud en attente commence le même cycle.

## Structure du dépôt

```text
aks-kured-poc/
├── .github/
│   └── workflows/
│       ├── deploy.yml          # Provisionne AKS, installe Kured, déploie la charge de travail (idempotent)
│       ├── test.yml            # Exécute le test de disponibilité et simule les redémarrages (fenêtre large par défaut)
│       └── teardown.yml        # Supprime le groupe de ressources et désactive la planification des tests
├── infra/
│   ├── main.bicep              # Cluster AKS + Log Analytics + DCR + Prometheus + Grafana (Bicep)
│   └── parameters.json         # Valeurs de paramètres par défaut
├── k8s/
│   ├── kured-values.yaml       # Valeurs Helm pour Kured
│   └── workload/
│       ├── namespace.yaml      # Espace de noms demo
│       ├── deployment.yaml     # zero-downtime-web (3 réplicas, anti-affinité)
│       ├── service.yaml        # Service LoadBalancer
│       └── pdb.yaml            # PodDisruptionBudget (minAvailable: 2)
├── scripts/
│   ├── availability-probe.sh   # Sonde HTTP continue avec sortie CSV
│   ├── e2e-test.sh             # Validation bout en bout des redémarrages
│   └── collect-artifacts.sh    # Collecte les artefacts de preuve du cluster
├── test-results/
│   └── availability-history.csv # Résultats de test cumulatifs (mis à jour automatiquement par le CI)
├── .gitignore
├── README.md
└── README.fr.md            # Traduction française
```

## Prérequis

- **Abonnement Azure** avec les permissions nécessaires pour créer des groupes de ressources, des clusters AKS et des attributions de rôles
- **Azure CLI** 2.60 ou ultérieur
- **Helm** 3.x
- **kubectl** correspondant à la version de votre cluster
- **Dépôt GitHub** avec des informations d'identification fédérées OIDC configurées (voir ci-dessous)
- **bash**, **curl**, **jq** et **bc** (pour exécuter les scripts localement)

## Configuration OIDC pour GitHub Actions

Les workflows GitHub Actions s'authentifient auprès d'Azure à l'aide d'OpenID Connect (OIDC) avec une information d'identification fédérée. Aucun secret client n'est stocké.

### 1. Créer une inscription d'application et un principal de service

```bash
az ad app create --display-name "aks-kured-poc-github"
```

Notez l'`appId` dans la sortie.

### 2. Créer un principal de service et attribuer le rôle Contributeur

```bash
APP_ID="<appId de l'étape précédente>"

az ad sp create --id "$APP_ID"

az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

### 3. Ajouter une information d'identification fédérée pour votre dépôt GitHub

```bash
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "aks-kured-poc-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<OWNER>/aks-kured-poc:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Remplacez `<OWNER>` par votre organisation ou nom d'utilisateur GitHub. Si les workflows s'exécutent sur des demandes de tirage (pull requests) ou d'autres branches, ajoutez des informations d'identification fédérées supplémentaires avec le sujet approprié.

### 4. Configurer les secrets du dépôt GitHub

Ajoutez les secrets suivants à votre dépôt sous **Settings > Secrets and variables > Actions** :

| Nom du secret            | Valeur                                                   |
| ------------------------ | -------------------------------------------------------- |
| `AZURE_CLIENT_ID`        | ID d'application (client) de l'inscription d'application |
| `AZURE_TENANT_ID`        | ID du locataire Azure AD                                 |
| `AZURE_SUBSCRIPTION_ID`  | ID de l'abonnement Azure cible                           |

## Démarrage rapide

### Option A : GitHub Actions (recommandé)

1. Poussez ce dépôt vers GitHub avec les secrets OIDC configurés.
2. Accédez à **Actions** et déclenchez le workflow **Deploy AKS Kured POC** (`deploy.yml`). Acceptez les valeurs par défaut ou modifiez la région, le nombre de nœuds, la taille des VM, etc. À la fin du workflow, le **résumé du job** affiche une URL publique cliquable pour le service déployé.
3. Une fois le déploiement terminé, déclenchez le workflow **Test AKS Kured POC** (`test.yml`). Définissez `simulate_reboot` sur `true` pour créer des fichiers sentinelles sur tous les nœuds. Par défaut, le workflow de test utilise une **fenêtre de redémarrage 24/7** (tous les jours, 0 h -- 23 h 59) afin que les redémarrages se déclenchent immédiatement sans attendre la fenêtre de production restreinte. Le workflow s'exécute également selon une **planification cron de 30 minutes** pour alimenter en continu l'historique de disponibilité.
4. Après la validation, déclenchez le workflow **Teardown AKS Kured POC** (`teardown.yml`). Tapez `DELETE` lorsqu'on vous le demande pour confirmer. Le démontage **désactive également la planification du workflow de test** pour éviter les exécutions cron échouées sur un cluster supprimé.

> **Conseil :** Les workflows `deploy.yml` et `test.yml` sont entièrement idempotents et peuvent être relancés à tout moment.

### Option B : CLI manuelle

```bash
# Variables
RESOURCE_GROUP="rg-aks-kured-poc"
CLUSTER_NAME="aks-kured-poc"
LOCATION="canadacentral"

# 1. Créer le groupe de ressources
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# 2. Déployer l'infrastructure
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters infra/parameters.json

# 3. Obtenir les informations d'identification du cluster
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME"

# 4. Installer Kured via Helm
helm repo add kured https://kubereboot.github.io/charts
helm repo update
helm upgrade --install kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --wait

# 5. Déployer la charge de travail d'exemple
kubectl apply -f k8s/workload/namespace.yaml
kubectl apply -f k8s/workload/deployment.yaml
kubectl apply -f k8s/workload/service.yaml
kubectl apply -f k8s/workload/pdb.yaml

# 6. Attendre le déploiement
kubectl rollout status deployment/zero-downtime-web --namespace demo --timeout=300s
```

## Configuration de Kured

Les valeurs Helm de Kured dans `k8s/kured-values.yaml` définissent le comportement suivant :

| Paramètre         | Valeur            | Objectif                                                                 |
| ------------------ | ----------------- | ------------------------------------------------------------------------ |
| `rebootDays`       | lu-ve             | Redémarrages uniquement en semaine                                       |
| `startTime`        | 2 h UTC           | Début de la fenêtre de perturbation                                      |
| `endTime`          | 6 h UTC           | Fin de la fenêtre de perturbation                                        |
| `period`           | 1m                | Fréquence de vérification du fichier sentinelle (courte pour la POC)     |
| `drainGracePeriod` | 60s               | Délai de grâce pour la terminaison des pods pendant le drainage          |
| `drainTimeout`     | 300s              | Temps maximum d'attente pour la fin du drainage                          |
| `lockTtl`          | 30m               | Durée de vie du verrou distribué de redémarrage                          |
| `lockReleaseDelay` | 1m                | Délai après le redémarrage avant de libérer le verrou (court pour la POC)|
| `concurrency`      | 1                 | Un seul nœud redémarre à la fois                                        |

### Taille des VM et fiabilité

La taille de VM par défaut est `Standard_D4s_v3` (4 vCPU / 16 Go de RAM).
L'utilisation d'une VM plus grande réduit la probabilité d'échecs de sonde
transitoires pendant les redémarrages. Avec des tailles plus petites comme
`Standard_DS2_v2` (2 vCPU / 7 Go de RAM), l'Azure Load Balancer achemine
occasionnellement une requête vers un nœud en cours de drainage pendant les
1 à 2 secondes avant la mise à jour du pool backend, entraînant un seul échec de
sonde par cycle de redémarrage.

Pour modifier la taille des VM, remplacez l'entrée `vm_size` lors du
déclenchement de `deploy.yml` ou mettez à jour le paramètre `vmSize` dans
`infra/main.bicep`.

### Remplacement de la fenêtre de perturbation pour les démonstrations

Par défaut, Kured ne redémarre que dans la fenêtre 2--6 h UTC en semaine. Pour une démonstration immédiate, élargissez la fenêtre :

```bash
helm upgrade kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --set configuration.startTime="0am" \
  --set configuration.endTime="11:59pm" \
  --set 'configuration.rebootDays={mo,tu,we,th,fr,sa,su}'
```

> **Remarque :** Le workflow `test.yml` applique automatiquement cette fenêtre large.
> Les valeurs d'entrée par défaut sont `0am`--`11:59pm` tous les sept jours afin que
> le redémarrage de démonstration se déclenche immédiatement. Modifiez les entrées
> pour restaurer la fenêtre restreinte si nécessaire.

Le workflow de test expose ces paramètres d'entrée :

| Entrée | Par défaut | Description |
| --- | --- | --- |
| `kured_start_time` | `0am` | Heure de début de la fenêtre de redémarrage |
| `kured_end_time` | `11:59pm` | Heure de fin de la fenêtre de redémarrage |
| `kured_reboot_days` | `mo,tu,we,th,fr,sa,su` | Liste séparée par des virgules des jours de redémarrage autorisés |

## Guide de démonstration

Suivez ces étapes pour exécuter une démonstration complète de redémarrage sans interruption.

### Étape 1 : Déployer

Déclenchez le workflow `deploy.yml` depuis GitHub Actions (ou suivez les étapes CLI manuelles ci-dessus). Cela provisionne le cluster AKS, installe Kured et déploie la charge de travail d'exemple.

### Étape 2 : Vérifier

Confirmez que le cluster est dans l'état attendu :

```bash
# Les 3 nœuds doivent être Ready
kubectl get nodes -o wide

# 3 pods fonctionnant sur des nœuds séparés (anti-affinité)
kubectl get pods -n demo -o wide

# Le PDB est actif avec minAvailable: 2
kubectl get pdb -n demo

# Le DaemonSet Kured fonctionne sur chaque nœud
kubectl get daemonset kured -n kube-system
```

### Étape 3 : Remplacer la fenêtre de perturbation (si nécessaire)

Si vous utilisez le flux **CLI manuelle** et que l'heure actuelle est en dehors de la fenêtre 2--6 h UTC en semaine, élargissez la planification de Kured :

```bash
helm upgrade kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --set configuration.startTime="0am" \
  --set configuration.endTime="11:59pm" \
  --set 'configuration.rebootDays={mo,tu,we,th,fr,sa,su}'
```

> **Remarque :** Lorsque vous utilisez le workflow GitHub Actions `test.yml`, cette
> étape est gérée automatiquement. Le workflow utilise par défaut une fenêtre 24/7
> (`0am`--`11:59pm`, tous les jours) et reconfigure Kured via `helm upgrade` avant
> de créer les fichiers sentinelles.

### Étape 4 : Exécuter le test

Déclenchez le workflow `test.yml` avec `simulate_reboot` défini sur `true`. Cela élargit la fenêtre de redémarrage de Kured (en utilisant les paramètres d'entrée), crée des fichiers sentinelles `/var/run/reboot-required` sur chaque nœud et exécute une sonde de disponibilité continue.

Alternativement, exécutez le test bout en bout local :

```bash
chmod +x scripts/e2e-test.sh
./scripts/e2e-test.sh
```

### Étape 5 : Surveiller

Surveillez l'activité de Kured et l'état des nœuds en temps réel :

```bash
# Journaux de Kured (cherchez « Reboot required » et « Commanding reboot »)
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --follow --prefix

# État des nœuds (surveillez SchedulingDisabled, NotReady, puis Ready)
watch kubectl get nodes -o wide

# Distribution des pods (les pods sont replanifiés sur d'autres nœuds pendant le drainage)
watch kubectl get pods -n demo -o wide
```

### Étape 6 : Observer

Pendant le test, vous devriez observer la séquence suivante pour chaque nœud :

1. Kured détecte la sentinelle et acquiert le verrou.
2. Le nœud est cordonné (`SchedulingDisabled`).
3. Les pods sont drainés (le PDB garantit qu'au moins 2 restent disponibles).
4. Le nœud passe à `NotReady` pendant le redémarrage.
5. Le nœud revient à `Ready` et est décordonné.
6. Kured libère le verrou et le nœud suivant commence.

Tout au long de ce cycle, le point de terminaison du service reste accessible avec zéro requête échouée.

### Étape 7 : Valider

Après que tous les nœuds ont redémarré et sont revenus à Ready :

```bash
# Vérifier les résultats de la sonde (devrait afficher un taux de succès de 100 %)
cat test-results/*/test-summary.txt

# Collecter les artefacts de preuve
chmod +x scripts/collect-artifacts.sh
./scripts/collect-artifacts.sh
```

Consultez la section [Surveillance](#surveillance) pour les requêtes KQL à valider dans le portail Azure.

### Étape 8 : Démontage

Déclenchez le workflow `teardown.yml` et tapez `DELETE` pour confirmer. Cela supprime l'intégralité du groupe de ressources et **désactive la planification du workflow de test**.

## Tests

### Exécutions planifiées

Le workflow `test.yml` s'exécute automatiquement **toutes les 30 minutes** via une planification cron. Chaque exécution :

1. Crée des fichiers sentinelles de redémarrage sur tous les nœuds (déclenchant Kured)
2. Exécute une sonde de disponibilité de 20 minutes **pendant que les redémarrages sont en cours**
3. Collecte les compteurs de redémarrage par nœud et ajoute les résultats à [test-results/availability-history.csv](test-results/availability-history.csv)

Le CSV est rendu sous forme de tableau triable dans l'interface GitHub, et un résumé de l'historique apparaît sur la page **résumé du job** de l'exécution du workflow.

Les exécutions planifiées utilisent les valeurs d'entrée par défaut :

| Paramètre | Par défaut |
| --- | --- |
| `environment` | `poc` |
| `test_duration` | `1200` (20 minutes) |
| `simulate_reboot` | `true` |
| `kured_start_time` | `0am` |
| `kured_end_time` | `11:59pm` |
| `kured_reboot_days` | `mo,tu,we,th,fr,sa,su` |

> **Pourquoi 20 minutes ?** Kured redémarre les nœuds un par un. Avec un intervalle
> de sondage de 1 minute et un délai de libération du verrou de 1 minute, chaque nœud
> nécessite environ 5 à 7 minutes pour le cordon, le drainage, le redémarrage et la
> réintégration. Trois nœuds requièrent environ 15 à 20 minutes au total. La sonde de
> disponibilité doit durer assez longtemps pour capturer toutes les transitions.

Pour mettre en pause les exécutions planifiées, désactivez le workflow depuis **Actions > Test AKS Kured POC > ··· > Disable workflow**. Réactivez-le lorsque vous êtes prêt.

> **Important :** La planification suppose que le cluster AKS est déjà déployé. Si le cluster a été supprimé, désactivez la planification pour éviter les exécutions échouées.

> **Problème connu -- arrêt automatique par politique Azure :** Certains
> abonnements Azure appliquent des politiques qui arrêtent ou désallouent les
> clusters AKS à minuit. Lorsque le cluster est arrêté, kubectl ne peut pas
> atteindre le serveur API et les exécutions planifiées échoueront avec
> `dial tcp: lookup ... no such host`. Si votre abonnement applique une telle
> politique, désactivez la planification cron en dehors des heures ouvrables ou
> relancez `deploy.yml` chaque matin pour démarrer le cluster avant la reprise
> des tests.

### Test bout en bout

Le script `scripts/e2e-test.sh` exécute un cycle de validation complet : vérifie les prérequis, lance une sonde de disponibilité continue, crée des fichiers sentinelles de redémarrage sur tous les nœuds, surveille les transitions de nœuds et rapporte la réussite ou l'échec avec des métriques détaillées.

```bash
chmod +x scripts/e2e-test.sh
./scripts/e2e-test.sh
```

Les résultats sont écrits dans `test-results/<horodatage>/`.

### Sonde de disponibilité autonome

Le script `scripts/availability-probe.sh` exécute une sonde HTTP légère contre le service pour une durée spécifiée.

```bash
SERVICE_IP=$(kubectl get svc zero-downtime-web -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
chmod +x scripts/availability-probe.sh
./scripts/availability-probe.sh "$SERVICE_IP" 600
```

### Collecte d'artefacts

Le script `scripts/collect-artifacts.sh` rassemble l'état des nœuds, l'état des pods, la configuration PDB, les événements, les journaux de Kured et les descriptions des nœuds dans `proof-artifacts/<horodatage>/`.

```bash
chmod +x scripts/collect-artifacts.sh
./scripts/collect-artifacts.sh
```

## Surveillance

### Azure Managed Prometheus et Grafana

Par défaut, `deploy.yml` active la collecte de métriques **Azure Managed Prometheus**
et crée une instance **Azure Managed Grafana**. Cela fournit des métriques
détaillées au niveau des nœuds (CPU, mémoire, disque, réseau) et des tableaux de bord
Kubernetes préconfigurés.

Après le déploiement, ouvrez le point de terminaison Grafana affiché dans le
résumé du workflow de déploiement (ou trouvez-le dans le portail Azure sous la
ressource Grafana). Les tableaux de bord intégrés pour Kubernetes sont
provisionnés automatiquement.

Pour désactiver Prometheus, définissez l'entrée `enable_prometheus` sur `false`
lors du déclenchement de `deploy.yml`.

### Commandes kubectl

```bash
# Journaux de Kured -- cherchez la détection de sentinelle, l'acquisition du verrou, le drainage et le redémarrage
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=200

# État des nœuds au fil du temps
kubectl get nodes -o wide

# État du PDB pendant les drainages
kubectl get pdb -n demo -o wide

# Événements dans l'espace de noms demo
kubectl get events -n demo --sort-by='.lastTimestamp'
```

### Requêtes KQL pour Container Insights

Ces requêtes peuvent être exécutées dans le portail Azure sous **Espace de travail Log Analytics > Journaux** ou sous le panneau **Surveillance > Journaux** du cluster AKS.

**Transitions d'état des nœuds (Ready/NotReady/Unknown) :**

```kql
KubeNodeInventory
| where TimeGenerated > ago(4h)
| project TimeGenerated, Computer, Status
| order by TimeGenerated asc
```

**Événements de cycle de vie des pods pendant les redémarrages :**

> **Remarque :** Container Insights ne collecte que les événements de type `Warning`
> par défaut. Les événements normaux de planification des pods (`Scheduled`, `Pulled`,
> `Started`) ne sont pas capturés. La requête ci-dessous affiche les événements de
> niveau avertissement qui surviennent lors des redémarrages de nœuds.

```kql
KubeEvents
| where TimeGenerated > ago(4h)
| where Namespace in ("demo", "kube-system", "")
| where Reason in ("NodeNotReady", "Rebooted", "KubeletIsDown", "Killing",
                   "FailedScheduling", "Unhealthy", "FailedMount",
                   "FailedCreatePodSandBox", "ContainerdStart")
| project TimeGenerated, Namespace, Name, Reason, Message, ObjectKind
| order by TimeGenerated asc
```

**Journaux des conteneurs Kured :**

> **Remarque :** Les journaux de `kube-system` nécessitent que la DCR soit configurée
> avec `namespaceFilteringMode: Include` et `kube-system` dans la liste des espaces
> de noms. Après le déploiement avec `deploy.yml`, attendez 5 à 10 minutes pour que
> l'agent commence la collecte.

```kql
ContainerLogV2
| where TimeGenerated > ago(4h)
| where PodNamespace == "kube-system"
| where PodName startswith "kured-"
| project TimeGenerated, PodName, LogMessage
| order by TimeGenerated asc
```

**Nombre de redémarrages par nœud (identifiants de démarrage distincts) :**

```kql
KubeEvents
| where TimeGenerated > ago(24h)
| where Reason == "Rebooted"
| extend BootId = extract("boot id: ([a-f0-9-]+)", 1, Message)
| summarize Reboots = dcount(BootId), LastReboot = max(TimeGenerated) by Name
| order by Name asc
```

**Vérifier l'absence de lacunes dans la disponibilité de l'application :**

```kql
ContainerLogV2
| where TimeGenerated > ago(4h)
| where PodNamespace == "demo"
| where PodName startswith "zero-downtime-web"
| summarize Count = count() by bin(TimeGenerated, 1m)
| order by TimeGenerated asc
```

## Nettoyage

### Option A : GitHub Actions

Déclenchez le workflow `teardown.yml` et tapez `DELETE` pour confirmer. Le workflow supprime l'intégralité du groupe de ressources (`rg-aks-kured-poc`) et toutes les ressources qu'il contient. Il **désactive également la planification du workflow de test** pour éviter les exécutions cron échouées.

### Option B : Azure CLI

```bash
az group delete --name rg-aks-kured-poc --yes --no-wait
```

Pour attendre la fin de la suppression :

```bash
az group wait --deleted --resource-group rg-aks-kured-poc --timeout 1800
```
