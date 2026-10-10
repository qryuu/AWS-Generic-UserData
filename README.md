# AWS-Generic-UserData

A collection of AWS EC2 UserData scripts for rapid provisioning.  
Amazon Linux 2023 (AL2023) および Amazon Linux 2 (AL2) に対応した汎用 UserData スクリプト集です。

---

## 主な特徴 (Features)

- **Amazon Linux 2023 (AL2023) ネイティブ対応**: `dnf` パッケージマネージャおよび最新パッケージ（Apache, Nginx, MariaDB 10.5+, PostgreSQL 15+, PHP 8.x, Ruby 3.x, Docker）をサポート。AL2 環境でも自動検出してフォールバック動作します。
- **IMDSv2 (Instance Metadata Service v2) 対応**: セキュアなトークンベースのメタデータ取得により、最新の AWS セキュリティ基準に準拠。
- **マルチデータベース対応 (MariaDB / PostgreSQL)**: 各種 Web アプリケーションで MariaDB と PostgreSQL を自由に選択可能（ローカル起動および Amazon RDS 接続に対応）。
- **高速・安全なプロビジョニング**: `set -euo pipefail` によるエラーハンドリング、サービス即時起動（`systemctl enable --now`）、再起動待ちのないスムーズな起動完了。

---

## 提供スクリプト一覧 (Available Scripts)

