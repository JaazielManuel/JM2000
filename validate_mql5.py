import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except UnicodeError:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in mandatory_handlers if h not in content]

    if missing:
        print(f"Error: Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for object-oriented string methods (e.g., .Lower(), .Find())
    # Procedural MQL5 uses StringToLower(str), StringFind(str, sub), etc.
    oo_string_methods = re.findall(r'\.\w+\(', content)
    # We should exclude common class methods if any are allowed,
    # but the rule says "no object-oriented string methods".
    # Typically in MQL5, string is a primitive-like type and doesn't have methods.
    # CTrade or CPositionInfo might have methods, but the validation is specifically for string methods.

    illegal_patterns = [
        r'\.Lower\(', r'\.Upper\(', r'\.Find\(', r'\.Substr\(', r'\.Replace\(',
        r'\.Trim\(', r'\.Len\(', r'\.Split\('
    ]

    for pattern in illegal_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            print(f"Error: Found prohibited object-oriented string method: {pattern}")
            return False

    print("Validation successful!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if validate_mql5(sys.argv[1]):
        sys.exit(0)
    else:
        sys.exit(1)
