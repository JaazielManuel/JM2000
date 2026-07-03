import os
import sys

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = ["OnInit", "OnDeinit", "OnTick", "OnTimer", "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"]
    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Validation FAILED. Missing handlers: {', '.join(missing)}")
        return False

    # Check for restricted OO string methods
    restricted = [".Lower()", ".Substr()", ".Trim()"]
    for r in restricted:
        if r in content:
            print(f"Validation WARNING: Restricted OO method found: {r}")
            # In MQL5 we should use StringToLower, StringSubstr, etc.

    # Check for EA_MAGIC
    if "EA_MAGIC 123456" not in content:
        print("Validation WARNING: EA_MAGIC 123456 not found.")

    print("Validation SUCCESSFUL.")
    return True

if __name__ == "__main__":
    if len(sys.argv) > 1:
        validate_mql5(sys.argv[1])
    else:
        validate_mql5("MT_LiveExecutor.mq5")
