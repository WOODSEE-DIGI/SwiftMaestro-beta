import json
from huggingface_hub import HfApi

def probe_model(repo_id):
    print(f"--- Probing {repo_id} ---")
    api = HfApi()
    try:
        # Get repo info
        repo_info = api.repo_info(repo_id=repo_id)
        print(f"Repo Found: {repo_info.id}")
        print(f"Last Modified: {repo_info.last_modified}")

        # List files to check sizes and existence of safetensors
        files = api.list_repo_files(repo_id=repo_id)
        print("\nFile Listing:")
        for f in files[:10]: # Limit output for clarity
            print(f"- {f}")
        
        if len(files) < 10:
            print("... (truncated)")

        # Check if it looks like an MLX repo
        is_mlx = any("mlx-community" in repo_id or "MLX" in f for f in files)
        print(f"\nDetected MLX pattern: {is_mlx}")

    except Exception as e:
        print(f"Error probing repository: {e}")

if __name__ == "__main__":
    target = "mlx-community/Qwen3.8-27B-4bit"
    probe_model(target)
