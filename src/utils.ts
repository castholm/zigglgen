export function compare<T extends string | number | bigint>(a: T, b: T): number {
  return a < b ? -1 : a > b ? 1 : 0
}
