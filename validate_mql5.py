import os
import re

def validate_mql5(filepath):
    print(f"Validating {filepath}...")

    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()

    # Mandatory handlers
    mandatory = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [m for m in mandatory if m not in content]

    if missing:
        print(f"Error: Missing mandatory handlers: {missing}")
        return False

    # Check for OO-string methods (e.g. .Lower(), .Find(), .Split())
    # Regex looks for .method_name(
    oo_methods = re.findall(r'\.\w+\(', content)
    forbidden_base = ['Lower', 'Find', 'Split', 'GetCharacter', 'Trim', 'Replace']

    found_forbidden = []
    for match in oo_methods:
        method = match[1:-1]
        if method in forbidden_base:
            found_forbidden.append(match)

    if found_forbidden:
        print(f"Error: Forbidden OO-style string methods found: {found_forbidden}")
        print("MQL5 requires procedural functions like StringToLower(), StringFind(), etc.")
        return False

    print("Validation successful!")
    return True

if __name__ == "__main__":
    if validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5'):
        exit(0)
    else:
        exit(1)
