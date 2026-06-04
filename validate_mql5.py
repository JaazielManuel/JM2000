import re
import sys

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

    # Check for procedural standards: no .method() calls except allowed ones
    # Regex to find .something(
    pattern = re.compile(r'\.(\w+)\(')
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionGetDouble', 'PositionGetInteger',
        'PositionGetString', 'OrderSend', 'Reset', 'Select', 'Ticket',
        'Magic', 'ResultRetcode', 'SelectByIndex', 'Profit', 'PositionModify',
        'PriceCurrent', 'Volume', 'SetExpertMagicNumber', 'PositionType',
        'Symbol', 'TakeProfit', 'PriceOpen', 'StopLoss'
    ]

    matches = pattern.finditer(content)
    violations = []
    for match in matches:
        method_name = match.group(1)
        if method_name not in allowed_methods:
            # Check if it's a trade object method or something similar
            # For simplicity, if it's not in the allowed list, it's a violation
            violations.append(method_name)

    if violations:
        # Filter out some common false positives if necessary, but according to memory,
        # we strictly avoid OO string methods.
        print(f"Error: Prohibited object-oriented method calls found: {', '.join(set(violations))}")
        return False

    print("Validation successful: MT_LiveExecutor.mq5 adheres to procedural standards.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
