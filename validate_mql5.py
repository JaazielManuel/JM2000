import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_handlers = [h for h in mandatory_handlers if h not in content]

    if missing_handlers:
        print(f"Error: Missing mandatory handlers: {', '.join(missing_handlers)}")
        return False

    # Check for prohibited OO string methods (e.g., .Lower())
    # This regex looks for dot followed by word starting with uppercase and opening parenthesis
    oo_string_methods = re.findall(r'\.\w+\(', content)
    prohibited = []
    for method in oo_string_methods:
        # Allow standard library object methods like g_trade.Buy() or PositionGetInteger()
        if not any(x in method for x in ['.Buy(', '.Sell(', '.PositionModify(', '.PositionClose(', '.ResultRetcode(']):
             prohibited.append(method)

    if prohibited:
        print(f"Warning: Potential OO string methods or unusual object calls found: {', '.join(prohibited)}")
        # We'll be strict about .Lower(), .Find(), etc. if they appear
        for p in prohibited:
            if any(x in p.lower() for x in ['lower', 'upper', 'find', 'replace', 'split']):
                print(f"Error: Prohibited procedural violation: {p}")
                return False

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
