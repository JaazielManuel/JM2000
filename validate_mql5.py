import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # Mandatory Handlers
    handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    for h in handlers:
        if f'void {h}' not in content and f'int {h}' not in content:
            errors.append(f"Missing mandatory handler: {h}")

    # Core Functions
    core_funcs = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for cf in core_funcs:
        if cf not in content:
            errors.append(f"Missing core function: {cf}")

    # Procedural Standards (No OO string methods like .Lower(), .Substr() on string objects)
    # In MQL5, these are StringToLower(str), StringSubstr(str, ...), etc.
    prohibited_oo = [r'\.\w+\(', ]
    # But we allow some known safe ones like trade.Buy, posInfo.Select, etc.
    allowed_methods = ['Buy', 'Sell', 'PositionSelect', 'PositionModify', 'SelectByIndex',
                       'Magic', 'Symbol', 'Ticket', 'PositionType', 'PriceOpen', 'Profit',
                       'ResultRetcode', 'SetExpertMagicNumber', 'Reset']

    matches = re.finditer(r'\.(\w+)\(', content)
    for m in matches:
        method = m.group(1)
        if method not in allowed_methods:
            errors.append(f"Prohibited OO-style method call: .{method}() at index {m.start()}")

    if errors:
        print("Validation FAILED:")
        for e in errors:
            print(f"- {e}")
        return False
    else:
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
