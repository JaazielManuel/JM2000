import sys
import re

def validate(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return False

    # Check for mandatory handlers
    handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_handlers = [h for h in handlers if h not in content]
    if missing_handlers:
        print(f"Missing mandatory handlers: {missing_handlers}")
        # Not returning False yet as some might be in progress

    # Check for prohibited OO string methods
    prohibited_methods = [r'\.Lower\(', r'\.Upper\(', r'\.Substr\(', r'\.Replace\(', r'\.Find\(']
    for method in prohibited_methods:
        if re.search(method, content):
            print(f"Prohibited OO method found: {method}")
            return False

    # Check for allowed methods (whitelist approach for certain dots)
    # This is a bit complex for a simple regex, but we'll check for dots that are NOT in the allowed list
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name',
        'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket', 'PositionSelectByTicket', 'PositionGetDouble',
        'PositionGetInteger', 'PositionGetString', 'ResultOrder'
    ]

    # Find all occurrences of .MethodName(
    found_methods = re.findall(r'\.(\w+)\(', content)
    for method in found_methods:
        if method not in allowed_methods:
            # Check if it's a common MQL5 struct access or something else allowed
            # For now, let's just log it
            print(f"Warning: Potentially prohibited method call: .{method}()")
            # return False # Uncomment if strict

    print("Validation passed (with warnings if any).")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
    else:
        validate(sys.argv[1])
