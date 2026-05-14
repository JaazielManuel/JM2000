import os
import re

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in mandatory_handlers if h not in content]

    if missing:
        print(f"Validation Failed: Missing handlers {missing}")
        return False

    # Check for OO string methods (e.g., .Lower())
    forbidden_oo = re.findall(r'\.\w+\(', content)
    # Filter common non-string OO calls if necessary, but in MQL5 many are forbidden for strings
    # For simplicity, we flag all dot-calls and manually review or refine if needed.
    # However, trade.Buy() is valid as CTrade is an object.

    # Refined check for string OO specifically
    # MQL5 strings are NOT objects, so something like "string_var.Lower()" is invalid.
    # Let's look for common string methods used as OO.
    forbidden_strings = ['.Lower(', '.Upper(', '.Find(', '.Replace(', '.Substr(']
    found_forbidden = [f for f in forbidden_strings if f in content]

    if found_forbidden:
        print(f"Validation Failed: OO string methods found {found_forbidden}")
        return False

    print("Validation Passed: All mandatory handlers present and no OO string methods detected.")
    return True

if __name__ == "__main__":
    validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5')
