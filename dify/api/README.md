## 💾 永続化データの保存先をS3に変更する場合の設定

Difyでアップロードされたファイルの保存先をローカル（`/app/api/storage`）からAWS S3に変更する場合は、以下の環境変数を`api.yaml`と`worker.yaml`に追加して設定を有効化してください。
この設定により、アップロードされたPDFやCSVなどのファイルがS3バケットに保存され、容量や永続性の制限を気にせず運用できます。
ref: https://docs.dify.ai/getting-started/install-self-hosted/environments


## 💾 Configuration for Using S3 as Persistent Storage

To store uploaded files (such as PDFs and CSVs) in AWS S3 instead of the local path (`/app/api/storage`), enable the following environment variables.
This setup allows for scalable and durable file storage without worrying about local disk limitations.
ref: https://docs.dify.ai/getting-started/install-self-hosted/environments


## 💾 使用 S3 作为持久化存储的配置（中文）

若需将上传文件（如 PDF、CSV 等）从本地路径（`/app/api/storage`）迁移到 AWS S3 进行存储，请在 Kubernetes 部署文件（如 `api.yaml`, `worker.yaml`）的 `env:` 部分添加以下环境变量。
通过此配置，您可以将上传文件保存到 S3，实现可扩展和高持久性的文件存储，无需担心本地磁盘容量限制或数据丢失。
如需了解更多环境变量说明，
ref: https://docs.dify.ai/getting-started/install-self-hosted/environments

```
env:
  - name: STORAGE_TYPE
    value: 's3'
  - name: S3_BUCKET_NAME
    value: '<your-bucket-name>'
  - name: S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: dify-credentials
        key: s3-access-key
  - name: S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: dify-credentials
        key: s3-secret-key
  - name: S3_REGION
    value: '<region>'
  - name: S3_ENDPOINT
    value: https://s3.<region>.amazonaws.com
```
