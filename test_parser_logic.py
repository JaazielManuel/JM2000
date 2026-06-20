import re

def extrai_numero(txt, start_pos):
    res = ""
    found = False
    cursor = start_pos
    for i in range(start_pos, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.':
            res += c
            found = True
        elif found:
            cursor = i
            break
    if not res: return 0.0, cursor
    return float(res), cursor

def periodo_texto(nome):
    nome = nome.lower()
    if "m15" in nome: return "PERIOD_M15"
    if "m1" in nome: return "PERIOD_M1"
    if "m5" in nome: return "PERIOD_M5"
    if "h1" in nome: return "PERIOD_H1"
    if "d1" in nome: return "PERIOD_D1"
    if "minutos" in nome or "min" in nome:
        val, _ = extrai_numero(nome, 0)
        if val == 1: return "PERIOD_M1"
        if val == 5: return "PERIOD_M5"
        if val == 15: return "PERIOD_M15"
    return "PERIOD_CURRENT"

def interpreta_prompt(prompt):
    prompt = prompt.lower()
    prompt = prompt.replace("|", ".").replace("\n", ".").replace(",", ".")

    segments = prompt.split('.')

    config = {
        "risk": 1.0,
        "sl": 300,
        "tp": 500,
        "max_trades": 3,
        "start_hour": 0,
        "news_veto": 20,
        "breakeven": 0,
        "trailing": 0,
        "rules": []
    }

    current_intent = 0 # 0: Global, 1: BUY, -1: SELL

    for seg in segments:
        seg = seg.strip()
        if not seg: continue

        # Global params
        if "risco" in seg: config["risk"], _ = extrai_numero(seg, seg.find("risco"))
        if "stop" in seg: config["sl"], _ = extrai_numero(seg, seg.find("stop"))
        if "take" in seg: config["tp"], _ = extrai_numero(seg, seg.find("take"))
        if "máximo" in seg or "max" in seg:
            pos = seg.find("máximo") if "máximo" in seg else seg.find("max")
            config["max_trades"], _ = extrai_numero(seg, pos)
        if "após as" in seg: config["start_hour"], _ = extrai_numero(seg, seg.find("após as"))
        if "notícias" in seg: config["news_veto"], _ = extrai_numero(seg, seg.find("notícias"))
        if "breakeven" in seg: config["breakeven"], _ = extrai_numero(seg, seg.find("breakeven"))
        if "trailing" in seg or "rastreio" in seg:
            pos = seg.find("trailing") if "trailing" in seg else seg.find("rastreio")
            config["trailing"], _ = extrai_numero(seg, pos)

        # Intent
        if "compra" in seg: current_intent = 1
        if "vende" in seg: current_intent = -1

        # Rules
        if current_intent != 0:
            if "média" in seg or "ma" in seg:
                pos = seg.find("média") if "média" in seg else seg.find("ma")
                p1, _ = extrai_numero(seg, pos)
                config["rules"].append({"type": "MA", "intent": current_intent, "p1": p1, "tf": periodo_texto(seg)})
            if "rsi" in seg:
                pos = seg.find("rsi") + 3
                p1, next_pos = extrai_numero(seg, pos)
                d1, _ = extrai_numero(seg, next_pos)
                config["rules"].append({"type": "RSI", "intent": current_intent, "p1": p1, "d1": d1, "tf": periodo_texto(seg)})

    return config

# Test
prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

config = interpreta_prompt(prompt)
print(f"Risk: {config['risk']}")
print(f"SL: {config['sl']}")
print(f"TP: {config['tp']}")
print(f"Max Trades: {config['max_trades']}")
print(f"Start Hour: {config['start_hour']}")
print(f"News Veto: {config['news_veto']}")
print(f"Rules Count: {len(config['rules'])}")
for r in config['rules']:
    print(f"Rule: {r}")
