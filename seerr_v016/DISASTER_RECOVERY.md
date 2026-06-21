# Seerr — Disaster Recovery Guide

Procedure to restore Seerr from a K8up backup after partial or total loss. Validated on kind-opm-dev (2026-03-28).

## Prerequisites

- K8up operator running in the cluster
- Access to the S3 backend (Garage, MinIO, etc.) where backups are stored
- Backup secret credentials (S3 access key, restic password)
- A recent K8up snapshot exists in the repository

## Identify Available Snapshots

```bash
kubectl get snapshots -n seerr --sort-by=.spec.date
```

Pick a snapshot with path `/data/seerr-seerr-config` (the PVC data, not the PreBackupPod output).

## Scenario A: In-Place Restore (pod exists, PVC exists)

Use when the application is misbehaving but the namespace and PVC are intact.

### 1. Scale down the StatefulSet

```bash
kubectl scale sts/seerr-seerr --replicas=0 -n seerr
kubectl wait --for=delete pod/seerr-seerr-0 -n seerr --timeout=120s
```

### 2. Apply a Restore CR

Replace `<SNAPSHOT_ID>` with the snapshot hash from the list above. Adjust the backend fields to match your environment's S3 endpoint, bucket, and secret names.

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: seerr-restore
  namespace: seerr
spec:
  snapshot: "<SNAPSHOT_ID>"
  restoreMethod:
    folder:
      claimName: seerr-seerr-config
  backend:
    repoPasswordSecretRef:
      name: seerr-backup-restic
      key: password
    s3:
      endpoint: http://<S3_ENDPOINT>
      bucket: <BUCKET>
      accessKeyIDSecretRef:
        name: seerr-backup-s3
        key: access-key-id
      secretAccessKeySecretRef:
        name: seerr-backup-s3
        key: secret-access-key
```

```bash
kubectl apply -f restore.yaml
kubectl wait --for=condition=completed restore/seerr-restore -n seerr --timeout=300s
```

### 3. Scale back up

```bash
kubectl scale sts/seerr-seerr --replicas=1 -n seerr
kubectl wait --for=condition=ready pod/seerr-seerr-0 -n seerr --timeout=120s
```

### 4. Verify

```bash
kubectl exec -n seerr seerr-seerr-0 -c seerr -- wget -qO- http://localhost:5055/api/v1/status
# Expected: JSON with version, commitTag, etc.
```

Open the Seerr web UI and confirm users, media requests, and integrations are intact.

---

## Scenario B: Full Disaster Recovery (namespace deleted)

Use when the entire `seerr` namespace has been lost. Backups survive in S3 independently of the cluster.

### 1. Recreate the namespace

```bash
kubectl create namespace seerr
```

### 2. Recreate the backup secrets

Seerr backup secrets are auto-created by OPM from literal values in the release config. For DR, you need to recreate them manually **with the OPM management label** so that `opm release apply` can adopt them.

If you have the saved YAML:

```bash
kubectl apply -f seerr-backup-secrets.yaml
```

Otherwise, create them manually (values from your release.cue `backup` config):

```bash
kubectl create secret generic seerr-backup-s3 \
  --from-literal=access-key-id=<ACCESS_KEY> \
  --from-literal=secret-access-key=<SECRET_KEY> \
  -n seerr

kubectl create secret generic seerr-backup-restic \
  --from-literal=password=<RESTIC_PASSWORD> \
  -n seerr
```

Then label both secrets so OPM can adopt them:

```bash
kubectl label secret seerr-backup-s3 seerr-backup-restic \
  -n seerr app.kubernetes.io/managed-by=open-platform-model
```

### 3. Create the PVC

The PVC **must** be labeled `app.kubernetes.io/managed-by: open-platform-model` so that `opm release apply` can adopt it without error.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seerr-seerr-config
  namespace: seerr
  labels:
    app.kubernetes.io/managed-by: open-platform-model
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
  storageClassName: <YOUR_STORAGE_CLASS>
```

```bash
kubectl apply -f seerr-pvc.yaml
```

### 4. Restore from backup

Apply the same Restore CR as Scenario A (step 2), then wait for completion.

### 5. Redeploy with OPM

```bash
opm release apply releases/<environment>/seerr/release.cue
```

OPM will adopt the existing PVC and secrets (`configured`) and create all other resources (StatefulSet, Service, Schedule, PreBackupPod, etc.).

### 6. Verify

Wait for the pod and check health:

```bash
kubectl wait --for=condition=ready pod/seerr-seerr-0 -n seerr --timeout=120s
kubectl exec -n seerr seerr-seerr-0 -c seerr -- wget -qO- http://localhost:5055/api/v1/status
```

Open the web UI and confirm all users, media requests, and integrations are restored.

---

## Important Notes

- **PVC and secrets must be labeled:** When manually creating resources before `opm release apply`, add the label `app.kubernetes.io/managed-by: open-platform-model`. Without it, OPM refuses to adopt the resource. This applies to both the PVC and the backup secrets (which OPM normally auto-creates from literal values).
- **Init container fixes permissions:** The `fix-permissions` init container runs `chown -R 1000:1000 /app/config` at startup, so file ownership issues after restore are handled automatically.
- **PreBackupPod checkpoint (SQLite only):** K8up runs `PRAGMA wal_checkpoint(TRUNCATE)` on `db.sqlite3` before each backup. This is skipped when Seerr is configured with PostgreSQL.
- **Backup data location:** Backups are stored in the S3 backend, not in the cluster. They survive namespace deletion, node failure, and cluster recreation — as long as the S3 storage is intact.
