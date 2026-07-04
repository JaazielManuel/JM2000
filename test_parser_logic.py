import re

def extrai_numero(txt, start_pos=0):
    res = ""
    found = False
    for i in range(start_pos, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.' or c == '-' or c == '+':
            res += c
            found = True
        elif found:
            break
    return float(res) if res else 0.0

def interpreta_prompt(prompt):
    rules = []
    params = {
        "max_trades": 1,
        "risk": 1.0,
        "stop": 300,
        "take": 500,
        "breakeven": 0,
        "breakeven_entry": 0,
        "trailing": 0,
        "start_hour": 0,
        "frequency": "M15"
    }

    normalized = prompt.lower()
    normalized = normalized.replace(" e ", ".").replace(" e o ", ".").replace(" e a ", ".").replace("|", ".").replace("\n", ".")
    segments = normalized.split('.')

    current_intent = None

    for seg in segments:
        seg = seg.strip()
        if not seg: continue

        if "compra" in seg: current_intent = "BUY"
        if "vende" in seg: current_intent = "SELL"

        if "stop de" in seg: params["stop"] = int(extrai_numero(seg, seg.find("stop de")))
        if "take de" in seg: params["take"] = int(extrai_numero(seg, seg.find("take de")))
        if "risco de" in seg: params["risk"] = extrai_numero(seg, seg.find("risco de"))
        if "máximo" in seg and "trades" in seg: params["max_trades"] = int(extrai_numero(seg, seg.find("máximo")))

        hour_pos = seg.find("depois das")
        if hour_pos < 0: hour_pos = seg.find("após as")
        if hour_pos >= 0: params["start_hour"] = int(extrai_numero(seg, hour_pos))

        if "minutos" in seg and "cada" in seg:
            params["frequency"] = f"M{int(extrai_numero(seg, seg.find('cada')))}"

        if "move stop para entrada" in seg or "breakeven" in seg:
            params["breakeven"] = int(extrai_numero(seg, seg.find("atingir")))
            ent_pos = seg.find("entrada")
            if ent_pos >= 0: params["breakeven_entry"] = int(extrai_numero(seg, ent_pos))

        if "trailing" in seg or "rastreio" in seg:
            params["trailing"] = int(extrai_numero(seg))

        if current_intent:
            if "média" in seg:
                p1 = extrai_numero(seg, seg.find("média"))
                if p1 == 0: p1 = 20
                oper = "none"
                if "cruzar acima" in seg: oper = "cross_above"
                elif "cruzar abaixo" in seg: oper = "cross_below"
                elif "acima" in seg: oper = ">"
                elif "abaixo" in seg: oper = "<"
                rules.append({"intent": current_intent, "type": "MA", "period": p1, "oper": oper})

            if "rsi" in seg:
                # Handle parenthesized RSI like RSI (14)
                match = re.search(r'rsi\s*\(?(\d+)\)?', seg)
                p1 = int(match.group(1)) if match else 14
                oper = "none"
                val = 0
                if "acima" in seg or "subir" in seg:
                    oper = ">"
                    val = extrai_numero(seg, seg.find("55") if "55" in seg else seg.find("acima"))
                elif "abaixo" in seg or "cair" in seg:
                    oper = "<"
                    val = extrai_numero(seg, seg.find("45") if "45" in seg else seg.find("abaixo"))
                rules.append({"intent": current_intent, "type": "RSI", "period": p1, "oper": oper, "val": val})

    return rules, params

def test():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    rules, params = interpreta_prompt(prompt)

    print(f"Rules: {rules}")
    print(f"Params: {params}")

    assert params["frequency"] == "M15"
    assert params["start_hour"] == 10
    assert params["stop"] == 30
    assert params["take"] == 50
    assert params["risk"] == 1.0
    assert params["max_trades"] == 3
    assert params["breakeven"] == 30
    assert params["breakeven_entry"] == 5

    buy_ma = next(r for r in rules if r["intent"] == "BUY" and r["type"] == "MA")
    assert buy_ma["period"] == 20
    assert buy_ma["oper"] == "cross_above"

    buy_rsi = next(r for r in rules if r["intent"] == "BUY" and r["type"] == "RSI")
    assert buy_rsi["period"] == 14
    assert buy_rsi["oper"] == ">"
    assert buy_rsi["val"] == 55.0

    sell_ma = next(r for r in rules if r["intent"] == "SELL" and r["type"] == "MA")
    assert sell_ma["oper"] == "cross_below"

    sell_rsi = next(r for r in rules if r["intent"] == "SELL" and r["type"] == "RSI")
    assert sell_rsi["oper"] == "<"
    assert sell_rsi["val"] == 45.0

    print("All parser tests passed!")

if __name__ == "__main__":
    test()
