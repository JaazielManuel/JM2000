import sys
import os
import re

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    required_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    required_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes', 'AguardaNoticias', 'GravaLog']

    missing = []
    for handler in required_handlers:
        if handler not in content:
            missing.append(handler)

    for func in required_functions:
        if func not in content:
            missing.append(func)

    if missing:
        print(f"Missing mandatory components: {', '.join(missing)}")
        return False

    # Check for forbidden OO string methods
    oo_string_methods = ['.Lower(', '.Substr(', '.Upper(', '.Find(', '.Replace(', '.TrimLeft(', '.TrimRight(']
    allowed_methods = ['Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume', 'Magic',
                       'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name', 'Reset',
                       'SelectByIndex', 'Symbol', 'PriceOpen', 'StopLoss', 'TakeProfit', 'PositionType',
                       'Ticket', 'PositionSelectByTicket', 'PositionGetDouble', 'PositionGetInteger',
                       'PositionGetString', 'ResultRetcodeDescription']

    found_forbidden = []
    # Simple regex to find .Method()
    matches = re.findall(r'\.\w+\(', content)
    for match in matches:
        method_name = match[1:-1]
        if method_name not in allowed_methods:
            if match in oo_string_methods:
                found_forbidden.append(match)

    if found_forbidden:
        print(f"Error: Forbidden object-oriented methods found: {', '.join(set(found_forbidden))}")
        return False

    print(f"Validation successful for {filepath}")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    success = validate_mql5(sys.argv[1])
    sys.exit(0 if success else 1)
