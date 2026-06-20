import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        return f"Error reading file: {e}"

    issues = []

    # Check for mandatory handlers
    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for handler in mandatory_handlers:
        if handler not in content:
            issues.append(f"Missing mandatory handler: {handler}")

    # Prohibited object-oriented string methods
    # Common ones: .Lower(), .Substr(), .Replace(), .Trim(), .Split()
    # We should also allow some legitimate property access like .Buy, .Sell from CTrade
    prohibited_patterns = [
        r'\.\w+\(', # Any .MethodCall()
    ]

    # Allowed methods (case sensitive as per memory)
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'PositionClose',
        'Profit', 'Volume', 'Magic', 'ResultRetcode', 'ResultPrice',
        'SetExpertMagicNumber', 'Name', 'Reset', 'SelectByIndex', 'Symbol',
        'PriceOpen', 'StopLoss', 'TakeProfit', 'PositionType', 'Ticket',
        'PositionSelectByTicket', 'PositionGetDouble', 'PositionGetInteger',
        'PositionGetString', 'ResultDeal'
    ]

    # Find all method calls
    method_calls = re.findall(r'\.(\w+)\(', content)
    for call in method_calls:
        if call not in allowed_methods:
            # Check if it's a false positive like a struct member access followed by (
            # But in MQL5, calling a function via a pointer or member function uses ()
            issues.append(f"Potentially prohibited OO method call: .{call}()")

    if issues:
        return "\n".join(issues)
    return "Validation PASSED"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
    else:
        result = validate_mql5(sys.argv[1])
        print(result)
        if result != "Validation PASSED":
            sys.exit(1)
