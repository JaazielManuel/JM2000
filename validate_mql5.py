import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return False

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_handlers = [h for h in mandatory_handlers if h not in content]

    if missing_handlers:
        print(f"Missing mandatory handlers: {missing_handlers}")
        return False

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
    else:
        if validate_mql5(sys.argv[1]):
            sys.exit(0)
        else:
            sys.exit(1)
