import re
import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    content = ""
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = [
        "OnInit", "OnTick", "OnTimer", "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]

    missing = [h for h in mandatory_handlers if h not in content]
    if missing:
        print(f"Error: Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for object-oriented string methods (e.g., .Lower(), .Find())
    # but allow common trade object methods (trade.Buy, etc.)
    prohibited_oo = re.findall(r'\.(?:Lower|Upper|Find|Substr|Replace|Len)\(', content)
    if prohibited_oo:
        print(f"Error: Prohibited object-oriented string methods found: {', '.join(set(prohibited_oo))}")
        return False

    print("Validation successful: All mandatory handlers present and procedural standards met.")
    return True

if __name__ == "__main__":
    path = "MQL5/Experts/MT_LiveExecutor.mq5"
    if validate_mql5(path):
        sys.exit(0)
    else:
        sys.exit(1)
