import re

def extrai_numero(txt, start_pos=0):
    res = ""
    found = False
    for i in range(start_pos, len(txt)):
        c = txt[i]
        if c.isdigit() or c in ".,-+":
            if c == ',': c = '.'
            res += c
            found = True
        elif found:
            break
    return float(res) if res else 0.0

def test_parser(prompt):
    p = prompt.lower()
    p = p.replace(" e ", ".").replace(" e o ", ".").replace(" e a ", ".").replace("|", ".").replace("\n", ".")

    params = {}
    if "stop de " in p: params['stop'] = extrai_numero(p, p.find("stop de "))
    if "take de " in p: params['take'] = extrai_numero(p, p.find("take de "))
    if "risco de " in p: params['risk'] = extrai_numero(p, p.find("risco de "))

    segments = [s.strip() for s in p.split(".") if s.strip()]
    rules = []
    current_intent = None

    for seg in segments:
        if "compra" in seg: current_intent = "BUY"
        elif "venda" in seg: current_intent = "SELL"

        if current_intent:
            rule = {"intent": current_intent, "segment": seg}
            if "média" in seg:
                rule["type"] = "MA"
                rule["period"] = extrai_numero(seg, seg.find("média"))
            elif "rsi" in seg:
                rule["type"] = "RSI"
                # Handle parenthesized RSI(14)
                match = re.search(r'rsi\s*\((\d+)\)', seg)
                if match:
                    rule["period"] = float(match.group(1))
                else:
                    rule["period"] = extrai_numero(seg, seg.find("rsi"))

                if "acima" in seg or "subir" in seg: rule["op"] = ">"
                elif "abaixo" in seg or "cair" in seg: rule["op"] = "<"

                rule["level"] = extrai_numero(seg, seg.find("acima")) if "acima" in seg else extrai_numero(seg, seg.find("abaixo"))

            rules.append(rule)

    return params, rules

if __name__ == "__main__":
    prompt = "A cada 15 minutos, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade."
    params, rules = test_parser(prompt)
    print("Params:", params)
    for r in rules:
        print("Rule:", r)

    assert params['stop'] == 30.0
    assert params['take'] == 50.0
    assert params['risk'] == 1.0
    assert any(r['type'] == 'MA' and r['period'] == 20.0 for r in rules)
    assert any(r['type'] == 'RSI' and r['period'] == 14.0 and r['op'] == '>' and r['level'] == 55.0 for r in rules)
    print("Test passed!")
