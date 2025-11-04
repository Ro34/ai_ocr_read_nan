# AI OCR Read

Flutter 前端 + Python FastAPI 后端（见 `ocr_ai_backend/`）。

前端支持拍照、调用后端 OCR/VLM 分析，并通过 Wi‑Fi NAN 实验功能在附近设备间广播分析结果。

## 运行后端（开发）

```bash
cd ocr_ai_backend
uv sync
# 推荐：监听 0.0.0.0，便于真机访问
uv run ocr-ai-backend
# 或
uv run uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

本机浏览器可开 http://127.0.0.1:8000/docs；真机请访问你的电脑 IP，比如 http://192.168.0.90:8000/docs。

提示：
- Android 模拟器访问宿主机请用 `http://10.0.2.2:8000`
- iOS 模拟器/桌面可用 `http://127.0.0.1:8000`
- 真机：使用你的电脑局域网 IP，例如 `http://192.168.0.90:8000`
- 初次调用会懒加载模型，稍慢；若 `torch/torchvision` 安装失败，请参照 https://pytorch.org/ 单独安装与你平台匹配的轮子

## 运行前端

```bash
flutter pub get
flutter run
```

在首页中：
- 设置“后端地址”（默认已按平台填好）
- “拍照”后点击 “OCR 识别” 或 “VLM 分析” 即可调用后端

可选：配置并启动“附近直连（NAN 实验）”，可在设备间广播分析结果。

