import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = [
        "OnInit", "OnDeinit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]

    missing_handlers = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing_handlers.append(handler)

    if missing_handlers:
        print(f"Missing mandatory handlers: {', '.join(missing_handlers)}")
        return False

    prohibited_methods = [r'\.Lower\(', r'\.Substr\(']
    for method in prohibited_methods:
        if re.search(method, content, re.IGNORECASE):
            print(f"Prohibited MQL5 method found: {method}")
            return False

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
