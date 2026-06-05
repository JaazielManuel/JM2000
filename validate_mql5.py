import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for prohibited OO string methods
    # We allow some specific methods like .Reset(), .Buy, .Sell etc from standard library or our own structs
    allowed_methods = [
        'Reset', 'Buy', 'Sell', 'PositionSelect', 'PositionModify',
        'Profit', 'Volume', 'Magic', 'ResultRetcode', 'Select', 'Close'
    ]

    # Simple regex to find .MethodCall()
    matches = re.findall(r'\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', content)
    for match in matches:
        if match not in allowed_methods:
            # Check if it looks like an OO string method
            if match in ['Lower', 'Upper', 'Trim', 'Replace', 'Find', 'Substr']:
                print(f"Prohibited OO method found: .{match}()")
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
