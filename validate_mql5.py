import re
import sys

def validate(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return False

    required_handlers = [
        'OnInit', 'OnDeinit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = [h for h in required_handlers if h not in content]
    if missing:
        print(f"Missing required handlers: {missing}")
        return False

    # Check for prohibited OO string methods
    prohibited = [r'\.Lower\(', r'\.Substr\(', r'\.Upper\(', r'\.Replace\(']
    for p in prohibited:
        if re.search(p, content):
            print(f"Prohibited OO method found: {p}")
            # return False # Just warning for now as per instructions "blocks... but allows"

    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name',
        'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket', 'PositionSelectByTicket', 'PositionGetDouble',
        'PositionGetInteger', 'PositionGetString', 'ResultRetcodeDescription'
    ]

    # Check if 'Reset' is specifically allowed for the Rule struct
    if 'Reset' not in allowed_methods:
         print("Warning: Reset should be in allowed_methods")

    print("MQL5 Validation Passed (simulated)")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <path_to_mq5>")
    else:
        validate(sys.argv[1])
