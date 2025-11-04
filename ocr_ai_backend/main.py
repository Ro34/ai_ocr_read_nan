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
import os
import base64
import time
from typing import List, Optional
import numpy as np

from dotenv import load_dotenv
from fastapi import FastAPI, File, UploadFile, Form, HTTPException
from fastapi.responses import JSONResponse
import httpx

from PIL import Image

load_dotenv()
app = FastAPI(title="AI OCR Read Backend", version="0.1.0")


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
    started = time.perf_counter()
    try:
        content = await file.read()
        # 读取一次用于校验（也可省略）
        Image.open(io.BytesIO(content)).convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="无法读取图片文件")

    cfg = _get_vlm_config()
    headers = {}
    if cfg["api_key"]:
        headers[cfg["auth_header"]] = f"{cfg['key_prefix']}{cfg['api_key']}" if cfg["key_prefix"] else cfg["api_key"]

    timeout = httpx.Timeout(cfg["timeout"])
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            if cfg["mode"].lower() == "base64":
                b64 = base64.b64encode(content).decode("utf-8")
                payload = {cfg["image_field"]: b64}
                if cfg["model"]:
                    payload["model"] = cfg["model"]
                # 附加字段
                if cfg["extra_fields"]:
                    for kv in cfg["extra_fields"].split(","):
                        kv = kv.strip()
                        if not kv:
                            continue
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            payload[k.strip()] = v.strip()
                resp = await client.post(cfg["url"], json=payload, headers=headers)
            else:
                # multipart
                files = {
                    cfg["image_field"]: (file.filename or "image.jpg", content, file.content_type or "image/jpeg"),
                }
                data = {}
                if cfg["model"]:
                    data["model"] = cfg["model"]
                if cfg["extra_fields"]:
                    for kv in cfg["extra_fields"].split(","):
                        kv = kv.strip()
                        if not kv:
                            continue
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            data[k.strip()] = v.strip()
                resp = await client.post(cfg["url"], data=data, files=files, headers=headers)

        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"上游 VLM API 错误 {resp.status_code}: {resp.text[:200]}")
        try:
            body = resp.json()
        except Exception:
            raise HTTPException(status_code=502, detail=f"上游返回非 JSON：{resp.text[:200]}")

        desc = None
        # 优先使用配置的 key
        if isinstance(body, dict) and cfg["desc_key"] in body:
            desc = body.get(cfg["desc_key"])  # type: ignore
        # 常见兜底
        if not desc and isinstance(body, dict):
            for k in ("description", "generated_text", "caption", "text"):
                if k in body and isinstance(body[k], str):
                    desc = body[k]
                    break
        if not desc:
            # 无法解析时返回片段，便于调试
            raise HTTPException(status_code=502, detail=f"无法从上游响应中解析描述：{str(body)[:300]}")

        duration_ms = int((time.perf_counter() - started) * 1000)
        return JSONResponse({"description": str(desc), "duration_ms": duration_ms})
    except HTTPException:
        raise
    except Exception as e:  # pragma: no cover
        raise HTTPException(status_code=502, detail=f"调用上游 VLM 失败: {e}")


def run():  # console script entrypoint
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)


if __name__ == "__main__":
    run()
