# Useful scripts

四套可獨立使用的工具：管理使用者層級的 Docker Compose、Debian 指令、Python 環境，以及將 Python 工作送到 Modal。前三支 shell 腳本不需要 `sudo`。

| 工具 | 用途 |
| --- | --- |
| `docker-user-tool.sh` | 檢查 Docker、安裝目前使用者的 Compose plugin、驗證 Compose 設定 |
| `user-apt-tool.sh` | 查詢或在使用者目錄解開簡單的 Debian 套件 |
| `uv-env-tool.sh` | 安裝 uv，建立獨立 Python 環境並管理套件 |
| `modal_runner/` | 指定 GPU 和相依套件執行 Python，下載日誌與成果 |

## Docker Compose：`docker-user-tool.sh`

適用已有 Docker CLI 的 Linux 環境。`install-compose` 從 Docker 官方 GitHub release 下載 Compose，驗證 SHA-256 後安裝到 `~/.docker/cli-plugins/`。它不會安裝 Docker Engine 或修改 daemon。

```bash
bash docker-user-tool.sh doctor
bash docker-user-tool.sh ports 15174
bash docker-user-tool.sh install-compose
bash docker-user-tool.sh verify-compose
bash docker-user-tool.sh validate "$HOME/my-project"
bash docker-user-tool.sh status "$HOME/my-project"
```

`ports` 不給埠號時會列出容器埠與主機 TCP listener。`validate`、`status` 預設讀取專案中的 `infra/compose.yaml` 及 `infra/.env`，也能在專案目錄參數後指定檔名。`validate` 只檢查設定，不啟動容器。可用 `COMPOSE_PLUGIN_DIR`、`COMPOSE_PLUGIN_PATH` 和 `DEFAULT_COMPOSE_VERSION` 覆寫預設值。

## Debian 工具：`user-apt-tool.sh`

適用 Debian 或 Ubuntu。它尋找快取中的 `.deb`，必要時用 `apt-get download` 下載，解開到 `~/.local/apt-user/`，並在 `~/.local/bin/` 建立指令連結。不修改系統套件資料庫，也不會自動解決所有相依套件。

```bash
bash user-apt-tool.sh check tree
bash user-apt-tool.sh cached tree
bash user-apt-tool.sh installed tree
bash user-apt-tool.sh install tree
bash user-apt-tool.sh setup-path
```

當套件名和指令名不同，使用 `bash user-apt-tool.sh install PACKAGE COMMAND`。`cached` 只代表找到了 `.deb`，不代表已安裝。這支工具適合 `tree` 等相依性簡單的命令列程式。可用 `USER_APT_ROOT` 和 `USER_BIN_DIR` 更改路徑。

## Python 環境：`uv-env-tool.sh`

用 uv 建立專案自己的 `.venv`，安裝套件並在環境中執行指令，不更改系統 Python。

```bash
bash uv-env-tool.sh bootstrap
bash uv-env-tool.sh setup-path
bash uv-env-tool.sh doctor
bash uv-env-tool.sh create "$HOME/work/my-project" 3.12
bash uv-env-tool.sh install-file "$HOME/work/my-project" requirements.txt
bash uv-env-tool.sh install "$HOME/work/my-project" pandas numpy
bash uv-env-tool.sh run "$HOME/work/my-project" python script.py --help
bash uv-env-tool.sh info "$HOME/work/my-project"
```

其他指令包括 `uninstall`、`torch DIRECTORY [BACKEND] [PACKAGE ...]`、`list`、`freeze`、`activate`、`tool-install`、`tool-list`。`activate` 會印出要在目前 shell 執行的 `source` 指令。可用 `UV_BIN_DIR`、`UV_BIN` 和 `UV_ENV_NAME` 更改預設值。

## Modal Python 工作：`modal_runner/`

一份 JSON 設定遠端命令、GPU、CPU、記憶體、參數及套件。比賽程式可以維持一般 Python 腳本；執行工具提供 shell 入口並以 Modal SDK 送出工作。每個模型或實驗各跑一次，日誌、GPU 採樣與成果便能對應到該次工作。

```bash
bash modal_runner/modal-run.sh --login
bash modal_runner/modal-run.sh modal_runner/example/modal-job.json --dry-run
bash modal_runner/modal-run.sh modal_runner/example/modal-job.json
```

在你的專案中建立 `modal-job.json`，例如：

```json
{
  "app_name": "my-python-jobs",
  "model_name": "example-model",
  "project_dir": ".",
  "command": ["python", "-u", "train.py", "--output", "{output_dir}/predictions.json"],
  "gpu": "L4",
  "cpu": 2,
  "memory_mib": 8192,
  "timeout_seconds": 3600,
  "result_dir": "runs",
  "image": {
    "python": "3.11",
    "requirements": "requirements.txt",
    "apt_packages": [],
    "pip_packages": []
  },
  "secrets": [],
  "volumes": {},
  "billing_snapshot": true,
  "billing": {"gpu_usd_per_hour": null}
}
```

`modal-run.sh` 會直接呼叫 `uv-env-tool.sh` 準備本機環境。可選 `--docker-doctor` 或 `--compose-project DIR`，讓它呼叫 `docker-user-tool.sh` 檢查 Docker 或驗證 Compose。這些檢查不影響 Modal 遠端建置 Dockerfile，也不要求本機 Docker daemon。可用 `image.dockerfile` 指向專案內的 Dockerfile，或用 `--gpu H100` 覆寫 GPU。腳本也能從 `MODAL_RUN_OUTPUT_DIR` 取得輸出目錄。結果會保存在 `runs/<run-id>/`，包括 `console.log`、`summary.json`、下載的 `job.json`、`gpu_samples.jsonl` 及腳本產生的檔案。大資料和權重適合放在 Modal Volume；憑證請用 Modal Secret。完整設定見 [Modal 工具說明](modal_runner/README.md)。

GPU 採樣記錄裝置名稱、使用率及顯示記憶體，但可能錯過短暫尖峰。自行填入每張 GPU 的時薪後可得到 GPU 部分的粗估上界，並不包含 CPU、記憶體及其他費用。帳務快照涵蓋整個 workspace，還可能延遲；工具因此不會將其當作這次工作的精確 credits 扣除額。詳見 [Modal 帳務說明](https://modal.com/docs/guide/billing)。

本機測試不會啟動遠端 GPU：

```bash
python -m unittest discover -s modal_runner -p 'test_*.py' -v
python -m py_compile modal_runner/*.py
```
