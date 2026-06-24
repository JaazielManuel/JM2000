import re

def extrai_numero(txt, cursor):
    res = ""
    found = False
    start = cursor
    if start < 0: start = 0
    for i in range(start, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.' or c == ',':
            if c == ',': c = '.'
            res += c
            found = True
        elif found:
            return float(res), i
    if not found: return 0, len(txt)
    return float(res), len(txt)

def test_parser():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

    sl = prompt.lower()

    # Test global params extraction
    p_slPoints = 0
    p_tpPoints = 0
    p_risk = 0
    p_maxTrades = 0
    p_breakeven = 0
    p_breakevenPlus = 0

    if "stop de" in sl:
        cur = sl.find("stop de") + 7
        p_slPoints, _ = extrai_numero(sl, cur)

    if "take de" in sl:
        cur = sl.find("take de") + 7
        p_tpPoints, _ = extrai_numero(sl, cur)

    if "risco de" in sl:
        cur = sl.find("risco de") + 8
        p_risk, _ = extrai_numero(sl, cur)

    if "máximo" in sl:
        cur = sl.find("máximo") + 6
        p_maxTrades, _ = extrai_numero(sl, cur)

    if "move stop para entrada" in sl:
        curB = sl.find("atingir") + 7
        p_breakeven, _ = extrai_numero(sl, curB)
        curP = sl.find("entrada +") + 9
        p_breakevenPlus, _ = extrai_numero(sl, curP)

    print(f"SL Points: {p_slPoints}")
    print(f"TP Points: {p_tpPoints}")
    print(f"Risk: {p_risk}")
    print(f"Max Trades: {p_maxTrades}")
    print(f"Breakeven: {p_breakeven}")
    print(f"Breakeven Plus: {p_breakevenPlus}")

    assert p_slPoints == 30
    assert p_tpPoints == 50
    assert p_risk == 1
    assert p_maxTrades == 3
    assert p_breakeven == 30
    assert p_breakevenPlus == 5

if __name__ == "__main__":
    test_parser()
    print("Parser logic test PASSED")
