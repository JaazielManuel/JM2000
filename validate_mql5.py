import sys
import re

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    required_handlers = [
        'OnInit', 'OnDeinit', 'OnTick', 'OnTimer', 'OnTradeTransaction',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in required_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Error: Missing handlers: {', '.join(missing)}")
        return False

    # Check for prohibited OOP string methods
    prohibited = ['.Lower()', '.Substr()', '.Upper()']
    for p in prohibited:
        if p in content:
            print(f"Error: Prohibited method {p} found.")
            return False

    # Check for EA_MAGIC
    if 'EA_MAGIC' not in content or '123456' not in content:
        print("Error: EA_MAGIC 123456 not found.")
        return False

    print("MQL5 Validation Passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
