import re
import os
import sys

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # Check for mandatory handlers
    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for handler in mandatory_handlers:
        if handler not in content:
            errors.append(f"Missing mandatory handler/function: {handler}")

    # Block object-oriented string methods (e.g., .Lower(), .Find())
    # Regex: dot followed by word characters and then opening parenthesis
    oo_string_methods = re.findall(r'\.\w+\(', content)
    # Filter out known safe objects if any, but the rule is strict against .method() on strings
    # In this script, CTrade (trade.), CPositionInfo (m_pos.), etc. are used.
    # We need to distinguish between string objects and other objects if possible,
    # but the memory says "block object-oriented string method calls (e.g., .Lower())"
    # and "ensuring the code remains strictly procedural".

    blocked_patterns = [r'\.Lower\(', r'\.Upper\(', r'\.Find\(', r'\.Replace\(', r'\.Split\(', r'\.Trim\(']
    for pattern in blocked_patterns:
        if re.search(pattern, content, re.IGNORECASE):
            errors.append(f"Forbidden OO string method found: {pattern}")

    if errors:
        print(f"Validation failed for {filepath}:")
        for err in errors:
            print(f" - {err}")
        return False

    print(f"Validation passed for {filepath}.")
    return True

if __name__ == "__main__":
    success = validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5')
    if not success:
        sys.exit(1)
