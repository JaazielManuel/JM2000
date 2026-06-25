import re

def extrai_numero(txt, cursor):
    s = ""
    found = False
    while cursor < len(txt):
        c = txt[cursor]
        if c.isdigit() or c == '.':
            s += c
            found = True
        elif found:
            break
        cursor += 1
    return float(s) if s else 0, cursor

def periodo_texto(nome):
    nome = nome.lower()
    if "m15" in nome: return "PERIOD_M15"
    if "m1" in nome: return "PERIOD_M1"
    if "m5" in nome: return "PERIOD_M5"
    if "h1" in nome: return "PERIOD_H1"
    if "minutos" in nome or "min" in nome:
        n, _ = extrai_numero(nome, 0)
        return f"PERIOD_M{int(n)}"
    return "PERIOD_CURRENT"

def test_parser():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

    segments = prompt.replace('|', '.').replace('\n', '.').split('.')

    results = {
        "p_risk": 0,
        "p_sl": 0,
        "p_tp": 0,
        "p_maxTrades": 0,
        "p_startHour": 0,
        "p_breakeven": 0,
        "p_breakevenStep": 0,
        "p_frequency": ""
    }

    for s in segments:
        s = s.lower()
        if "risco" in s:
            results["p_risk"], _ = extrai_numero(s, s.find("risco"))
        if "stop de" in s:
            results["p_sl"], _ = extrai_numero(s, s.find("stop de"))
        if "take de" in s:
            results["p_tp"], _ = extrai_numero(s, s.find("take de"))
        if "máximo" in s and "trades" in s:
            results["p_maxTrades"], _ = extrai_numero(s, s.find("máximo"))
        if "depois das" in s or "após as" in s:
            idx = s.find("depois das") if "depois das" in s else s.find("após as")
            results["p_startHour"], _ = extrai_numero(s, idx)
        if "move stop para entrada" in s or "breakeven" in s or "ao atingir" in s:
            if "ao atingir" in s:
                idx = s.find("ao atingir")
                results["p_breakeven"], _ = extrai_numero(s, idx)
                if "entrada" in s:
                    results["p_breakevenStep"], _ = extrai_numero(s, s.find("entrada"))
            else:
                idx = s.find("move stop para entrada") if "move stop para entrada" in s else s.find("breakeven")
                results["p_breakeven"], _ = extrai_numero(s, idx)
                if "+" in s:
                    results["p_breakevenStep"], _ = extrai_numero(s, s.find("+"))
        if "a cada" in s:
            results["p_frequency"] = periodo_texto(s)

    print(f"Parsed results: {results}")

    assert results["p_risk"] == 1.0
    assert results["p_sl"] == 30.0
    assert results["p_tp"] == 50.0
    assert results["p_maxTrades"] == 3
    assert results["p_startHour"] == 10
    assert results["p_breakeven"] == 30
    assert results["p_breakevenStep"] == 5
    assert results["p_frequency"] == "PERIOD_M15"

    print("Test passed!")

if __name__ == "__main__":
    test_parser()
