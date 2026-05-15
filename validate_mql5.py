import sys
import re

def validate_mql5(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in mandatory_handlers if h not in content]

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for forbidden OO string methods
    # MQL5 strings are procedural, so work.Lower() is invalid.
    # We look for something like .Lower(, .Find(, .Substr( etc.
    forbidden_patterns = [
        r'\.\w+\(', # Any method call on an object
    ]

    # Exceptions that are allowed in MQL5 (e.g. trade.Buy, symbol.Name)
    # But for strings specifically, we should be careful.
    # The memory specifically mentions .Lower()

    found_oo = re.findall(r'\.\s*(Lower|Upper|Find|Substr|Replace|Len)\s*\(', content, re.IGNORECASE)
    if found_oo:
        print(f"Forbidden OO string methods found: {', '.join(set(found_oo))}")
        return False

    print("Validation successful.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)
    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
