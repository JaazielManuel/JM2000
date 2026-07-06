import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # Check mandatory handlers
    mandatory_handlers = [
        r'int\s+OnInit\s*\(',
        r'void\s+OnDeinit\s*\(',
        r'void\s+OnTick\s*\(',
        r'void\s+OnTimer\s*\(',
        r'void\s+InterpretaPrompt\s*\(',
        r'ENUM_SIGNAL\s+AvaliaTudo\s*\(',
        r'void\s+EnviaOrdem\s*\('
    ]

    for handler in mandatory_handlers:
        if not re.search(handler, content):
            errors.append(f"Missing mandatory handler: {handler}")

    # Check prohibited OO string methods
    prohibited_oo = [
        r'\.Lower\(',
        r'\.Substr\(',
        r'\.Trim\(',
        r'\.Replace\(',
        r'\.Split\('
    ]

    for prob in prohibited_oo:
        if re.search(prob, content):
            errors.append(f"Prohibited OO string method found: {prob}")

    # Check allowed library methods (optional, just to see if we are using them)
    # This is more of a whitelist check if we want to be strict.

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return False

    print("MQL5 Validation Passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
