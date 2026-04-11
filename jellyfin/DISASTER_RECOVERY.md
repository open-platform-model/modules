# Jellyfin — Disaster Recovery Guide

Procedure to restore Jellyfin from a K8up backup after partial or total loss. Validated on kind-opm-dev (2026-03-28).

## Prerequisites

- K8up operator running in the cluster
- Access to the S3 backend (Garage, MinIO, etc.) where backups are stored
- Backup secret credentials (S3 access key, restic password)
- A recent K8up snapshot exists in the repository

## Identify Available Snapshots

```bash
kubectl get snapshots -n jellyfin --sort-by=.spec.date
```

Pick a snapshot with path `/data/jellyfin-jellyfin-config` (the PVC data, not the PreBackupPod output).

## Scenario A: In-Place Restore (pod exists, PVC exists)

Use when the application is misbehaving but the namespace and PVC are intact.

### 1. Scale down the StatefulSet

```bash
kubectl scale sts/jellyfin-jellyfin --replicas=0 -n jellyfin
kubectl wait --for=delete pod/jellyfin-jellyfin-0 -n jellyfin --timeout=120s
```

### 2. Apply a Restore CR

Replace `<SNAPSHOT_ID>` with the snapshot hash from the list above. Adjust the backend fields to match your environment's S3 endpoint, bucket, and secret names.

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: jellyfin-restore
  namespace: jellyfin
spec:
  snapshot: "<SNAPSHOT_ID>"
  restoreMethod:
    folder:
      claimName: jellyfin-jellyfin-config
  backend:
    repoPasswordSecretRef:
      name: jellyfin-backup-restic
      key: password
    s3:
      endpoint: http://<S3_ENDPOINT>
      bucket: <BUCKET>
      accessKeyIDSecretRef:
        name: jellyfin-backup-s3
        key: access-key-id
      secretAccessKeySecretRef:
        name: jellyfin-backup-s3
        key: secret-access-key
```

```bash
kubectl apply -f restore.yaml
kubectl wait --for=condition=completed restore/jellyfin-restore -n jellyfin --timeout=300s
```

### 3. Scale back up

```bash
kubectl scale sts/jellyfin-jellyfin --replicas=1 -n jellyfin
kubectl wait --for=condition=ready pod/jellyfin-jellyfin-0 -n jellyfin --timeout=120s
```

### 4. Verify

```bash
kubectl exec -n jellyfin jellyfin-jellyfin-0 -c jellyfin -- curl -s http://localhost:8096/health
# Expected: Healthy
```

Open the Jellyfin web UI and confirm users, libraries, and settings are intact.

---

## Scenario B: Full Disaster Recovery (namespace deleted)

Use when the entire `jellyfin` namespace has been lost. Backups survive in S3 independently of the cluster.

### 1. Recreate the namespace

```bash
kubectl create namespace jellyfin
```

### 2. Recreate the backup secrets

You need the original S3 credentials and restic password. If you have the saved YAML:

```bash
kubectl apply -f jellyfin-backup-secrets.yaml
```

Otherwise, create them manually:

```bash
kubectl create secret generic jellyfin-backup-s3 \
  --from-literal=access-key-id=<ACCESS_KEY> \
  --from-literal=secret-access-key=<SECRET_KEY> \
  -n jellyfin

kubectl create secret generic jellyfin-backup-restic \
  --from-literal=password=<RESTIC_PASSWORD> \
  -n jellyfin
```

### 3. Create the PVC

The PVC **must** be labeled `app.kubernetes.io/managed-by: open-platform-model` so that `opm release apply` can adopt it without error.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-jellyfin-config
  namespace: jellyfin
  labels:
    app.kubernetes.io/managed-by: open-platform-model
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: <YOUR_STORAGE_CLASS>
```

```bash
kubectl apply -f jellyfin-pvc.yaml
```

### 4. Restore from backup

Apply the same Restore CR as Scenario A (step 2), then wait for completion.

### 5. Redeploy with OPM

```bash
opm release apply releases/<environment>/jellyfin/release.cue
```

OPM will adopt the existing PVC (`configured`) and create all other resources (StatefulSet, Service, Schedule, PreBackupPod, etc.).

### 6. Verify

Wait for the pod and check health:

```bash
kubectl wait --for=condition=ready pod/jellyfin-jellyfin-0 -n jellyfin --timeout=120s
kubectl exec -n jellyfin jellyfin-jellyfin-0 -c jellyfin -- curl -s http://localhost:8096/health
```

Open the web UI and confirm all users, libraries, and playback state are restored.

---

## Important Notes

- **PVC label required:** When manually creating the PVC before `opm release apply`, add the label `app.kubernetes.io/managed-by: open-platform-model`. Without it, OPM refuses to adopt the resource.
- **Init container fixes permissions:** The `fix-permissions` init container runs `chown` on `/config` at startup, so file ownership issues after restore are handled automatically.
- **PreBackupPod checkpoint:** K8up runs a SQLite WAL checkpoint (`PRAGMA wal_checkpoint(TRUNCATE)`) on `library.db` and `jellyfin.db` before each scheduled backup. Ad-hoc backups also trigger this.
- **Backup data location:** Backups are stored in the S3 backend, not in the cluster. They survive namespace deletion, node failure, and cluster recreation — as long as the S3 storage is intact.
