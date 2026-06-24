import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        return False

    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"FAILED: Missing mandatory handlers: {missing}")
        return False

    # Check for procedural standards (no OO string methods like .Lower() or .Substr())
    # Allowed methods (Trade, Position, etc.)
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume', 'Magic',
        'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name', 'Reset'
    ]

    # Simple regex to find .Method() calls that are not in allowed_methods
    # Matches . followed by alphanumeric and ()
    method_calls = re.findall(r'\.([a-zA-Z0-9]+)\(', content)
    violations = []
    for m in method_calls:
        if m not in allowed_methods:
            violations.append(m)

    if violations:
        # Check if they are maybe local struct methods
        # For simplicity, we flag them if they look like string methods
        string_methods = ['Lower', 'Substr', 'Replace', 'Trim', 'Find', 'Split', 'Length']
        for v in violations:
            if v in string_methods:
                 print(f"FAILED: Procedural violation - Object-oriented string method used: .{v}()")
                 return False

    print("PASSED: MQL5 procedural standards and mandatory handlers verified.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
