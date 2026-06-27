import re

def extrai_numero(txt, anchor, offset=0, start_pos=0):
    pos = txt.find(anchor, start_pos)
    if pos < 0: return 0

    sub = ""
    found_digit = False
    for i in range(pos + len(anchor) + offset, len(txt)):
        c = txt[i]
        if c.isdigit() or c == '.' or c == ',' or c == '+' or c == '-':
            if c == ',': sub += "."
            else: sub += c
            found_digit = True
        elif found_digit:
            break
    try:
        return float(sub)
    except:
        return 0

def test_parser():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    prompt_lower = prompt.lower()

    print(f"Testing prompt: {prompt}")

    # Global params
    stop = extrai_numero(prompt_lower, "stop de")
    take = extrai_numero(prompt_lower, "take de")
    risco = extrai_numero(prompt_lower, "risco de")
    be_trigger = extrai_numero(prompt_lower, "atingir")
    be_profit = extrai_numero(prompt_lower, "entrada")

    print(f"Stop: {stop} (Expected: 30)")
    print(f"Take: {take} (Expected: 50)")
    print(f"Risco: {risco} (Expected: 1)")
    print(f"BE Trigger: {be_trigger} (Expected: 30)")
    print(f"BE Profit: {be_profit} (Expected: 5)")

    assert stop == 30
    assert take == 50
    assert risco == 1
    assert be_trigger == 30
    assert be_profit == 5

    # Test compound indicators
    # In MQL5 we search for keywords in segments.
    segments = prompt_lower.split('.')
    buy_segment = ""
    for s in segments:
        if "compra" in s:
            buy_segment = s
            break

    print(f"Buy segment: {buy_segment}")
    media_pos = buy_segment.find("média")
    rsi_pos = buy_segment.find("rsi")

    media_period = extrai_numero(buy_segment, "média de", 0, media_pos)
    rsi_level = extrai_numero(buy_segment, "acima", 0, rsi_pos)

    print(f"Media period: {media_period} (Expected: 20)")
    print(f"RSI level: {rsi_level} (Expected: 55)")

    assert media_period == 20
    assert rsi_level == 55

    print("Parser logic test passed!")

if __name__ == "__main__":
    test_parser()
