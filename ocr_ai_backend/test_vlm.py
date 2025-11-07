#!/usr/bin/env python3
"""测试 VLM API 端点"""
import requests

def test_vlm():
    url = "http://localhost:8000/vlm"
    
    # 使用测试图片
    with open("img/1.png", "rb") as f:
        files = {"file": ("1.png", f, "image/png")}
        
        print(f"正在调用 {url}...")
        response = requests.post(url, files=files)
        
        print(f"状态码: {response.status_code}")
        print(f"响应: {response.json()}")
        
        if response.status_code == 200:
            result = response.json()
            print(f"\n✅ 成功!")
            print(f"描述: {result.get('description')}")
            print(f"耗时: {result.get('duration_ms')}ms")
            print(f"模型: {result.get('model')}")
        else:
            print(f"\n❌ 失败: {response.text}")

if __name__ == "__main__":
    test_vlm()
