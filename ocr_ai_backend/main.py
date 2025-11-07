"""
FastAPI backend providing two endpoints:

- POST /ocr: OCR via EasyOCR. Returns JSON { text, confidences, avg_confidence, languages, duration_ms }
- POST /vlm: Image captioning via Transformers (nlpconnect/vit-gpt2-image-captioning). Returns { description, duration_ms }

Both endpoints accept multipart/form-data with field "file" (image bytes). Optional fields:
- languages: comma-separated langs for OCR (default: "ch_sim,en").

Run locally:
  uv run uvicorn main:app --reload --port 8000
"""
from __future__ import annotations

import io
import json
import os
import base64
import time
from typing import List, Optional
import numpy as np

from dotenv import load_dotenv
from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.responses import JSONResponse
import httpx
import logging
import traceback

from PIL import Image

load_dotenv()
app = FastAPI(title="AI OCR Read Backend", version="0.1.0")

# logging: enable verbose VLM logs when VLM_DEBUG env var is truthy
logger = logging.getLogger("ocr_ai_backend")
if not logger.handlers:
    h = logging.StreamHandler()
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logger.addHandler(h)
vlm_debug = os.getenv("VLM_DEBUG", "0").lower() in ("1", "true", "yes")
logger.setLevel(logging.DEBUG if vlm_debug else logging.INFO)


# Lazy holders so cold-start happens on first call only
_easyocr_reader = None
_vlm_pipeline = None  # 保留符号但不再使用本地模型（改为在线 API）


def _load_easyocr(languages: List[str]):
    global _easyocr_reader
    if _easyocr_reader is None:
        try:
            import easyocr  # type: ignore
        except Exception as e:  # pragma: no cover
            raise HTTPException(status_code=503, detail=f"EasyOCR 未安装或加载失败: {e}")
        # EasyOCR reader can support multiple languages, but initializing with too many slows down.
        # We initialize with requested languages; if later calls change languages, we re-create the reader.
        _easyocr_reader = easyocr.Reader(languages, gpu=False)
    else:
        # If the current reader languages don't match, rebuild
        try:
            current_langs = getattr(_easyocr_reader, "lang_char", {}).keys()
            # lang_char is a dict of language->charset; fall back if not available
            current_langs = set(current_langs) if current_langs else set()
            if current_langs and set(languages) != set(current_langs):
                import easyocr  # type: ignore
                _reset_easyocr()
                _easyocr_reader = easyocr.Reader(languages, gpu=False)
        except Exception:
            pass
    return _easyocr_reader


def _reset_easyocr():
    global _easyocr_reader
    _easyocr_reader = None


def _get_vlm_config():
    url = os.getenv("VLM_API_URL")
    if not url:
        raise HTTPException(status_code=503, detail="未配置在线 VLM：请在 .env 中设置 VLM_API_URL")
    return {
        "url": url,
        "api_key": os.getenv("VLM_API_KEY"),
        "auth_header": os.getenv("VLM_API_AUTH_HEADER", "Authorization"),
        "key_prefix": os.getenv("VLM_API_KEY_PREFIX", "Bearer "),
        "mode": os.getenv("VLM_API_MODE", "multipart"),  # multipart | base64
        "image_field": os.getenv("VLM_API_IMAGE_FIELD", "file"),
        "desc_key": os.getenv("VLM_API_DESC_KEY", "description"),
        "model": os.getenv("VLM_API_MODEL"),
        "timeout": float(os.getenv("VLM_API_TIMEOUT", "30")),
        # 额外 JSON 字段（可选），逗号分隔的 key=value 对，例如: extra=1,lang=zh
        "extra_fields": os.getenv("VLM_API_EXTRA_FIELDS", ""),
        # Chat-completions 风格（如 SiliconFlow/OpenAI 兼容）
        "chat": os.getenv("VLM_API_CHAT", "0").lower() in ("1", "true", "yes"),
        "prompt": os.getenv("VLM_API_PROMPT", "Please describe the image concisely."),
        "max_tokens": int(os.getenv("VLM_API_MAX_TOKENS", "512")),
        "temperature": float(os.getenv("VLM_API_TEMPERATURE", "0.7")),
        "top_p": float(os.getenv("VLM_API_TOP_P", "0.7")),
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/ocr")
async def ocr_endpoint(
    file: UploadFile = File(...),
    languages: Optional[str] = Form("ch_sim,en"),
):
    started = time.perf_counter()
    try:
        content = await file.read()
        image = Image.open(io.BytesIO(content)).convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="无法读取图片文件")

    langs = [s.strip() for s in (languages or "ch_sim,en").split(",") if s.strip()]
    if not langs:
        langs = ["ch_sim", "en"]

    reader = _load_easyocr(langs)
    try:
        # EasyOCR expects a file path, bytes, or a numpy array (CV image). Convert PIL Image -> numpy array.
        img_np = np.array(image)
        # If image mode is RGB (PIL default), convert to BGR which EasyOCR/OpenCV often expects.
        if img_np.ndim == 3 and img_np.shape[2] == 3:
            img_np = img_np[:, :, ::-1]
        # result format: list of [bbox, text, confidence]
        results = reader.readtext(img_np)
    except Exception as e:  # pragma: no cover
        raise HTTPException(status_code=500, detail=f"OCR 失败: {e}")

    texts: List[str] = []
    confidences: List[float] = []
    for r in results:
        if isinstance(r, (list, tuple)) and len(r) >= 3:
            texts.append(str(r[1]))
            try:
                confidences.append(float(r[2]))
            except Exception:
                confidences.append(0.0)

    combined_text = "\n".join(texts)
    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0
    duration_ms = int((time.perf_counter() - started) * 1000)

    return JSONResponse(
        {
            "text": combined_text,
            "confidences": confidences,
            "avg_confidence": round(avg_conf, 4),
            "languages": langs,
            "duration_ms": duration_ms,
        }
    )


