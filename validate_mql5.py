import re
import os
import sys

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    content = ""
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except UnicodeError:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit',
        'OnTick',
        'OnTimer',
        'InterpretaPrompt',
        'AvaliaTudo',
        'EnviaOrdem'
    ]

    missing_handlers = [h for h in mandatory_handlers if h not in content]

    if missing_handlers:
        print(f"Missing mandatory handlers: {', '.join(missing_handlers)}")
        return False

    # Procedural standards check:
    # MQL5 string methods like .Lower(), .Upper(), .Find() are object-oriented and often discouraged in basic procedural MQL5
    # or not available in all contexts (like MQL4 compatibility).
    # We want to ensure functions like StringToLower(str), StringFind(str, sub) are used instead.

    # Common object-oriented string methods to check for
    oo_string_methods = ['Lower', 'Upper', 'Find', 'Replace', 'Substr', 'TrimLeft', 'TrimRight', 'Len']
    violations = []

    # We look for something like `str.Lower(`
    # But we need to exclude allowed objects like trade, posInfo, symInfo, etc.
    allowed_objects = ['trade', 'posInfo', 'symInfo', 'accInfo', 'pos', 'symbol', 'account']

    # Find all occurrences of `.method(`
    matches = re.finditer(r'(\w+)\.(\w+)\s*\(', content)
    for match in matches:
        obj = match.group(1)
        method = match.group(2)

        if method in oo_string_methods and obj not in allowed_objects:
            violations.append(f"{obj}.{method}()")

    if violations:
        print(f"Violations of procedural standards (object-oriented string methods used): {', '.join(set(violations))}")
        return False

    print("Validation successful: All mandatory handlers present and procedural standards maintained.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        target = "MQL5/Experts/MT_LiveExecutor.mq5"
    else:
        target = sys.argv[1]

    if validate_mql5(target):
        sys.exit(0)
    else:
        sys.exit(1)
