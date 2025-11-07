# AI OCR Backend

FastAPI 服务，提供：

- POST `/ocr`：使用 EasyOCR 对图片进行文字识别
- POST `/vlm`：调用“在线 VLM API”生成图片描述（可通过 `.env` 配置）

返回示例：

```json
// /ocr
{
	"text": "示例票据，金额￥128.00，日期2025-10-31",
	"confidences": [0.98, 0.93, 0.86],
	"avg_confidence": 0.9233,
	"languages": ["ch_sim", "en"],
	"duration_ms": 512
}
```

```json
// /vlm
{
	"description": "a receipt showing total 128 yuan and date 2025-10-31",
	"duration_ms": 842
}
```

## 本地运行（建议）

使用 uv（已在仓库根目录执行过 `uv init ocr_ai_backend`）：

```bash
cd ocr_ai_backend
uv sync
# 方式一：通过脚本（监听 0.0.0.0，便于真机访问）
uv run ocr-ai-backend
# 或 方式二：直接 uvicorn（同样指定 --host 0.0.0.0）
uv run uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

然后打开 http://127.0.0.1:8000/docs 查看接口文档（真机请访问你的主机 IP，如 http://192.168.0.90:8000/docs）。

提示：`/ocr` 使用 EasyOCR（需要 `torch/torchvision`）；`/vlm` 现已改为调用在线 API，无需本地下载大模型。

## 接口参数

- `POST /ocr`
	- form-data: `file`（必填，图片）
	- form-data: `languages`（可选，默认 `ch_sim,en`）

- `POST /vlm`
	- form-data: `file`（必填，图片）

## 配置在线 VLM（.env）

复制示例文件并填写你的线上接口信息：

```bash
cd ocr_ai_backend
cp .env.example .env
```

`.env` 关键项：

- `VLM_API_URL`（必填）：你的在线 VLM 接口地址
- `VLM_API_KEY`（可选）：API Key
- `VLM_API_AUTH_HEADER`（默认 `Authorization`）：鉴权使用的请求头名
- `VLM_API_KEY_PREFIX`（默认 `Bearer `）：鉴权前缀
- `VLM_API_MODE`（默认 `multipart`）：`multipart` 或 `base64`
- `VLM_API_IMAGE_FIELD`（默认 `file`）：图片字段名
- `VLM_API_DESC_KEY`（默认 `description`）：响应 JSON 中描述字段名
- `VLM_API_MODEL`（可选）：指定上游模型名
- `VLM_API_TIMEOUT`（默认 `30`）：请求超时秒数
- `VLM_API_EXTRA_FIELDS`（可选）：以逗号分隔的 `key=value`，会一并提交给上游

- `VLM_API_TEMPERATURE`（可选，默认 0.7）：Chat-completions 采样温度
- `VLM_API_TOP_P`（可选，默认 0.7）：Chat-completions top_p 截断采样

### SiliconFlow（Chat Completions）快速配置

SiliconFlow 提供 OpenAI 兼容的 `/v1/chat/completions` 接口，支持图文混合输入。后端已内置适配：

1) `.env` 示例：

```env
VLM_API_URL=https://api.siliconflow.cn/v1/chat/completions
VLM_API_KEY=sk-xxxx
VLM_API_CHAT=1
VLM_API_MODEL=Qwen/Qwen3-VL-30B-A3B-Instruct
VLM_API_PROMPT=用中文简洁描述这张图片的内容
VLM_API_MAX_TOKENS=256
```

2) 工作方式：当 `VLM_API_CHAT=1`（或 URL 含 `/chat/completions`）时，后端会发送如下 JSON 结构给上游（示意）：

```jsonc
{
	"model": "Qwen/Qwen3-VL-30B-A3B-Instruct",
	"messages": [
		{
			"role": "user",
			"content": [
				{"type": "text", "text": "用中文简洁描述这张图片的内容"},
				{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<...>"}}
			]
		}
	],
	"stream": false,
	"max_tokens": 256
}
```

响应解析优先从 `choices[0].message.content` 读取描述文本；若没有，则会回退到 `description/generated_text/caption/text` 等常见字段。

后端在启动时会自动读取 `.env`。当调用 `/vlm` 时，后端会将上传的图片按 `VLM_API_MODE` 指定的方式（`multipart` 或 `base64`）转发给外部 API，并从响应中按 `VLM_API_DESC_KEY` 提取图片描述。
若启用了 `VLM_API_CHAT`，则走上面的 Chat Completions 适配逻辑。

## 常见问题

- iOS/Android 调试访问本机/局域网：
	- Android 模拟器请使用 `http://10.0.2.2:8000`
	- iOS 模拟器可用 `http://127.0.0.1:8000`
	- 真机需使用你电脑的局域网 IP（例如 `http://192.168.0.90:8000`），并确保同一网络下可访问

- iOS ATS/Android 明文 HTTP 限制：开发阶段如需 HTTP，可配置 ATS 例外或 Android 网络安全配置（生产环境建议使用 HTTPS）。


