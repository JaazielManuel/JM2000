import re

def extrai_numero(text, start_pos):
    res = ""
    started = False
    for i in range(start_pos, len(text)):
        c = text[i]
        if c.isdigit() or c == '.' or c == '+' or c == '-':
            res += c
            started = True
        elif started:
            break
    return float(res) if res else 0.0

def periodo_texto(nome):
    n = nome.lower()
    if "m15" in n or "15 min" in n: return "PERIOD_M15"
    if "m30" in n or "30 min" in n: return "PERIOD_M30"
    if "m1" in n or "1 min" in n: return "PERIOD_M1"
    if "m5" in n or "5 min" in n: return "PERIOD_M5"
    if "h4" in n or "4 horas" in n: return "PERIOD_H4"
    if "h1" in n or "1 hora" in n: return "PERIOD_H1"
    if "d1" in n or "diário" in n: return "PERIOD_D1"
    return "PERIOD_CURRENT"

def interpreta_prompt(prompt):
    prompt = prompt.lower()
    normalized = prompt.replace("|", ".").replace("\n", ".").replace(" e ", ".").replace(" + ", ".")
    segments = normalized.split('.')

    rules = []
    current_intent = "NONE"

    current_tf = periodo_texto(prompt)

    for seg in segments:
        seg = seg.strip()
        if not seg: continue

        if "compra" in seg: current_intent = "BUY"
        elif "vende" in seg: current_intent = "SELL"

        # MA
        if "média" in seg or "ma" in seg:
            pos = seg.find("média")
            if pos < 0: pos = seg.find("ma")
            p1 = extrai_numero(seg, pos + 5)
            if p1 <= 0: p1 = 20
            cross = "cruzar" in seg
            rules.append({"type": "MA_CROSS", "p1": p1, "intent": current_intent, "cross": cross, "tf": current_tf})

        # RSI
        if "rsi" in seg:
            pos = seg.find("rsi")
            p1 = extrai_numero(seg, pos + 3)
            if p1 <= 0: p1 = 14
            d1, d2 = 70.0, 30.0
            p_acima = seg.find("acima de")
            p_abaixo = seg.find("abaixo de")
            if p_acima >= 0: d1 = extrai_numero(seg, p_acima + 8)
            if p_abaixo >= 0: d2 = extrai_numero(seg, p_abaixo + 9)
            cross = any(x in seg for x in ["subir", "cair", "cruzar"])
            rules.append({"type": "RSI_THRESHOLD", "p1": p1, "d1": d1, "d2": d2, "intent": current_intent, "cross": cross, "tf": current_tf})

    # Params
    params = {}
    p_risco = prompt.find("risco de")
    if p_risco >= 0: params["risk"] = extrai_numero(prompt, p_risco + 8)

    p_stop = prompt.find("stop de")
    if p_stop >= 0: params["stop"] = extrai_numero(prompt, p_stop + 7)

    p_take = prompt.find("take de")
    if p_take >= 0: params["take"] = extrai_numero(prompt, p_take + 7)

    return rules, params

def test():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade."
    rules, params = interpreta_prompt(prompt)

    print(f"Prompt: {prompt}")
    print("Rules detected:")
    for r in rules:
        print(f"  - {r}")
    print(f"Params detected: {params}")

    assert any(r["type"] == "MA_CROSS" and r["p1"] == 20 for r in rules)
    assert any(r["type"] == "RSI_THRESHOLD" and r["p1"] == 14 and r["d1"] == 55 for r in rules)
    assert params["risk"] == 1.0
    assert params["stop"] == 30.0
    assert params["take"] == 50.0

    print("\nTest passed!")

if __name__ == "__main__":
    test()
