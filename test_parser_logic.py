import re

def extrai_numero(txt, cursor):
    num_str = ""
    found = False
    dot_found = False

    for i in range(cursor, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.' or c == ',':
            if c == ',': c = '.'
            if c == '.':
                if dot_found: break
                dot_found = True
            num_str += c
            found = True
        elif found:
            return float(num_str), i
        if i == len(txt) - 1:
            if found: return float(num_str), len(txt)
            return 0, len(txt)
    return 0, cursor

def test_parser(prompt):
    print(f"Testing prompt: {prompt}")

    # Global params
    risk = 0
    sl = 0
    tp = 0

    if "risco" in prompt.lower():
        idx = prompt.lower().find("risco")
        risk, _ = extrai_numero(prompt, idx)
        print(f"Risk: {risk}%")

    if "stop de" in prompt.lower():
        idx = prompt.lower().find("stop de")
        sl, _ = extrai_numero(prompt, idx)
        print(f"SL: {sl} points")

    if "take de" in prompt.lower():
        idx = prompt.lower().find("take de")
        tp, _ = extrai_numero(prompt, idx)
        print(f"TP: {tp} points")

    # Intent detection
    rules = []
    segments = re.split(r'[.|\n]', prompt)
    current_intent = None

    for seg in segments:
        seg = seg.lower()
        if "compra" in seg: current_intent = "BUY"
        elif "vende" in seg: current_intent = "SELL"

        if current_intent:
            if "média" in seg or "ema" in seg:
                rules.append({"intent": current_intent, "type": "MA"})
            if "rsi" in seg:
                rules.append({"intent": current_intent, "type": "RSI"})

    print(f"Rules found: {rules}")
    return rules

if __name__ == "__main__":
    p = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade."
    rules = test_parser(p)
    # Improved parser should find 2 indicators for BUY and 2 for SELL
    buy_rules = [r for r in rules if r['intent'] == 'BUY']
    sell_rules = [r for r in rules if r['intent'] == 'SELL']

    assert len(buy_rules) >= 2, f"Expected at least 2 BUY rules, found {len(buy_rules)}"
    assert len(sell_rules) >= 2, f"Expected at least 2 SELL rules, found {len(sell_rules)}"

    print("Test passed!")
