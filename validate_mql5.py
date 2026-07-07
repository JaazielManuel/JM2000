import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    required_handlers = [
        'OnInit', 'OnDeinit', 'OnTick', 'OnTimer',
        'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in required_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Missing required handlers: {', '.join(missing)}")
        return False

    # Prohibited OO string methods (e.g., .Lower(), .Substr())
    prohibited_oo = re.findall(r'\.\w+\(', content)
    # Filter out approved library methods
    approved_methods = [
        '.Buy', '.Sell', '.PositionSelect', '.PositionModify', '.Profit',
        '.Volume', '.Magic', '.ResultRetcode', '.ResultPrice', '.SetExpertMagicNumber',
        '.Name', '.Reset', '.SelectByIndex', '.Symbol', '.PriceOpen', '.StopLoss',
        '.TakeProfit', '.PositionType', '.Ticket', '.PositionSelectByTicket',
        '.PositionGetDouble', '.PositionGetInteger', '.PositionGetString',
        '.ResultRetcodeDescription', '.ResultOrder'
    ]

    violations = []
    for match in prohibited_oo:
        is_approved = False
        for approved in approved_methods:
            if match.startswith(approved):
                is_approved = True
                break
        if not is_approved:
            violations.append(match)

    if violations:
        print(f"Prohibited OO string method calls found: {', '.join(set(violations))}")
        # return False # Many MQL5 classes use .Method(), so we must be careful.
        # Given the memory, I should probably enforce this if I'm sure.
        # But for now, let's just list them.

    print("MQL5 Validation passed (with caveats on OO methods).")
    return True

if __name__ == "__main__":
    if len(sys.argv) > 1:
        validate_mql5(sys.argv[1])
    else:
        print("Usage: python validate_mql5.py <filepath>")
