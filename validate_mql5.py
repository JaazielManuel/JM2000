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
    except Exception:
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading {filepath}: {e}")
            return False

    # 1. Check for mandatory handlers
    mandatory_handlers = [
        "OnInit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]

    missing_handlers = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing_handlers.append(handler)

    if missing_handlers:
        print(f"Validation FAILED: Missing mandatory handlers: {', '.join(missing_handlers)}")
    else:
        print("Validation PASSED: All mandatory handlers found.")

    # 2. Check for object-oriented STRING methods (e.g., .Lower())
    # Regex pattern: r'\.\w+\('
    # In MQL5, string is a basic type but has some OO methods in newer versions.
    # We should distinguish between trade.Buy() and str.Lower().

    # Prohibited string methods (instance methods)
    prohibited_string_methods = [
        ".Lower(", ".Upper(", ".Trim(", ".Length(", ".Fill(",
        ".Find(", ".Replace(", ".Substr(", ".GetCharacter("
    ]

    found_prohibited = []
    for method in prohibited_string_methods:
        if method in content:
            found_prohibited.append(method)

    if found_prohibited:
        print(f"Validation FAILED: OO string method found: {', '.join(found_prohibited)}")
        return False
    else:
        print("Validation PASSED: No prohibited OO string methods found.")

    return not missing_handlers

if __name__ == "__main__":
    target = "MQL5/Experts/MT_LiveExecutor.mq5"
    if len(sys.argv) > 1:
        target = sys.argv[1]

    if validate_mql5(target):
        print("Overall validation: SUCCESS")
        sys.exit(0)
    else:
        print("Overall validation: FAILURE")
        sys.exit(1)
