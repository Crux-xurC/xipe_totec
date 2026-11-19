// A sample for Scanner.JavaScript: add(1) in a comment is not a call
export function add(a, b) {
  return a + b
}

function hidden(x) {
  const s = "hidden() in a string"
  return add(x, 1)
}

export const twice = (x) => add(x, x);

const notFn = (1 + 2);

export default function main(n) {
  return twice(hidden(n))
}
