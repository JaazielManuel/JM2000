import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"File {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer']
    mandatory_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']

    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    for func in mandatory_functions:
        if func not in content:
            missing.append(func)

    if missing:
        print(f"Missing mandatory components: {', '.join(missing)}")
        return False

    # Check for forbidden OO methods (simplified check)
    forbidden = ['.Lower()', '.Upper()', '.Find(', '.Scan(', '.Format(', '.Len()']
    found_forbidden = []
    for f_str in forbidden:
        if f_str in content:
            found_forbidden.append(f_str)

    if found_forbidden:
        print(f"Found forbidden OO-style string methods: {', '.join(found_forbidden)}")
        return False

    print("MQL5 Validation Passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
    else:
        if validate_mql5(sys.argv[1]):
            sys.exit(0)
        else:
            sys.exit(1)
