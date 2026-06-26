import re
import sys

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: File {filepath} not found.")
        return False

    mandatory_handlers = [
        'OnInit', 'OnDeinit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing_handlers = [h for h in mandatory_handlers if h not in content]
    if missing_handlers:
        print(f"Validation Failed: Missing handlers: {', '.join(missing_handlers)}")
        return False

    # Procedural string standards check: no .Lower(), .Substr(), etc.
    prohibited_methods = [r'\.Lower\(\)', r'\.Substr\(\)', r'\.Upper\(\)', r'\.Trim\(\)']
    for method in prohibited_methods:
        if re.search(method, content, re.IGNORECASE):
            print(f"Validation Failed: Prohibited OO string method found: {method}")
            return False

    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name',
        'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket', 'PositionSelectByTicket', 'PositionGetDouble',
        'PositionGetInteger', 'PositionGetString', 'ResultRetcodeDescription'
    ]

    # Just a sanity check that we are using some of these
    print("MQL5 Validation Passed: Mandatory handlers present and no prohibited OO string methods detected.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
    else:
        if validate_mql5(sys.argv[1]):
            sys.exit(0)
        else:
            sys.exit(1)
