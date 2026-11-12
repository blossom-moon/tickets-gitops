# Bootstrap

Виконується вручну один раз на чистому кластері. Усе інше Argo CD бере з Git.

## 1. Secret застосунку (паролі не зберігаються в Git)

```bash
kubectl create namespace kostetska
kubectl create secret generic tickets-secrets -n kostetska \
  --from-literal=db-password='<пароль БД>' \
  --from-literal=keycloak-client-secret='<будь-яке значення>'
```

Чарт посилається на цей Secret через `secrets.existingSecret: tickets-secrets` у `charts/tickets/values-minikube.yaml`.

## 2. Кореневий Application

```bash
kubectl apply -f bootstrap/root-app.yaml
```
