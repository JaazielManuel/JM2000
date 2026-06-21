import re

def extrai_numero(txt, start):
    res = ""
    found = False
    for i in range(start, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.' or c == ',':
            if c == ',':
                res += "."
            else:
                res += c
            found = True
        elif found:
            break
    return float(res) if res else 0.0

def periodo_texto(nome):
    if "m15" in nome: return "PERIOD_M15"
    if "m1" in nome: return "PERIOD_M1"
    if "m5" in nome: return "PERIOD_M5"
    if "h1" in nome: return "PERIOD_H1"
    if "d1" in nome: return "PERIOD_D1"
    if "15 min" in nome: return "PERIOD_M15"
    return "PERIOD_CURRENT"

def interpreta_prompt(prompt):
    prompt = prompt.lower().replace('|', '.').replace('\n', '.')
    segments = prompt.split('.')

    config = {
        "risk": 1.0,
        "sl": 0.0,
        "tp": 0.0,
        "max_trades": 3,
        "breakeven": 0.0,
        "be_plus": 0.0,
        "trailing": 0.0,
        "start_hour": 0,
        "frequency": "PERIOD_M15",
        "rules": []
    }

    current_intent = 0 # 1: BUY, -1: SELL

    for seg in segments:
        seg = seg.strip()
        if not seg: continue

        if "compra" in seg: current_intent = 1
        if "venda" in seg or "vende" in seg: current_intent = -1

        if "risco" in seg: config["risk"] = extrai_numero(seg, seg.find("risco") + 5)
        if "stop de" in seg: config["sl"] = extrai_numero(seg, seg.find("stop de") + 7)
        if "take de" in seg: config["tp"] = extrai_numero(seg, seg.find("take de") + 7)
        if "máximo" in seg and "trades" in seg: config["max_trades"] = int(extrai_numero(seg, seg.find("máximo") + 6))

        if "move stop para entrada" in seg:
            # "Ao atingir +30 pontos, move stop para entrada +5 pontos"
            config["breakeven"] = extrai_numero(seg, seg.find("atingir") + 7)
            if "+" in seg[seg.find("entrada"):]:
                config["be_plus"] = extrai_numero(seg, seg.find("entrada") + 7)

        if "depois das" in seg: config["start_hour"] = int(extrai_numero(seg, seg.find("depois das") + 10))
        if "cada" in seg and "min" in seg: config["frequency"] = periodo_texto(seg)

        if current_intent != 0:
            if "média" in seg or "ema" in seg or "sma" in seg:
                idx = seg.find("média")
                if idx == -1: idx = seg.find("ema")
                if idx == -1: idx = seg.find("sma")
                period = extrai_numero(seg, idx + 5)
                config["rules"].append({"type": "MA", "intent": current_intent, "period": period, "tf": config["frequency"]})
            if "rsi" in seg:
                period = extrai_numero(seg, seg.find("rsi") + 3)
                val_idx = seg.find("acima")
                if val_idx == -1: val_idx = seg.find("abaixo")
                val = extrai_numero(seg, val_idx + 5)
                config["rules"].append({"type": "RSI", "intent": current_intent, "period": period, "value": val, "tf": config["frequency"]})

    return config

if __name__ == "__main__":
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

    result = interpreta_prompt(prompt)
    import json
    print(json.dumps(result, indent=2))
