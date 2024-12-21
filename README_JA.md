# dify-kubernetes

[Dify](https://dify.ai/)  を Kubernetes にデプロイする

> サポートが必要な場合は、気軽に問題を提起するか、メールしてください 😊

[メール](mailto:a623719265@gmail.com)

> このリポジトリが役に立った場合は、スター 🌟 を付けてください~~

## 開発計画

> hostPath の代わりに PVC をストレージとして使用する必要がある場合は、`feature/pvc-volume` ブランチをチェックアウトしてください

### ssrf プロキシコンポーネントの追加

ssrf プロキシコンポーネントを `dify-deployment.yaml` と `dify-mirror-deployment.yaml` に統合しました。ファイルは `dify/middleware` にあります。

### その他のベクターデータベース

**PR 歓迎！**
これに関する開発計画があり、2024年10月に開始します。

ファイルは `dify/database` にあります。

HA データベースセットアップ用の新しいブランチ `feature/dify-database-HA-setup` を作成し、フォルダー `dify` の下に `database-ha` フォルダーを作成しました。HA データベースに貢献したい場合は、自由にファイルを追加してください！

## 使用方法

### リポジトリをクローンする

```shell

git clone https://github.com/Winson-030/dify-kubernetes.git

kubectl apply -f dify-deployment.yaml

```

### 直接適用する

```shell

kubectl apply -f https://raw.githubusercontent.com/Winson-030/dify-kubernetes/main/dify-deployment.yaml

```

クラスターが dockerhub に直接接続できない場合（中国のほとんどのユーザー向け）、以下のミラー レジストリ プリセットを使用してデプロイを適用します。

```shell

kubectl apply -f https://cdn.jsdelivr.net/gh/Winson-030/dify-kubernetes@main/dify-mirror-deployment.yaml

```

デプロイ後、`http://$(PUBLIC_IP):30000` の nodeport 経由で dify ウェブサイトにアクセスできます。デフォルトの初期パスワードは `password` です。または、クラスターにイングレスをデプロイすることもできます。

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

dify API を公開したい場合は、nginx コンポーネントをアンインストールし、以下のイングレスをデプロイしてください。nginx イングレスコントローラーを使用する場合は、この YAML ファイルを変更してください。

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
