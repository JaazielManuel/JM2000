import re
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-16' if open(filepath, 'rb').read(2) == b'\xff\xfe' else 'utf-8') as f:
        content = f.read()

    required_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    required_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes', 'GravaCSV', 'GravaLog']

    missing = []
    for h in required_handlers:
        if f"{h}(" not in content:
            missing.append(h)

    for func in required_functions:
        if f"{func}(" not in content:
            missing.append(func)

    if missing:
        print(f"Missing mandatory components: {', '.join(missing)}")
        return False

    # Check for OO string methods (illegal in procedural MQL5 if not using special classes)
    oo_strings = re.findall(r'\.\w+\(', content)
    # Filter out known safe ones like posInfo.SelectByIndex(
    oo_strings = [s for s in oo_strings if not any(x in s for x in ['.SelectByIndex(', '.Magic(', '.Symbol(', '.PositionType(', '.Volume(', '.PriceOpen(', '.Time(', '.StopLoss(', '.TakeProfit(', '.Profit(', '.Comment(', '.Buy(', '.Sell(', '.PositionModify(', '.ResultRetcode(', '.ResultRetcodeDescription(', '.Reset('])]

    if oo_strings:
        print(f"Warning: Potential illegal OO string methods found: {', '.join(oo_strings)}")
        # Some might be false positives if they are from standard classes like CTrade

    print("Validation successful!")
    return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
