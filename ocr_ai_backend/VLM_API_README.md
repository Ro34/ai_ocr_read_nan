# VLM API 使用说明

## 端点: POST /vlm

### 功能
调用远程 VLM (视觉语言模型) API 来识别和描述图像内容。

### 请求格式
- **Method**: POST
- **Content-Type**: multipart/form-data
- **参数**:
  - `file` (必需): 图片文件

### 环境变量配置 (.env)

```env
# VLM API 配置
VLM_API_URL=https://api.siliconflow.cn/v1/chat/completions
VLM_API_KEY=your-api-key-here
VLM_API_MODEL=Qwen/Qwen3-VL-30B-A3B-Instruct
VLM_API_TIMEOUT=30
VLM_API_CHAT=1
VLM_API_PROMPT=用中文简洁描述这张图片的内容
VLM_API_MAX_TOKENS=256
VLM_API_TEMPERATURE=0.7
VLM_API_TOP_P=0.7
VLM_DEBUG=1
```

### 响应格式

```json
{
  "description": "图片描述内容",
  "duration_ms": 1234,
  "model": "Qwen/Qwen3-VL-30B-A3B-Instruct"
}
```

### 使用示例

#### 使用 curl
```bash
curl -X POST http://localhost:8000/vlm \
  -F "file=@img/1.png"
```

#### 使用 Python requests
```python
import requests

with open("img/1.png", "rb") as f:
    files = {"file": ("image.png", f, "image/png")}
    response = requests.post("http://localhost:8000/vlm", files=files)
    print(response.json())
```

#### 使用测试脚本
```bash
cd ocr_ai_backend
python test_vlm.py
```

### 技术实现细节

1. **图片处理**: 
   - 接收 multipart/form-data 格式的图片文件
   - 转换为 base64 编码格式
   - 构造 data URI (`data:image/png;base64,...`)

2. **API 调用**:
   - 使用 OpenAI/SiliconFlow 兼容的 chat completions 格式
   - 消息内容包含图片 URL 和文本提示词
   - 支持配置模型、温度、top_p 等参数

3. **响应处理**:
   - 从 `choices[0].message.content` 提取描述文本
   - 返回描述内容、处理耗时和使用的模型

### 错误处理

- **400**: 无法读取图片文件
- **503**: VLM API 未配置或调用失败
- **500**: 处理过程中出现异常

### 注意事项

1. 确保 `.env` 文件中配置了正确的 API URL 和 API Key
2. 图片会被转换为 base64 编码后发送,较大的图片可能需要更长的处理时间
3. 可以通过 `VLM_API_PROMPT` 自定义提示词来引导模型输出特定格式的描述
4. 设置 `VLM_DEBUG=1` 可以查看详细的请求和响应日志
