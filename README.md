# AWS-Generic-UserData

A collection of AWS EC2 UserData scripts for rapid provisioning.  
Amazon Linux 2023 (AL2023) および Amazon Linux 2 (AL2) に対応した汎用 UserData スクリプト集です。

---

## 主な特徴 (Features)

- **Amazon Linux 2023 (AL2023) ネイティブ対応**: `dnf` パッケージマネージャおよび最新パッケージ（Apache, MariaDB 10.5+, PHP 8.x）をサポート。AL2 環境でも自動検出してフォールバック動作します。
- **IMDSv2 (Instance Metadata Service v2) 対応**: セキュアなトークンベースのメタデータ取得により、最新の AWS セキュリティ基準に準拠。
- **堅牢なデータベース設定**: `utf8mb4` (Unicode 絵文字対応) を標準採用、安全なランダムパスワード生成とクレデンシャルファイルパーミッション制限（`600`）。
- **高速・安全なプロビジョニング**: `set -euo pipefail` によるエラーハンドリング、サービス即時起動（`systemctl enable --now`）、再起動待ちのないスムーズな起動完了。

---

## スクリプト一覧 (Scripts)

### 1. `lamp-Initial_construction.sh`
Apache、PHP、MariaDB をインストールし、指定された初期データベース・ユーザーを作成します。

#### 引数 (Arguments)
```bash
./lamp-Initial_construction.sh [DB名] [DBユーザー名] [DBパスワード]
```
- 第1引数: DB名 (デフォルト: `lampdb`)
- 第2引数: DBユーザー名 (デフォルト: `lampuser`)
- 第3引数: DBパスワード (デフォルト: `lamppass`)

---

### 2. `lamp-Initial_construction_wordpress.sh`
WordPress の最新日本語版（WP-CLI 経由）を自動ダウンロード・設定・インストールします。ローカル MariaDB 構成および RDS 構成の両方に対応しています。

#### 引数 (Arguments)
```bash
./lamp-Initial_construction_wordpress.sh [DB種別] [DB名] [ユーザー名] [パスワード] [RDSエンドポイント] [RDSマスターユーザー] [RDSマスターパスワード]
```

| 引数番号 | 項目 | デフォルト値 | 補足 |
|:---|:---|:---|:---|
| `$1` | DB種別 | `local` | `local` または `rds` (大文字小文字不問) |
| `$2` | DB名 | `wpdb` | 作成する WordPress 用 DB 名 |
| `$3` | ユーザー名 | `wpuser` | DB ユーザー名 兼 WordPress 管理者 ID |
| `$4` | パスワード | `wppass` | DB パスワード 兼 WordPress 管理者パスワード |
| `$5` | RDS エンドポイント | なし | RDS モード時のみ必須（例: `mydb.xxxx.ap-northeast-1.rds.amazonaws.com:3306`） |
| `$6` | RDS マスターユーザー | なし | RDS モード時のみ必須 |
| `$7` | RDS マスターパスワード | なし | RDS モード時のみ必須 |

---

## EC2 UserData での利用例 (Usage Examples)

EC2 インスタンス作成時の「高度な詳細」>「ユーザーデータ (UserData)」に貼り付けて使用します。

### パターン A: ローカル DB (デフォルト設定) で WordPress を構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_wordpress.sh | bash
```

### パターン B: ローカル DB (カスタムパラメータ) で WordPress を構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_wordpress.sh | bash -s local mywpdb mywpuser MyStrongPassword123!
```

### パターン C: Amazon RDS 接続で WordPress を構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction_wordpress.sh | bash -s rds mywpdb mywpuser MyStrongPassword123! mydb.xxxx.ap-northeast-1.rds.amazonaws.com:3306 admin MasterPass123!
```

### パターン D: シンプルな LAMP サーバーの構築
```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/qryuu/AWS-Generic-UserData/master/lamp-Initial_construction.sh | bash -s myappdb myappuser MySecretPassword!
```

---

## 管理画面へのアクセス (Accessing WordPress)

スクリプト実行完了後、ブラウザから EC2 のパブリック IP アドレスへアクセスします。

- **WordPress トップページ**: `http://<EC2-Public-IP>/`
- **WordPress 管理画面**: `http://<EC2-Public-IP>/wp-admin`
  - **ログイン ID**: `<ユーザー名>` (デフォルト: `wpuser`)
  - **パスワード**: `<パスワード>` (デフォルト: `wppass`)

---

## 認証情報とセキュリティ (Security Notes)

- ローカル MariaDB の `root` パスワードはランダム生成され、`/home/ec2-user/.mysql.secrets` に保存されます（パーミッション `600`）。
- `ec2-user` ユーザーは `/home/ec2-user/.my.cnf` を利用して `mysql` コマンドでパスワードなしログインが可能です。
- 本番環境で運用する場合は、必ずデフォルトパスワードから十分な強度のパスワードへ変更してご利用ください。

---

## ライセンス (License)

[MIT License](file:///c:/Users/housi/OneDrive/ドキュメント/vscode/AWS-Generic-UserData/LICENSE)
