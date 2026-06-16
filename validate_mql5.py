import re
import sys

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except Exception:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = [h for h in mandatory_handlers if h not in content]
    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume',
        'Magic', 'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name',
        'Reset', 'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit',
        'PositionType', 'Ticket', 'PositionClose'
    ]

    method_calls = re.findall(r'\.(\w+)\(', content)
    prohibited = [m for m in method_calls if m not in allowed_methods]

    if prohibited:
        print(f"Prohibited object-oriented methods found: {', '.join(set(prohibited))}")
        print("Please use static functions like StringSubstr, StringToLower, etc.")
        return False

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)
    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
