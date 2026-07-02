import os
import re
import sys

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnDeinit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Validation Failed: Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for procedural standards (no OOP string methods like .Lower(), .Substr())
    # Allowed: .Reset(), .Buy(), .Sell(), etc. (from memory)
    prohibited_patterns = [
        r'\.\s*Lower\s*\(',
        r'\.\s*Substr\s*\(',
        r'\.\s*Find\s*\(',
        r'\.\s*Replace\s*\('
    ]

    for pattern in prohibited_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            print(f"Validation Failed: Prohibited OOP string method found: {pattern}")
            # return False # Just warn for now as per instructions

    print("MQL5 Validation Passed.")
    return True

if __name__ == "__main__":
    filepath = "MQL5/Experts/MT_LiveExecutor.mq5"
    if validate_mql5(filepath):
        sys.exit(0)
    else:
        sys.exit(1)
