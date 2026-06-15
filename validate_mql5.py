import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except UnicodeError:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = [h for h in mandatory_handlers if h not in content]
    if missing:
        print(f"Error: Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Procedural standards: check for prohibited OO-style string methods
    # e.g., str.Lower(), str.Substr(), etc.
    # Allowed methods include those from MQL5 standard library or common names
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name',
        'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket'
    ]

    # Simple regex to find .MethodName() calls
    pattern = re.compile(r'\.\w+\s*\(')
    matches = pattern.findall(content)

    errors = []
    for match in matches:
        method = match[1:-1].strip()
        if method not in allowed_methods:
            # Check if it might be an MQL5 function that is NOT a method
            # In procedural MQL5, we use StringSubstr(s,...) instead of s.Substr(...)
            errors.append(f"Prohibited method call: .{method}()")

    if errors:
        for err in errors:
            print(f"Procedural Error: {err}")
        return False

    print("MQL5 Validation Passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