| スクリプト名 | 用途 | 主要スタック |
|:---|:---|:---|
| [`docker-Initial_construction.sh`](#1-docker-initial_constructionsh) | コンテナホスト基盤 | Docker Engine, Docker Compose v2, ec2-user 権限 |
| [`lamp-Initial_construction.sh`](#2-lamp-initial_constructionsh) | LAMP 汎用基盤 | Apache, PHP 8.x, MariaDB |
| [`lemp-Initial_construction.sh`](#3-lemp-initial_constructionsh) | LEMP 高速 Web 基盤 | Nginx, PHP-FPM 8.x, MariaDB |
| [`postgresql-Initial_construction.sh`](#4-postgresql-initial_constructionsh) | DB サーバー基盤 | PostgreSQL 15+, 認証設定 |
| [`lamp-Initial_construction_wordpress.sh`](#5-lamp-initial_construction_wordpresssh) | ブログ / CMS | WordPress, WP-CLI, Apache, PHP, MariaDB |
| [`lamp-Initial_construction_moodle.sh`](#6-lamp-initial_construction_moodlesh) | 学習管理システム (LMS) | Moodle, Apache, PHP 8.x, **MariaDB または PostgreSQL** |
| [`lamp-Initial_construction_nextcloud.sh`](#7-lamp-initial_construction_nextcloudsh) | オンラインストレージ | Nextcloud, Apache, PHP OPcache, **MariaDB または PostgreSQL** |
| [`initial_construction_redmine.sh`](#8-initial_construction_redminesh) | プロジェクト管理 | Redmine, Ruby, Puma (systemd), Apache, **MariaDB または PostgreSQL** |

---

## 各スクリプトの仕様と引数

### 1. `docker-Initial_construction.sh`
EC2 を Docker および Docker Compose が即座に使えるコンテナホストとしてセットアップします。`ec2-user` に権限が付与されているため、ログイン直後から `sudo` なしで `docker run` や `docker compose` コマンドを実行できます。

```bash
./docker-Initial_construction.sh
```
- 引数なし

---

### 2. `lamp-Initial_construction.sh`
Apache、PHP、MariaDB をインストールし、指定された初期データベース・ユーザーを作成します。

```bash
./lamp-Initial_construction.sh [DB名] [DBユーザー名] [DBパスワード]
```
- `$1`: DB名 (デフォルト: `lampdb`)
- `$2`: DBユーザー名 (デフォルト: `lampuser`)
- `$3`: DBパスワード (デフォルト: `lamppass`)

---

### 3. `lemp-Initial_construction.sh`
Nginx、PHP-FPM、MariaDB をインストールし、高速な LEMP 環境を構築します。

```bash
./lemp-Initial_construction.sh [DB名] [DBユーザー名] [DBパスワード]
```
- `$1`: DB名 (デフォルト: `lempdb`)
- `$2`: DBユーザー名 (デフォルト: `lempuser`)
- `$3`: DBパスワード (デフォルト: `lemppass`)

---

### 4. `postgresql-Initial_construction.sh`
PostgreSQL 15+ 単体データベースサーバーを初期化し、初期データベース、ユーザー、パスワード、接続認証（`pg_hba.conf`）を設定します。

```bash
./postgresql-Initial_construction.sh [DB名] [DBユーザー名] [DBパスワード]
```
- `$1`: DB名 (デフォルト: `mydb`)
- `$2`: DBユーザー名 (デフォルト: `myuser`)
- `$3`: DBパスワード (デフォルト: `mypassword`)

---

### 5. `lamp-Initial_construction_wordpress.sh`
WordPress の最新日本語版（WP-CLI 経由）を自動セットアップします。

```bash
./lamp-Initial_construction_wordpress.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB種別 (`local` または `rds`, デフォルト: `local`)
- `$2`: DB名 (デフォルト: `wpdb`)
- `$3`: DBユーザー名 兼 管理者 ID (デフォルト: `wpuser`)
- `$4`: パスワード (デフォルト: `wppass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 6. `lamp-Initial_construction_moodle.sh`
Moodle LMS を自動セットアップします。**MariaDB と PostgreSQL の両方に対応**しています。

```bash
./lamp-Initial_construction_moodle.sh [DB指定] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB指定
  - `local` または `mariadb` (デフォルト: ローカル MariaDB)
  - `postgres` (ローカル PostgreSQL)
  - `rds` または `rds-mariadb` (Amazon RDS MariaDB/MySQL)
  - `rds-postgres` (Amazon RDS PostgreSQL)
- `$2`: DB名 (デフォルト: `moodledb`)
- `$3`: DBユーザー名 兼 Moodle 管理者 ID (デフォルト: `moodleuser`)
- `$4`: パスワード (デフォルト: `moodlepass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 7. `lamp-Initial_construction_nextcloud.sh`
Nextcloud オンラインストレージを自動セットアップします。**MariaDB と PostgreSQL の両方に対応**しています。

```bash
./lamp-Initial_construction_nextcloud.sh [DB指定] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB指定
  - `local` または `mariadb` (デフォルト: ローカル MariaDB)
  - `postgres` (ローカル PostgreSQL)
  - `rds` または `rds-mariadb` (Amazon RDS MariaDB/MySQL)
  - `rds-postgres` (Amazon RDS PostgreSQL)
- `$2`: DB名 (デフォルト: `nextclouddb`)
- `$3`: DBユーザー名 兼 管理者 ID (デフォルト: `ncadmin`)
- `$4`: パスワード (デフォルト: `ncpass123`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 8. `initial_construction_redmine.sh`
Redmine プロジェクト管理ツールを自動セットアップします。**MariaDB と PostgreSQL の両方に対応**しています。

```bash
./initial_construction_redmine.sh [DB指定] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB指定
  - `local` または `mariadb` (デフォルト: ローカル MariaDB)
  - `postgres` (ローカル PostgreSQL)
  - `rds` または `rds-mariadb` (Amazon RDS MariaDB/MySQL)
  - `rds-postgres` (Amazon RDS PostgreSQL)
- `$2`: DB名 (デフォルト: `redminedb`)
- `$3`: DBユーザー名 (デフォルト: `redmineuser`)
- `$4`: パスワード (デフォルト: `redminepass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）
- **初期管理者アカウント**: `admin` / `admin` (初回ログイン時に変更)

---

## EC2 UserData での利用例 (Usage Examples)

EC2 インスタンス作成時の「高度な詳細」>「ユーザーデータ (UserData)」に貼り付けて使用します。

### Docker & Docker Compose ホストの構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/docker-Initial_construction.sh | bash
```

### LEMP スタック (Nginx + PHP + MariaDB) の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lemp-Initial_construction.sh | bash -s myappdb myappuser MyStrongPass123!
```

### PostgreSQL データベースサーバーの構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/postgresql-Initial_construction.sh | bash -s mydb myuser MySecurePass123!
```

### Moodle LMS (PostgreSQL 構成) の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_moodle.sh | bash -s postgres moodledb moodleadmin MyMoodlePass123!
```

### Nextcloud (PostgreSQL 構成) の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_nextcloud.sh | bash -s postgres nextclouddb ncadmin MyCloudPass123!
```

### Redmine (PostgreSQL 構成) の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/initial_construction_redmine.sh | bash -s postgres redminedb redmineuser MyRedminePass123!
```

### WordPress (デフォルト MariaDB 構成) の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_wordpress.sh | bash
```

---

## 認証情報とセキュリティ (Security Notes)

- ローカル MariaDB の `root` パスワードはランダム生成され、`/home/ec2-user/.mysql.secrets` に保存されます（パーミッション `600`）。
- ローカル PostgreSQL の接続情報は `/home/ec2-user/.pgpass` に保存されます（パーミッション `600`）。
- 本番環境で運用する場合は、必ずデフォルトパスワードから十分な強度のパスワードへ変更してご利用ください。

---

## ライセンス (License)

[MIT License](file:///c:/Users/housi/OneDrive/ドキュメント/vscode/AWS-Generic-UserData/LICENSE)
