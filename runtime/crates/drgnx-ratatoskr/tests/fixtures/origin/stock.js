class Item {
  constructor(qty, minimum) {
    this.qty = qty;
    this.min = minimum;
    this.reserve = 0;
  }
}

function load() {
  const item = new Item(2, 10);
  item.reserve = 8;
  return item;
}

function restock(item) {
  const shortfall = item.min - item.qty + item.reserve;
  return shortfall;
}

const it = load();
const s = restock(it);
console.log(s);
