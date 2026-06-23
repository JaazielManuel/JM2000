import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return False

    errors = []

    # 1. Mandatory Handlers
    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for handler in mandatory_handlers:
        if handler not in content:
            errors.append(f"Missing mandatory handler/function: {handler}")

    # 2. Procedural Standards (No OO string methods)
    # Match patterns like .Lower(), .Substr(), .Replace(), .Trim(), etc.
    prohibited_methods = [
        r'\.Lower\(', r'\.Substr\(', r'\.Replace\(', r'\.Trim\(',
        r'\.TrimLeft\(', r'\.TrimRight\(', r'\.Find\('
    ]

    # Exceptions (Approved library methods)
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume', 'Magic',
        'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name', 'Reset',
        'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket', 'PositionSelectByTicket', 'PositionGetDouble',
        'PositionGetInteger', 'PositionGetString'
    ]

    # Simple check for any .Method( that is not in allowed_methods
    found_methods = re.findall(r'\.([a-zA-Z0-9_]+)\(', content)
    for method in found_methods:
        if method not in allowed_methods:
            # Check if it's one of the prohibited string methods
            for prohibited in prohibited_methods:
                if re.search(prohibited, f".{method}("):
                    errors.append(f"Prohibited OO string method found: .{method}()")
                    break

    if errors:
        print("Validation FAILED:")
        for err in errors:
            print(f" - {err}")
        return False

    print("Validation PASSED.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
