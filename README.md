# AWS-Generic-UserData

A collection of AWS EC2 UserData scripts for rapid provisioning.  
Amazon Linux 2023 (AL2023) および Amazon Linux 2 (AL2) に対応した汎用 UserData スクリプト集です。

---

## 主な特徴 (Features)

- **Amazon Linux 2023 (AL2023) ネイティブ対応**: `dnf` パッケージマネージャおよび最新パッケージ（Apache, MariaDB 10.5+, PHP 8.x, Ruby 3.x）をサポート。AL2 環境でも自動検出してフォールバック動作します。
- **IMDSv2 (Instance Metadata Service v2) 対応**: セキュアなトークンベースのメタデータ取得により、最新の AWS セキュリティ基準に準拠。
- **堅牢なデータベース設定**: `utf8mb4` (Unicode 絵文字対応) を標準採用、安全なランダムパスワード生成とクレデンシャルファイルパーミッション制限（`600`）。
- **高速・安全なプロビジョニング**: `set -euo pipefail` によるエラーハンドリング、サービス即時起動（`systemctl enable --now`）、再起動待ちのないスムーズな起動完了。

---

## 提供スクリプト一覧 (Available Scripts)

| スクリプト名 | 用途 | 主要スタック |
|:---|:---|:---|
| [`lamp-Initial_construction.sh`](#1-lamp-initial_constructionsh) | LAMP 汎用基盤 | Apache, PHP 8.x, MariaDB |
| [`lamp-Initial_construction_wordpress.sh`](#2-lamp-initial_construction_wordpresssh) | ブログ / CMS | WordPress, WP-CLI, Apache, PHP, MariaDB |
| [`lamp-Initial_construction_moodle.sh`](#3-lamp-initial_construction_moodlesh) | 学習管理システム (LMS) | Moodle, Apache, PHP 8.x, MariaDB, Cron |
| [`lamp-Initial_construction_nextcloud.sh`](#4-lamp-initial_construction_nextcloudsh) | オンラインストレージ | Nextcloud, Apache, PHP OPcache, MariaDB |
| [`initial_construction_redmine.sh`](#5-initial_construction_redminesh) | プロジェクト管理 | Redmine, Ruby, Puma (systemd), Apache, MariaDB |

---

## 各スクリプトの仕様と引数

### 1. `lamp-Initial_construction.sh`
Apache、PHP、MariaDB をインストールし、指定された初期データベース・ユーザーを作成します。

```bash
./lamp-Initial_construction.sh [DB名] [DBユーザー名] [DBパスワード]
```
- `$1`: DB名 (デフォルト: `lampdb`)
- `$2`: DBユーザー名 (デフォルト: `lampuser`)
- `$3`: DBパスワード (デフォルト: `lamppass`)

---

### 2. `lamp-Initial_construction_wordpress.sh`
WordPress の最新日本語版（WP-CLI 経由）を自動ダウンロード・設定・インストールします。ローカル MariaDB および RDS 構成の両方に対応しています。

```bash
./lamp-Initial_construction_wordpress.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB種別 (`local` または `rds`, デフォルト: `local`)
- `$2`: DB名 (デフォルト: `wpdb`)
- `$3`: DBユーザー名 兼 WordPress 管理者 ID (デフォルト: `wpuser`)
- `$4`: DBパスワード 兼 WordPress 管理者パスワード (デフォルト: `wppass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 3. `lamp-Initial_construction_moodle.sh`
Moodle LMS の最新安定版を自動セットアップし、Moodle 用 PHP 設定、MariaDB 初期化、初期 CLI インストール、定期実行 cron を登録します。

```bash
./lamp-Initial_construction_moodle.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB種別 (`local` または `rds`, デフォルト: `local`)
- `$2`: DB名 (デフォルト: `moodledb`)
- `$3`: DBユーザー名 兼 Moodle 管理者 ID (デフォルト: `moodleuser`)
- `$4`: DBパスワード 兼 Moodle 管理者パスワード (デフォルト: `moodlepass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 4. `lamp-Initial_construction_nextcloud.sh`
Nextcloud オンラインストレージの最新安定版を自動展開し、最適化された OPcache 設定、`occ` CLI による無人インストール、`trusted_domains` の自動登録、バックグラウンド cron を設定します。

```bash
./lamp-Initial_construction_nextcloud.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB種別 (`local` または `rds`, デフォルト: `local`)
- `$2`: DB名 (デフォルト: `nextclouddb`)
- `$3`: DBユーザー名 兼 Nextcloud 管理者 ID (デフォルト: `ncadmin`)
- `$4`: DBパスワード 兼 Nextcloud 管理者パスワード (デフォルト: `ncpass123`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）

---

### 5. `initial_construction_redmine.sh`
Redmine プロジェクト管理ツールを自動構築します。Ruby 環境、Bundler による依存関係導入、MariaDB への DB マイグレーションと初期データ投入、Puma アプリケーションサーバー（systemd 常駐サービス）および Apache リバースプロキシを設定します。

```bash
./initial_construction_redmine.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```
- `$1`: DB種別 (`local` または `rds`, デフォルト: `local`)
- `$2`: DB名 (デフォルト: `redminedb`)
- `$3`: DBユーザー名 (デフォルト: `redmineuser`)
- `$4`: DBパスワード (デフォルト: `redminepass`)
- `$5`〜`$7`: RDS エンドポイント, マスターユーザー, パスワード（RDS 時のみ必須）
- **初期管理者アカウント**: `admin` / `admin` (初回ログイン後に変更を求められます)

---

## EC2 UserData での利用例 (Usage Examples)

EC2 インスタンス作成時の「高度な詳細」>「ユーザーデータ (UserData)」に貼り付けて使用します。

### WordPress の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_wordpress.sh | bash
```

### Moodle LMS の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_moodle.sh | bash -s local moodledb moodleadmin MyMoodlePass123!
```

### Nextcloud の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_nextcloud.sh | bash -s local nextclouddb ncadmin MyCloudPass123!
```

### Redmine の構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/initial_construction_redmine.sh | bash
```

### シンプルな LAMP サーバーの構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction.sh | bash -s myappdb myappuser MySecretPassword!
```

---

## 認証情報とセキュリティ (Security Notes)

- ローカル MariaDB の `root` パスワードはランダム生成され、`/home/ec2-user/.mysql.secrets` に保存されます（パーミッション `600`）。
- `ec2-user` ユーザーは `/home/ec2-user/.my.cnf` を利用して `mysql` コマンドでパスワードなしログインが可能です。
- 本番環境で運用する場合は、必ずデフォルトパスワードから十分な強度のパスワードへ変更してご利用ください。

---

## ライセンス (License)

[MIT License](file:///c:/Users/housi/OneDrive/ドキュメント/vscode/AWS-Generic-UserData/LICENSE)
