import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    content = ""
    try:
        with open(filepath, "r", encoding="utf-16-sig") as f:
            content = f.read()
    except Exception:
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading file: {e}")
            return False

    # 1. Check for mandatory handlers
    mandatory_handlers = [
        "OnInit", "OnTick", "OnTimer", "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]
    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # 2. Check for prohibited OO string methods
    # Regex: r'\.\w+\(' but allow trade and position management objects
    # Allowed objects: trade, pos, symbol, account, mql_tick, etc.
    # Actually, the memory says "blocks prohibited object-oriented string method calls (e.g., .Lower()) ... but is refined to allow ... (e.g., trade.Buy())"

    prohibited_pattern = re.compile(r'\.(\w+)\(')
    allowed_objects = ["trade", "pos", "symbol", "account", "arr", "rules", "f", "history"] # Heuristic
    # More specifically, we want to block things like .Lower(), .Upper(), .Find(), .Replace() on strings.
    # In MQL5, strings are NOT objects with methods.

    prohibited_methods = ["Lower", "Upper", "Find", "Replace", "Substr", "TrimLeft", "TrimRight", "Len"]

    lines = content.splitlines()
    for i, line in enumerate(lines):
        matches = prohibited_pattern.finditer(line)
        for match in matches:
            method_name = match.group(1)
            # Check if the prefix is an allowed object
            prefix_match = re.search(r'(\w+)\.' + method_name + r'\(', line)
            if prefix_match:
                obj_name = prefix_match.group(1)
                if method_name in prohibited_methods and obj_name not in allowed_objects:
                    print(f"Prohibited OO-style string method '{method_name}' found at line {i+1}: {line.strip()}")
                    return False

    print("Validation successful!")
    return True

if __name__ == "__main__":
    target = "MQL5/Experts/MT_LiveExecutor.mq5"
    if not validate_mql5(target):
        sys.exit(1)
    sys.exit(0)
