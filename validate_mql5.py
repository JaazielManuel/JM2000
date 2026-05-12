import os
import re

def validate():
    filepath = 'MQL5/Experts/MT_LiveExecutor.mq5'
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r') as f:
        content = f.read()

    mandatory_handlers = [
        'OnInit',
        'OnTick',
        'OnTimer',
        'InterpretaPrompt',
        'AvaliaTudo',
        'EnviaOrdem'
    ]

    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Error: Missing mandatory handlers/functions: {', '.join(missing)}")
        return False

    # Check for forbidden object-oriented string methods
    forbidden = re.findall(r'\.\w+\(', content)
    # Filter out common legitimate ones if any, but in MQL5 procedural we mostly use functions
    # However, trade.Buy() etc are allowed as they are class methods.
    # The requirement specifically mentioned .Lower() which doesn't exist in MQL5 strings.

    if '.Lower(' in content:
        print("Error: Forbidden .Lower() method found. Use StringToLower() instead.")
        return False

    if '.Upper(' in content:
        print("Error: Forbidden .Upper() method found. Use StringToUpper() instead.")
        return False

    if '.Find(' in content:
        print("Error: Forbidden .Find() method found. Use StringFind() instead.")
        return False

    print("MQL5 Validation Passed!")
    return True

if __name__ == "__main__":
    if validate():
        exit(0)
    else:
        exit(1)
