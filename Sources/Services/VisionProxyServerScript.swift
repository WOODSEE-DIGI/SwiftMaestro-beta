import Foundation

/// Embedded vision proxy server script.
///
/// The script is written to the SwiftMaestro app support directory so it can be
/// spawned as a subprocess by `VisionProxyService`. Keeping it embedded ensures
/// public users get the correct version without manually locating a file.
enum VisionProxyServerScript {

    /// Path where the script should be written.
    static var installedPath: String {
        SwiftMaestroPaths.appSupportDir
            .appendingPathComponent("vision_proxy_server.py")
            .path
    }

    /// Default model path for the vision proxy server.
    ///
    /// Qwen3-VL-8B-Instruct-4bit is a real vision model (~5.8 GB) appropriate for
    /// the SwiftMaestro target hardware (64 GB+ unified memory). It is a large
    /// step up from the tiny 0.5B FastVLM model and produces accurate captions.
    /// Resolved via `ModelCatalog.modelsRoot` so it respects the user's model-root override.
    static var defaultModelPath: String {
        (ModelCatalog.modelsRoot as NSString)
            .appendingPathComponent("mlx-community/Qwen3-VL-8B-Instruct-4bit")
    }

    /// Ensure the server script exists on disk and return its path.
    /// Always overwrites the file so updates are picked up after app upgrades.
    static func ensureInstalled() throws -> String {
        let path = installedPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = scriptContent
            .replacingOccurrences(of: "PLACEHOLDER_DEFAULT_MODEL_PATH", with: defaultModelPath)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return path
    }

    private     static let scriptContent = """
#!/usr/bin/env python3
# SwiftMaestro Vision Proxy Server
# Serves an MLX vision-language model via an OpenAI-style /v1/chat/completions endpoint.
# Supports both text-only and vision (image+text) requests.
#
# Usage:
#     python vision_proxy_server.py [--port 8765] [--model-path /path/to/mlx-vlm-model]

import argparse
import base64
import json
import io
import os
import time
import uuid
import warnings
from pathlib import Path

os.environ["TRANSFORMERS_VERBOSITY"] = "error"
warnings.filterwarnings("ignore", category=UserWarning)

from flask import Flask, request, jsonify, Response
from PIL import Image
from mlx_vlm import load, generate, stream_generate
from mlx_vlm.prompt_utils import apply_chat_template

app = Flask(__name__)
model = None
processor = None
MODEL_ID = "vision-proxy"


def load_model(model_path: str):
    global model, processor, MODEL_ID
    print(f"[VisionProxy] Loading model from {model_path}...", flush=True)
    model, processor = load(model_path)
    MODEL_ID = Path(model_path).name
    print(f"[VisionProxy] Model loaded: {MODEL_ID}", flush=True)


MAX_IMAGE_LONG_EDGE = 1280


def resize_image(image):
    # Resize image so its longest edge is at most MAX_IMAGE_LONG_EDGE pixels.
    if isinstance(image, str):
        image = Image.open(image).convert("RGB")
    if isinstance(image, Image.Image):
        w, h = image.size
        if max(w, h) > MAX_IMAGE_LONG_EDGE:
            scale = MAX_IMAGE_LONG_EDGE / max(w, h)
            new_size = (int(w * scale), int(h * scale))
            image = image.resize(new_size, Image.Resampling.LANCZOS)
    return image


def extract_image_from_message(content):
    # Extract image from OpenAI-format message content (list with image_url).
    if isinstance(content, str):
        return content, None

    text_parts = []
    image = None
    for part in content:
        if part.get("type") == "text":
            text_parts.append(part["text"])
        elif part.get("type") == "image_url":
            url = part["image_url"]["url"]
            if url.startswith("data:"):
                header, b64data = url.split(",", 1)
                image_bytes = base64.b64decode(b64data)
                image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
            elif url.startswith(("http://", "https://")):
                image = url
            elif Path(url).is_file():
                image = url
    if image is not None:
        image = resize_image(image)
    return " ".join(text_parts), image


@app.route("/v1/models", methods=["GET"])
def list_models():
    return jsonify({
        "object": "list",
        "data": [{
            "id": MODEL_ID,
            "object": "model",
            "created": int(time.time()),
            "owned_by": "mlx-community",
            "permission": [],
            "root": MODEL_ID,
            "parent": None,
        }]
    })


@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    data = request.json
    messages = data.get("messages", [])
    max_tokens = data.get("max_tokens", 256)
    temperature = data.get("temperature", 0.0)
    top_p = data.get("top_p", 1.0)
    stream = data.get("stream", False)

    image = None
    for msg in messages:
        if msg["role"] == "user":
            text, img = extract_image_from_message(msg["content"])
            if img is not None:
                image = img
                msg["content"] = text

    num_images = 1 if image is not None else 0
    prompt = apply_chat_template(processor, model.config, messages, num_images=num_images)

    request_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    created = int(time.time())

    if stream:
        def generate_stream():
            yield f"data: {json.dumps({'id': request_id, 'object': 'chat.completion.chunk', 'created': created, 'model': MODEL_ID, 'choices': [{'index': 0, 'delta': {'role': 'assistant'}, 'finish_reason': None}]})}\\n\\n"

            for response in stream_generate(
                model, processor, prompt,
                image=[image] if image else None,
                max_tokens=max_tokens,
                temp=temperature,
                top_p=top_p,
            ):
                chunk = {
                    "id": request_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": MODEL_ID,
                    "choices": [{
                        "index": 0,
                        "delta": {"content": getattr(response, "text", str(response))},
                        "finish_reason": None,
                    }]
                }
                yield f"data: {json.dumps(chunk)}\\n\\n"

            yield f"data: {json.dumps({'id': request_id, 'object': 'chat.completion.chunk', 'created': created, 'model': MODEL_ID, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})}\\n\\n"
            yield "data: [DONE]\\n\\n"

        return Response(generate_stream(), mimetype="text/event-stream")

    result = generate(
        model, processor, prompt,
        image=[image] if image else None,
        max_tokens=max_tokens,
        temp=temperature,
        top_p=top_p,
        verbose=False,
    )
    output_text = getattr(result, "text", str(result))

    return jsonify({
        "id": request_id,
        "object": "chat.completion",
        "created": created,
        "model": MODEL_ID,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": output_text},
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": -1,
            "completion_tokens": -1,
            "total_tokens": -1,
        }
    })


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": MODEL_ID})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SwiftMaestro vision proxy server")
    parser.add_argument("--port", type=int, default=8765, help="Port to serve on")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Host to bind to")
    parser.add_argument(
        "--model-path", type=str,
        default='PLACEHOLDER_DEFAULT_MODEL_PATH',
        help="Path to the converted MLX vision-language model"
    )
    args = parser.parse_args()

    load_model(args.model_path)

    print(f"[VisionProxy] Server starting on {args.host}:{args.port}", flush=True)
    print(f"[VisionProxy] Endpoints:", flush=True)
    print(f"  GET  /health", flush=True)
    print(f"  GET  /v1/models", flush=True)
    print(f"  POST  /v1/chat/completions", flush=True)
    app.run(host=args.host, port=args.port, threaded=True)
"""
}
