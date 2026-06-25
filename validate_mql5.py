import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    # Required handlers
    required_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_handlers = [h for h in required_handlers if h not in content]

    if missing_handlers:
        print(f"Missing mandatory handlers: {missing_handlers}")
        return False

    # Forbidden object-oriented string methods
    forbidden_methods = [r'\.Lower\(', r'\.Substr\(', r'\.Upper\(', r'\.Replace\(', r'\.Find\(', r'\.Split\(']
    for pattern in forbidden_methods:
        if re.search(pattern, content):
            print(f"Forbidden procedural violation: {pattern}")
            return False

    # Allowed methods (whitelist)
    allowed_methods = ['Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume', 'Magic',
                       'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name', 'Reset',
                       'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
                       'PositionType', 'Ticket', 'PositionSelectByTicket', 'PositionGetDouble',
                       'PositionGetInteger', 'PositionGetString']

    # Check for unauthorized .method() calls not in whitelist
    all_methods = re.findall(r'\.(\w+)\(', content)
    unauthorized = [m for m in all_methods if m not in allowed_methods]
    if unauthorized:
        print(f"Potential unauthorized method calls: {unauthorized}")
        # Not returning False immediately, but logging for review

    print("Validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
    else:
        if not validate_mql5(sys.argv[1]):
            sys.exit(1)
