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
    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]
    for handler in mandatory_handlers:
        if handler not in content:
            errors.append(f"Missing mandatory handler/function: {handler}")

    # 2. Procedural Standards - Prohibit OO String Methods
    # Look for .MethodName() where MethodName starts with an uppercase letter
    # but excluding allowed methods.

    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber',
        'Name', 'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen',
        'StopLoss', 'TakeProfit', 'PositionType', 'Ticket',
        'PositionSelectByTicket', 'PositionGetDouble', 'PositionGetInteger', 'PositionGetString'
    ]

    # Simple regex to find .Method() calls
    matches = re.findall(r'\.([A-Z][a-zA-Z0-9_]*)\(', content)
    for match in matches:
        if match not in allowed_methods:
            # Check if it's a string method commonly used in OO
            if match in ['Lower', 'Substr', 'Trim', 'Replace', 'Find', 'Len']:
                errors.append(f"Prohibited OO string method call found: .{match}()")

    if errors:
        for err in errors:
            print(f"Validation Error: {err}")
        return False

    print("Validation Passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
