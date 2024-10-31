# dify-kubernetes

Deploy [Dify](https://dify.ai/) on Kubernetes

> Feel free to raise issues or email me if you need support 😊
[Email](mailto:a623719265@gmail.com)

> Star 🌟 if this repo help you ~~

## Development Plan

> This branch use PVC as storage instead of hostPath, thanks contributions from the community!

### Add ssrf proxy component

Integrated ssrf proxy component into `dify-deployment.yaml` and `dify-mirror-deployment.yaml`. You can get files in `dify/middleware`.

### Other vector database

**Welcome PR!**
I have a development plan for this and will start in October 2024.

You can get files in `dify/database`.

I create a new branch for HA database setup which is `feature/dify-database-HA-setup`, and a folder `database-ha` under folder `dify`. Feel free to add files if you want to contribute to HA database!


## How to use

### Clone the repository

```shell

git clone https://github.com/Winson-030/dify-kubernetes.git
git checkout feature/pvc-volume 
kubectl apply -f dify-deployment.yaml

```

### Apply Directly

```shell

kubectl apply -f https://raw.githubusercontent.com/Winson-030/dify-kubernetes/feature/pvc-volume/dify-deployment.yaml

```

If cluster is not able to connect dockerhub directly(for most users in China), apply deployment with mirror registry preset below.

```shell

kubectl apply -f https://cdn.jsdelivr.net/gh/Winson-030/dify-kubernetes@feature/pvc-volume/dify-mirror-deployment.yaml

```

After Deployed, you can visit the dify web site via nodeport at `http://$(PUBLIC_IP):30000`, the **default init password** is `password`, or you can deploy a ingress to your cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dify-ingress
  namespace: dify
spec:
  ingressClassName: "traefik"
  rules:
    - host: dify.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dify-nginx
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: dify-nginx
                port:
                  number: 80
          - path: /console/api
            pathType: Prefix
            backend:
              service:
                name: dify-nginx
                port:
                  number: 80
          - path: /v1
            pathType: Prefix
            backend:
              service:
                name: dify-nginx
                port:
                  number: 80
          - path: /files
            pathType: Prefix
            backend:
              service:
                name: dify-nginx
                port:
                  number: 80
  tls:
    - secretName: dify-tls
```

If you want to expose dify api, uninstall nginx component and deploy a ingress below, if you use nginx ingress controller, change this yaml file.

```yaml
# Traefik Ingress Route without nginx reverse proxy
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: dify-ingressroute
  namespace: dify
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - kind: Rule
      # console web url
      match: Host(`dify.example.com`) && PathPrefix(`/`)
      middlewares:
        - name: ingress-cors
      services:
        - name: dify-web
          port: 3000
    - kind: Rule
      # app web url
      match: Host(`difyapp.example.com`) && PathPrefix(`/`)
      middlewares:
        - name: ingress-cors
      services:
        - name: dify-web
          port: 3000
    - kind: Rule
      # service api url
      match: Host(`difyapi.example.com`) && PathPrefix(`/`)
      middlewares:
        - name: ingress-cors
      services:
        - name: dify-api
          port: 5001
    - kind: Rule
      # console api url
      match: Host(`consoleapi.example.com`) && PathPrefix(`/`)
      middlewares:
        - name: ingress-cors
      services:
        - name: dify-api
          port: 5001

    - kind: Rule
      # app api url
      match: Host(`appapi.example.com`) && PathPrefix(`/`)
      middlewares:
        - name: ingress-cors
      services:
        - name: dify-api
          port: 5001
  tls:
    secretName: dify-tls
# Traefik Middleware for Ingress
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ingress-cors
  namespace: dify
spec:
  headers:
    accessControlAllowCredentials: true
    accessControlAllowMethods:
      - "GET"
      - "OPTIONS"
      - "PUT"
      - "POST"
      - "DELETE"
      - "PATCH"
    accessControlAllowHeaders:
      # - "*"
      - "Content-Type"
      - "authorization"
      - "x-app-code"
    accessControlAllowOriginList:
      # - "*"
      - "https://consoleapi.example.com"
      - "https://dify.example.com"
      - "https://difyapi.example.com"
      - "https://difyapp.example.com"
      - "https://appapi.example.com"
    accessControlMaxAge: 100
    addVaryHeader: true
```
## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=Winson-030/dify-kubernetes&type=Date)](https://star-history.com/#Winson-030/dify-kubernetes&Date)
