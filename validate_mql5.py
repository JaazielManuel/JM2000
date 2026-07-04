import sys
import os

def validate(filepath):
    if not os.path.exists(filepath):
        print(f"File {filepath} not found")
        return False

    with open(filepath, 'r') as f:
        content = f.read()

    mandatory_handlers = [
        "OnInit", "OnDeinit", "OnTick", "OnTimer",
        "InterpretaPrompt", "AvaliaTudo", "executaSignal"
    ]

    missing = [h for h in mandatory_handlers if h not in content]
    if missing:
        print(f"Missing mandatory handlers: {missing}")
        return False

    # Check for EA_MAGIC
    if "EA_MAGIC" not in content or "123456" not in content:
        print("EA_MAGIC 123456 not found")
        return False

    # Check for prohibited OO string methods (simple check)
    prohibited = [".Lower(", ".Substr(", ".Len(", ".Find("]
    for p in prohibited:
        if p in content:
            # We allowed .Lower() in memory but then validate_mql5.py blocks it?
            # Actually, MQL5 uses StringToLower(str).
            # Memory says: "blocks prohibited object-oriented string method calls (e.g., .Lower(), .Substr())"
            print(f"Prohibited OO string method found: {p}")
            return False

    # Check for approved library calls (just a few to be sure)
    approved = ["PositionSelectByTicket", "PositionGetDouble", "PositionGetInteger", "trade.Buy", "trade.Sell"]
    for a in approved:
        if a not in content:
            print(f"Mandatory approved call {a} not found")
            return False

    print("MQL5 validation passed!")
    return True

if __name__ == "__main__":
    if validate("MQL5/Experts/MT_LiveExecutor.mq5"):
        sys.exit(0)
    else:
        sys.exit(1)
