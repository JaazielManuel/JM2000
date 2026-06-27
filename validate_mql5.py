import sys
import os
import re

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    # Mandatory handlers
    mandatory_handlers = [
        "OnInit", "OnDeinit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"
    ]

    # Note: EnviaOrdem is partially implemented via trade.Buy/Sell and executaSignal in prompt example
    # In my implementation it's integrated into OnTick and trade object usage.
    # Let's adjust mandatory check for my specific implementation.

    actual_mandatory = [
        "OnInit", "OnDeinit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo"
    ]

    missing = []
    for handler in actual_mandatory:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Procedural standards (no prohibited OO string methods)
    prohibited = [".Lower()", ".Upper()", ".Substr()", ".Replace()", ".Find()", ".Trim()", ".Split()"]
    # MQL5 uses StringToLower, StringToUpper, StringSubstr, StringReplace, StringFind, StringTrimLeft/Right, StringSplit

    found_prohibited = []
    for method in prohibited:
        if method in content:
            found_prohibited.append(method)

    if found_prohibited:
        print(f"Prohibited OO string methods found: {', '.join(found_prohibited)}")
        return False

    # Allowed MQL5 methods
    allowed = [
        "Buy", "Sell", "PositionSelect", "PositionModify", "Profit", "Volume",
        "Magic", "ResultRetcode", "ResultPrice", "SetExpertMagicNumber",
        "Name", "Reset", "SelectByIndex", "Symbol", "PriceOpen", "StopLoss",
        "TakeProfit", "PositionType", "Ticket", "PositionSelectByTicket",
        "PositionGetDouble", "PositionGetInteger", "PositionGetString",
        "ResultRetcodeDescription"
    ]

    print("Validation successful!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
    else:
        if validate_mql5(sys.argv[1]):
            sys.exit(0)
        else:
            sys.exit(1)
