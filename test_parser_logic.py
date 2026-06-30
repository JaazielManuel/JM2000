import re

def extrai_numero(text, keyword, start_pos=0):
    idx = text.find(keyword, start_pos)
    if idx == -1: return None

    # Look for the first number after the keyword
    match = re.search(r'[-+]?\d*\.?\d+', text[idx + len(keyword):])
    if match:
        return float(match.group())
    return None

def periodo_texto(nome):
    nome = nome.lower().strip()
    if "m15" in nome: return "PERIOD_M15"
    if "m1" in nome: return "PERIOD_M1"
    if "m5" in nome: return "PERIOD_M5"
    if "h1" in nome: return "PERIOD_H1"
    if "d1" in nome: return "PERIOD_D1"
    return "PERIOD_CURRENT"

class Rule:
    def __init__(self):
        self.active = False
        self.intent = 0 # 1 BUY, -1 SELL
        self.type = 0
        self.tf = "PERIOD_CURRENT"
        self.p1 = 0
        self.p2 = 0
        self.d1 = 0.0
        self.s1 = ""
        self.op = ""

def test_parser(prompt):
    rules = []
    # Normalize
    prompt = prompt.replace('|', '.').replace('\n', '.')
    segments = prompt.split('.')

    current_intent = 0

    for seg in segments:
        seg = seg.lower()
        if "compra" in seg: current_intent = 1
        if "vende" in seg: current_intent = -1

        if "média" in seg or "ma" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.type = 1 # MA
            r.p1 = int(extrai_numero(seg, "média") or extrai_numero(seg, "ma") or 20)
            if "cruzar acima" in seg or "acima" in seg: r.op = ">"
            if "cruzar abaixo" in seg or "abaixo" in seg: r.op = "<"
            rules.append(r)

        if "rsi" in seg:
            rsi_pos = seg.find("rsi")
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.type = 2 # RSI
            r.p1 = int(extrai_numero(seg, "rsi", rsi_pos) or 14)
            if "acima" in seg or "subir" in seg:
                r.op = ">"
                r.d1 = extrai_numero(seg, "acima", rsi_pos) or extrai_numero(seg, "subir", rsi_pos) or 70
            if "abaixo" in seg or "cair" in seg:
                r.op = "<"
                r.d1 = extrai_numero(seg, "abaixo", rsi_pos) or extrai_numero(seg, "cair", rsi_pos) or 30
            rules.append(r)

    return rules

if __name__ == "__main__":
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45."
    rules = test_parser(prompt)
    print(f"Parsed {len(rules)} rules.")
    for i, r in enumerate(rules):
        print(f"Rule {i}: Intent={r.intent}, Type={r.type}, P1={r.p1}, Op={r.op}, D1={r.d1}")

    # Basic assertions
    assert len(rules) >= 4
    assert rules[0].intent == 1 and rules[0].type == 1 and rules[0].p1 == 20
    assert rules[1].intent == 1 and rules[1].type == 2 and rules[1].d1 == 55
    assert rules[2].intent == -1 and rules[2].type == 1
    assert rules[3].intent == -1 and rules[3].type == 2 and rules[3].d1 == 45
    print("Test passed!")
