## 部署指南
1. 克隆仓库到本地：

```bash
git clone https://github.com/Ro34/ai_ocr_read_nan
```

2. 安装 uv 工具
可以参考：[https://docs.astral.sh/uv/getting-started/installation/](https://docs.astral.sh/uv/getting-started/installation/)

3. 进入后端目录并安装依赖：

```bash
cd ocr_ai_backend
uv sync
```
4. 配置环境变量
复制 `.env.example` 为 `.env` 并根据需要修改配置：

```bash
cp .env.example .env
```
5. 运行后端服务：

```bash
uv run main.py
```

6.获取本机 IP 地址填入 App 中
使用 `ifconfig` (macOS/Linux) 或 `ipconfig` (Windows) 获取本机 IP 地址
在 app 中填入这个后端地址+8000 端口
例如 http://192.168.1.100:8000