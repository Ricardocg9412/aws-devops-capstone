# Docker Run 

```sh
docker run -d --name inventory-api \
  -p 127.0.0.1:8080:8080 inventory-api:1.0
```

## Port Foreard for service 

```sh
kubectl port-forward service/inventory-api-service 8000:80 -n devops-lab
```

kubectl port-forward -n devops-lab service/inventory-api 8080:80

## Kind 

kubectl cluster-info --context kind-devops-lab
kind load docker-image inventory-api:1.0 --name devops-lab
kind get clusters
kubectl get kind-devops-lab

## Helm 

helm upgrade --install inventory-api ./helm/inventory-api \
  --namespace devops-lab \
  --create-namespace \
  --set autoscaling.enabled=true \
  --set replicaCount=null \
  -f ./helm/inventory-api/values-dev.yaml \
  --wait --timeout 3m