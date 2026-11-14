class Item:
    def __init__(self, qty, minimum):
        self.qty = qty
        self.min = minimum
        self.reserve = 0


def load():
    item = Item(2, 10)
    item.reserve = 8
    return item


def restock(item):
    shortfall = item.min - item.qty + item.reserve
    return shortfall


it = load()
s = restock(it)
log = []
log.append(s)
print(s)