@app.post("/vlm")
async def vlm_endpoint(file: UploadFile = File(...)):
    """
    VLM endpoint: 调用远程 VLM API 识别图像内容
    接受 multipart/form-data 格式的图片文件
    """
    started = time.perf_counter()
    
    # 读取图片并转换为 base64
    try:
        content = await file.read()
        image = Image.open(io.BytesIO(content)).convert("RGB")
        
        # 优化图片大小以减少传输时间
        # 如果图片过大,等比例缩放到最大边不超过 1920px
        max_size = 1920
        if max(image.size) > max_size:
            ratio = max_size / max(image.size)
            new_size = tuple(int(dim * ratio) for dim in image.size)
            image = image.resize(new_size, Image.Resampling.LANCZOS)
            logger.debug(f"图片已缩放至: {new_size}")
        
        # 将图片转换为 base64 编码,使用 JPEG 格式以减小大小
        buffered = io.BytesIO()
        image.save(buffered, format="JPEG", quality=85, optimize=True)
        img_base64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
        img_data_uri = f"data:image/jpeg;base64,{img_base64}"
        
        img_size_kb = len(img_base64) / 1024
        logger.debug(f"图片 base64 大小: {img_size_kb:.2f} KB")
    except Exception as e:
        logger.error(f"无法读取图片文件: {e}")
        raise HTTPException(status_code=400, detail=f"无法读取图片文件: {e}")
    
    # 获取 VLM 配置
    config = _get_vlm_config()
    
    # 构建请求数据 - 使用 chat completions 格式
    headers = {
        "Content-Type": "application/json",
    }
    
    # 添加认证头
    if config["api_key"]:
        auth_header = config["auth_header"]
        key_prefix = config["key_prefix"]
        headers[auth_header] = f"{key_prefix}{config['api_key']}"
    
    # 构建消息内容 - 包含图片和提示词
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": {
                        "url": img_data_uri
                    }
                },
                {
                    "type": "text",
                    "text": config["prompt"]
                }
            ]
        }
    ]
    
    payload = {
        "model": config["model"],
        "messages": messages,
        "stream": False,
        "max_tokens": config["max_tokens"],
        "temperature": config["temperature"],
        "top_p": config["top_p"],
    }
    
    logger.debug(f"VLM 请求 URL: {config['url']}")
    logger.debug(f"VLM 请求模型: {config['model']}")
    logger.debug(f"VLM 请求提示词: {config['prompt']}")
    
    # 调用远程 API
    try:
        # 使用更长的超时时间,分别设置连接和读取超时
        timeout = httpx.Timeout(
            connect=10.0,  # 连接超时 10 秒
            read=config["timeout"],  # 读取超时使用配置值
            write=10.0,  # 写入超时 10 秒
            pool=5.0  # 连接池超时 5 秒
        )
        
        async with httpx.AsyncClient(timeout=timeout) as client:
            logger.debug(f"开始调用 VLM API (超时: {config['timeout']}s)...")
            response = await client.post(
                config["url"],
                headers=headers,
                json=payload
            )
            response.raise_for_status()
            result = response.json()
            
        logger.debug(f"VLM API 响应: {json.dumps(result, ensure_ascii=False, indent=2)}")
        
        # 从响应中提取描述文本
        # SiliconFlow/OpenAI 格式: choices[0].message.content
        description = ""
        if "choices" in result and len(result["choices"]) > 0:
            choice = result["choices"][0]
            if "message" in choice and "content" in choice["message"]:
                description = choice["message"]["content"]
        
        if not description:
            logger.warning(f"无法从响应中提取描述: {result}")
            description = str(result)
        
        duration_ms = int((time.perf_counter() - started) * 1000)
        
        return JSONResponse({
            "description": description,
            "duration_ms": duration_ms,
            "model": config["model"]
        })
        
    except httpx.TimeoutException as e:
        duration_ms = int((time.perf_counter() - started) * 1000)
        logger.error(f"VLM API 调用超时 ({duration_ms}ms): {e}")
        raise HTTPException(
            status_code=504,
            detail=f"VLM API 调用超时,请尝试增加 VLM_API_TIMEOUT 配置值 (当前: {config['timeout']}s)"
        )
    except httpx.HTTPStatusError as e:
        logger.error(f"VLM API 返回错误状态码: {e.response.status_code}")
        logger.error(f"响应内容: {e.response.text}")
        raise HTTPException(
            status_code=e.response.status_code,
            detail=f"VLM API 返回错误: {e.response.text}"
        )
    except httpx.HTTPError as e:
        logger.error(f"VLM API 调用失败: {e}")
        logger.error(traceback.format_exc())
        raise HTTPException(
            status_code=503,
            detail=f"VLM API 调用失败: {str(e)}"
        )
    except Exception as e:
        logger.error(f"VLM 处理失败: {e}")
        logger.error(traceback.format_exc())
        raise HTTPException(
            status_code=500,
            detail=f"VLM 处理失败: {str(e)}"
        )


def run():  # console script entrypoint
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)


if __name__ == "__main__":
    run()
