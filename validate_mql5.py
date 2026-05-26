import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    encodings = ['utf-16', 'utf-8']
    content = None
    for enc in encodings:
        try:
            with open(filepath, 'r', encoding=enc) as f:
                content = f.read()
            break
        except Exception:
            continue

    if content is None:
        print("Error: Could not read file with utf-16 or utf-8.")
        return False

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer']
    mandatory_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']

    missing = []
    for h in mandatory_handlers + mandatory_functions:
        if h not in content:
            missing.append(h)

    if missing:
        print(f"Validation Failed: Missing mandatory components: {', '.join(missing)}")
        return False

    # Check for OO string methods like .Lower(), .Find(), etc.
    # Pattern looks for a dot followed by a word and then an open parenthesis.
    # Exclude common allowed ones if any, but MQL5 procedural doesn't use dots for strings.
    # Note: Objects like m_trade.Buy() ARE allowed.
    # We specifically want to target string-like OO calls if they were mistakenly used.
    # Actually, the memory says: "regex pattern r'\.\w+\(' to identify and block object-oriented string method calls"
    # But wait, MQL5 DOES use objects for Trade, PositionInfo, etc.
    # The memory specifically says "block object-oriented string method calls (e.g., .Lower())".
    # I should probably just check for .Lower(), .Upper(), .Find(), .Replace() etc on strings.

    forbidden_methods = [r'\.Lower\(', r'\.Upper\(', r'\.Find\(', r'\.Replace\(', r'\.Split\(']
    for pattern in forbidden_methods:
        if re.search(pattern, content, re.IGNORECASE):
            print(f"Validation Failed: Forbidden OO string method found matching {pattern}")
            return False

    print("Validation Successful: MT_LiveExecutor.mq5 is compliant.")
    return True

if __name__ == "__main__":
    path = "MQL5/Experts/MT_LiveExecutor.mq5"
    if not validate_mql5(path):
        sys.exit(1)
