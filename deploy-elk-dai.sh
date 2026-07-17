#!/bin/bash

# 遇到錯誤即停止執行
set -e

echo "===================================================="
echo "          ELK Stack 8.12.2 一鍵部署啟動器            "
echo "===================================================="

# ==========================================
# 防呆模組 1：Docker & Docker Compose 自動偵測與安裝
# ==========================================
check_and_install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "[INFO] 偵測到系統未安裝 Docker，開始自動安裝程序..."
        
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
        else
            echo "[ERROR] 無法識別的作業系統，請手動安裝 Docker 後再試。"
            exit 1
        fi

        echo "[INFO] 當前系統類型: $OS"

        case "$OS" in
            ubuntu|debian)
                echo "[INFO] 正在更新 apt 套件源並安裝依賴..."
                sudo apt-get update -y
                sudo apt-get install -y ca-certificates curl gnupg lsb-release
                
                echo "[INFO] 新增 Docker 官方 GPG 金鑰與 Repository..."
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -y --overwrite -o /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $VERSION_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                
                echo "[INFO] 安裝 Docker Engine 與 Docker Compose 插件..."
                sudo apt-get update -y
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            centos|rhel|almalinux|rocky)
                echo "[INFO] 正在安裝 yum-utils..."
                sudo yum install -y yum-utils
                
                echo "[INFO] 新增 Docker 官方 Repository..."
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                
                echo "[INFO] 安裝 Docker Engine 與 Docker Compose 插件..."
                sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            *)
                echo "[WARN] 暫不支援的自動安裝發行版: $OS。嘗試使用官方通用腳本安裝..."
                curl -fsSL https://get.docker.com | sh
                ;;
        esac

        echo "[INFO] 啟動 Docker 服務並設定開機自啟..."
        sudo systemctl enable --now docker
    else
        echo "[PASS] 偵測到 Docker 已安裝。"
    fi

    if ! sudo systemctl is-active --quiet docker; then
        echo "[INFO] Docker 服務未啟動，正在嘗試啟動..."
        sudo systemctl start docker
    fi

    if ! docker compose version &> /dev/null; then
        echo "[INFO] 偵測到未安裝 Docker Compose 插件，開始安裝..."
        if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
            sudo apt-get update -y && sudo apt-get install -y docker-compose-plugin
        elif [ "$OS" == "centos" ] || [ "$OS" == "rhel" ]; then
            sudo yum install -y docker-compose-plugin
        else
            echo "[INFO] 採用二進位手動下載安裝 Docker Compose..."
            ARCH=$(uname -m)
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$ARCH" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            sudo mkdir -p /usr/local/lib/docker/cli-plugins
            sudo ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
        fi
    else
        echo "[PASS] 偵測到 Docker Compose 已符合要求。"
    fi
}

