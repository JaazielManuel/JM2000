import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: File {filepath} not found.")
        return False

    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except UnicodeError:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit',
        'OnTick',
        'OnTimer',
        'InterpretaPrompt',
        'AvaliaTudo',
        'EnviaOrdem'
    ]

    missing_handlers = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing_handlers.append(handler)

    if missing_handlers:
        print(f"Missing mandatory handlers: {', '.join(missing_handlers)}")
    else:
        print("All mandatory handlers found.")

    # Check for object-oriented string methods (e.g., .Lower())
    oo_string_methods = re.findall(r'\.\w+\(', content)

    suspicious_oo = []
    for method in oo_string_methods:
        # Check if it's a known MQL5 class method vs a prohibited string OO call
        # StringToLower, StringFind, etc are procedural.
        # Prohibited: .Lower(), .Upper(), .Find(), .Split(), .Substring(), .Replace()
        if method.lower() in ['.lower(', '.upper(', '.find(', '.split(', '.substring(', '.replace(']:
            suspicious_oo.append(method)

    if suspicious_oo:
        print(f"Detected suspicious object-oriented method calls: {', '.join(suspicious_oo)}")
        print("MQL5 requires procedural functions for string manipulation (e.g., StringToLower(work)).")
    else:
        print("No prohibited object-oriented string methods detected.")

    return len(missing_handlers) == 0 and len(suspicious_oo) == 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <path_to_mq5>")
        sys.exit(1)

    success = validate_mql5(sys.argv[1])
    if not success:
        sys.exit(1)
    else:
        sys.exit(0)
