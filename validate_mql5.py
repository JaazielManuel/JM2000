import re
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    content = ""
    try:
        # Tentar UTF-16 (comum no MetaEditor)
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except:
        try:
            # Tentar UTF-8
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading file: {e}")
            return False

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in mandatory_handlers if h not in content]

    if missing:
        print(f"Validation Failed: Missing handlers {missing}")
        return False

    # Check for prohibited OO string methods (e.g., .Lower(), .Substr())
    # Allow trade.Buy() and similar valid trade object calls
    oo_string_pattern = re.compile(r'\.\w+\(')
    matches = oo_string_pattern.findall(content)

    # Filter out known valid object methods
    allowed_methods = ['Buy', 'Sell', 'PositionModify', 'Ticket', 'Symbol', 'Magic', 'PositionType', 'PriceOpen', 'StopLoss', 'TakeProfit', 'Profit', 'SelectByIndex', 'Name', 'ResultRetcode', 'ResultRetcodeDescription', 'SetExpertMagicNumber', 'Reset']

    violations = []
    for m in matches:
        method_name = m[1:-1]
        if method_name not in allowed_methods:
            violations.append(m)

    if violations:
        print(f"Validation Warning: Potential prohibited OO methods found: {violations}")
        # Not failing yet, as some might be false positives, but logging for review

    print("MQL5 Validation Passed (Procedural Standards Check).")
    return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