# ==========================================
# 防呆模組 2：智慧埠口自動探測與避讓
# ==========================================
find_free_port() {
    local port=$1
    local service_name=$2
    local original_port=$port
    
    while true; do
        local in_use=0
        if command -v ss &> /dev/null; then
            if ss -tuln | grep -q -E "\b$port\b"; then in_use=1; fi
        elif command -v netstat &> /dev/null; then
            if netstat -tuln | grep -q -E "\b$port\b"; then in_use=1; fi
        elif command -v lsof &> /dev/null; then
            if lsof -i :$port -t &>/dev/null; then in_use=1; fi
        else
            if (timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$port") 2>/dev/null; then in_use=1; fi
        fi

        # 如果埠口未被佔用，則直接輸出並返回
        if [ $in_use -eq 0 ]; then
            if [ "$port" -ne "$original_port" ]; then
                # 輸出警告訊息至 stderr，避免干預標準輸出 (stdout) 的變數賦值
                echo -e "\033[33m[WARN] 埠口 $original_port 已被佔用！$service_name 自動配置為新埠口: $port\033[0m" >&2
            else
                echo "[PASS] $service_name 埠口檢測通過: $port" >&2
            fi
            echo "$port"
            return 0
        fi
        # 若衝突，則遞增埠口號繼續探測
        port=$((port + 1))
    done
}

# 執行 Docker 與 Compose 環境防呆
check_and_install_docker

# 自動計算無衝突的實體埠口
echo "[INFO] 正在進行智慧埠口衝突探測..."
ES_PORT=$(find_free_port 9200 "Elasticsearch API")
ES_TRANSPORT_PORT=$(find_free_port 9300 "Elasticsearch Transport")
KIBANA_PORT=$(find_free_port 5601 "Kibana Dashboard")
LOGSTASH_BEATS_PORT=$(find_free_port 5044 "Logstash Beats Input")
LOGSTASH_TCP_PORT=$(find_free_port 50000 "Logstash TCP Input")

# ==========================================
# 1. 系統環境檢查與優化
# ==========================================
if [ "$(uname)" == "Linux" ]; then
    CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
    if [ "$CURRENT_MAP_COUNT" -lt 262144 ]; then
        echo "[INFO] 偵測到 Linux 系統，且 vm.max_map_count ($CURRENT_MAP_COUNT) 不足。"
        echo "[INFO] 正在提升核心虛擬記憶體限制至 262144..."
        sudo sysctl -w vm.max_map_count=262144
        echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf > /dev/null
    else
        echo "[PASS] 系統 vm.max_map_count 已符合要求 ($CURRENT_MAP_COUNT)。"
    fi
fi

# 2. 建立必要目錄
echo "[INFO] 建立 ELK 掛載目錄..."
mkdir -p logstash/config
mkdir -p logstash/pipeline

# 3. 寫入 Logstash 系統設定
echo "[INFO] 寫入 Logstash 配置文件..."
cat << 'EOF' > logstash/config/logstash.yml
http.host: "0.0.0.0"
xpack.monitoring.elasticsearch.hosts: [ "http://elasticsearch:9200" ]
EOF

# 4. 寫入 Logstash Pipeline 規則
cat << 'EOF' > logstash/pipeline/logstash.conf
input {
  tcp {
    port => 50000
    codec => json
  }
  beats {
    port => 5044
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "logstash-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }
}
EOF

# 5. 動態寫入 Docker Compose 檔案（使用動態埠口變數）[cite: 1]
echo "[INFO] 生成 docker-compose.yml..."
cat << EOF > docker-compose.yml
version: '3.8'

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.2
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
      - xpack.security.enabled=false
    volumes:
      - es_data:/usr/share/elasticsearch/data
    ports:
      - "${ES_PORT}:9200"
      - "${ES_TRANSPORT_PORT}:9300"
    networks:
      - elk
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -q 'status'"]
      interval: 10s
      timeout: 5s
      retries: 5

  kibana:
    image: docker.elastic.co/kibana/kibana:8.12.2
    container_name: kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - I18N_LOCALE=zh-CN
    ports:
      - "${KIBANA_PORT}:5601"
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - elk

  logstash:
    image: docker.elastic.co/logstash/logstash:8.12.2
    container_name: logstash
    volumes:
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml
      - ./logstash/pipeline/logstash.conf:/usr/share/logstash/pipeline/logstash.conf
    ports:
      - "${LOGSTASH_BEATS_PORT}:5044"
      - "${LOGSTASH_TCP_PORT}:50000/tcp"
      - "${LOGSTASH_TCP_PORT}:50000/udp"
    environment:
      - LS_JAVA_OPTS=-Xms256m -Xmx256m
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - elk

networks:
  elk:
    driver: bridge

volumes:
  es_data:
    driver: local
EOF

# 6. 執行容器部署[cite: 1]
echo "[INFO] 啟動 Docker Compose 容器群組..."
sudo docker compose down >/dev/null 2>&1 || true
sudo docker compose up -d

echo "===================================================="
echo "🎉 ELK 服務已成功在背景啟動！"
echo "----------------------------------------------------"
echo "1. Elasticsearch API : http://localhost:${ES_PORT}"
echo "2. Kibana 儀表板      : http://localhost:${KIBANA_PORT}"
echo "3. Logstash 接收埠    : TCP ${LOGSTASH_TCP_PORT} / Beats ${LOGSTASH_BEATS_PORT}"
echo "===================================================="
echo "[提示] Elasticsearch 啟動需要大約 30-60 秒，請稍候..."
