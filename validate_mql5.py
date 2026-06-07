import re
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # 1. Check for mandatory handlers
    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for handler in mandatory_handlers:
        if not re.search(fr'\b{handler}\s*\(', content):
            errors.append(f"Missing mandatory handler: {handler}")

    # 2. Check for prohibited OO string methods (procedural standard)
    # Common ones: .Lower(), .Upper(), .Substr(), .TrimLeft(), .TrimRight(), .Replace(), .Split()
    oo_methods = re.findall(r'\.\w+\(', content)
    allowed_methods = ['.Buy', '.Sell', '.PositionSelect', '.PositionModify', '.Profit', '.Volume', '.Magic', '.ResultRetcode', '.ResultPrice', '.SetExpertMagicNumber', '.Name', '.Reset']

    for method in oo_methods:
        if not any(method.startswith(allowed) for allowed in allowed_methods):
            errors.append(f"Potential OO string method found: {method}")

    # 3. Check for indicator handle validation
    if 'INVALID_HANDLE' not in content:
        errors.append("Indicator handles should be checked against INVALID_HANDLE")

    if errors:
        print(f"Validation failed for {filepath}:")
        for error in errors:
            print(f" - {error}")
        return False
    else:
        print(f"Validation passed for {filepath}!")
        return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
