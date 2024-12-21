# dify-kubernetes

在 Kubernetes 部署 [Dify](https://dify.ai/) 

> 有需要可以起 issue 或者给我发邮件 😊

[Email](mailto:a623719265@gmail.com)

> 这个项目帮到你的话，点个星星 🌟 ~~

## 开发计划

> 如果你需要 PVC 作为存储，请切换到 `feature/pvc-volume` 分支

### 增加 ssrf 代理组件

ssrf 代理组件已经整合到 `dify-deployment.yaml` 和 `dify-mirror-deployment.yaml` 中。你可以在 `dify/middleware` 中找到该组件的文件。

### 支持其他向量数据库

**欢迎提交 PR！**

最近太忙，暂时没时间支持其他数据库。非常欢迎贡献代码。已经支持的数据库文件可以在 `dify/database` 中找到。

我创建了一个分支用于高可用数据库的配置，分支名为 `feature/dify-database-HA-setup`，在 `dify` 文件夹下创建了一个 `database-ha` 文件夹。欢迎提交 PR！

## 如何使用

### 克隆仓库

```shell

git clone https://github.com/Winson-030/dify-kubernetes.git

kubectl apply -f dify-deployment.yaml

```

### 一句命令直接部署

```shell

kubectl apply -f https://raw.githubusercontent.com/Winson-030/dify-kubernetes/main/dify-deployment.yaml

```

如果集群无法直接连接 dockerhub（中国的大多数用户），可以使用下面的镜像源。

```shell

kubectl apply -f https://cdn.jsdelivr.net/gh/Winson-030/dify-kubernetes@main/dify-mirror-deployment.yaml

```

部署完成后，你可以通过 `http://$(PUBLIC_IP):30000` 访问 dify web 站点，**默认初始化密码** 为 `password`，也可以部署 ingress 进行访问。

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

假如想暴露 dify 的 api，卸载 nginx 组件并部署以下 ingress, 如果使用 nginx ingress controller, 修改此yaml文件。

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
