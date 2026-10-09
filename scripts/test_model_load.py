import os
import sys
import time
import subprocess
from huggingface_hub import snapshot_download

MODEL_ID = "mlx-community/Qwen3.8-27B-4bit"
TEST_DIR = os.path.expanduser("~/Ai-models/test_qwen3_8")

def run_cmd(cmd):
    print(f"Running: {' '.join(cmd)}")
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        print(line, end="")
    process.wait()
    return process.returncode

def main():
    if not os.path.exists(TEST_DIR):
        os.makedirs(TEST_DIR)

    print(f"--- Phase 1: Downloading Metadata for {MODEL_ID} ---")
    # We only download metadata to check existence and size without pulling 15GB+ yet
    try:
        repo_info = snapshot_download(repo_id=MODEL_ID, allow_patterns=["*.json", "*.txt"], local_dir=TEST_DIR)
        print(f"Metadata downloaded to: {repo_info}")
    except Exception as e:
        print(f"Error downloading metadata: {e}")
        sys.exit(1)

    print("\n--- Phase 2: Testing MLX Inference (Dry Run/Small Load) ---")
    # We use mlx_lm.generate via CLI to see if the environment can even resolve the model structure
    # This is a 'dry run' attempt - it will try to load weights into memory.
    # If this fails with OOM or error, we know immediately.
    cmd = [
        "python3", "-m", "mlx_lm.generate",
        "--model", MODEL_ID,
        "--prompt", "Hello, who are you?",
        "--max-tokens", "10",
        "--temp", "0.0"
    ]
    
    start_time = time.time()
    result = run_cmd(cmd)
    end_time = time.time()

    if result == 0:
        print(f"\n✅ SUCCESS: Qwen 3.8 loaded and generated tokens in {end_time - start_time:.2f}s")
        sys.exit(0)
    else:
        print(f"\n❌ FAILED: Model failed to load or generate.")
        sys.exit(1)

if __name__ == '__main__':
    main()