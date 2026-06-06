import re
import sys

def validate_mql5(filepath):
    print(f"Validating {filepath}...")
    content = ""

    # Try UTF-8 then UTF-16
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        try:
            with open(filepath, 'r', encoding='utf-16') as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading file: {e}")
            return False

    # 1. Check mandatory handlers
    mandatory_handlers = [
        "OnInit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]
    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"FAILED: Missing mandatory handlers: {', '.join(missing)}")
        return False
    else:
        print("PASSED: All mandatory handlers found.")

    # 2. Check for object-oriented string methods (Procedural Standards)
    # Regex to find .MethodName( or .MethodName
    # We want to block things like str.Lower(), str.Substr()
    # But allow things like trade.Buy(), rule.Reset(), pos.Profit()

    allowed_methods = [
        "Reset", "Buy", "Sell", "PositionSelect", "PositionModify",
        "Profit", "Volume", "Magic", "ResultRetcode", "ResultPrice",
        "SetExpertMagicNumber", "Name"
    ]

    # Find all instances of .Word(
    found_methods = re.findall(r'\.(\w+)\(', content)
    violations = []
    for m in found_methods:
        if m not in allowed_methods:
            violations.append(m)

    if violations:
        # Check if they are actually used on strings or other objects
        # To be safe and strict, we block any dot-method not in the allowed list
        # unless it's a known MQL5 property (which usually don't use parentheses)
        print(f"FAILED: Prohibited object-oriented methods found: {', '.join(set(violations))}")
        print("Use procedural functions like StringSubstr, StringToLower, etc. instead.")
        return False
    else:
        print("PASSED: Procedural standards check.")

    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    success = validate_mql5(sys.argv[1])
    if not success:
        sys.exit(1)
    sys.exit(0)
