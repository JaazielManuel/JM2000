import sys
import re

def validate(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing_handlers = [h for h in mandatory_handlers if h not in content]
    if missing_handlers:
        print(f"Missing mandatory handlers: {', '.join(missing_handlers)}")
        return False

    # Prohibited OO-style string methods
    prohibited_patterns = [
        r'\.\s*Lower\s*\(',
        r'\.\s*Upper\s*\(',
        r'\.\s*Trim\s*\(',
        r'\.\s*Substr\s*\(',
        r'\.\s*Replace\s*\(',
        r'\.\s*Find\s*\('
    ]

    for pattern in prohibited_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            print(f"Detected prohibited OO-style string method: {pattern}")
            return False

    # Allowed methods check (whitelist approach for specific cases if needed)
    # The memory mentions allowed methods: Buy, Sell, PositionSelect, etc.
    # This script is mostly to catch common pitfalls mentioned in memories.

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)
    if validate(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
