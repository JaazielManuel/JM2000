import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: File {filepath} not found.")
        return False

    content = ""
    encodings = ['utf-16', 'utf-8', 'latin-1']
    for enc in encodings:
        try:
            with open(filepath, 'r', encoding=enc) as f:
                content = f.read()
            break
        except Exception:
            continue

    if not content:
        print(f"Error: Could not read {filepath} with any supported encoding.")
        return False

    # Mandatory handlers
    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in mandatory_handlers:
        if not re.search(rf'\b{handler}\b', content):
            missing.append(handler)

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Procedural string standards (no .Lower(), .Substr(), etc. on strings)
    # But allow some specific methods
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit',
        'Volume', 'Magic', 'ResultRetcode', 'ResultPrice',
        'SetExpertMagicNumber', 'Name', 'Reset', 'SelectByIndex',
        'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit', 'PositionType',
        'Ticket'
    ]

    # Find all .method() calls
    matches = re.findall(r'\.(\w+)\s*\(', content)
    for match in matches:
        if match not in allowed_methods:
            # Check if it's a known string method or just something not in our allowlist
            # For simplicity, we block all .method() calls NOT in the allowlist
            print(f"Procedural violation: Prohibited method call '.{match}()' found.")
            return False

    print("Validation passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
