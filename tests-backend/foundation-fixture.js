"use strict";
function matches(row, query) {
  return Object.entries(query).every(([key, value]) => typeof value === "function" ? value(row[key]) : row[key] === value);
}
function memoryDatabase() {
  let tables = new Map(), tail = Promise.resolve();
  function api(store) {
    return {
      collection(name) {
        const table = () => {
          const current = typeof store === "function" ? store() : store;
          if (!current.has(name)) current.set(name, new Map());
          return current.get(name);
        };
        const query = (filter = {}, order, count = Infinity) => ({
          where: value => query(value, order, count), orderBy: (key) => query(filter, key, count), limit: n => query(filter, order, n),
          async get() { return { data: [...table().values()].filter(row => matches(row, filter))
            .sort((a,b) => order ? (a[order] > b[order] ? 1 : a[order] < b[order] ? -1 : 0) : 0).slice(0, count).map(row => structuredClone(row)) }; },
          doc(id) { return {
            async get() { return { data: table().has(id) ? [structuredClone(table().get(id))] : [] }; },
            async set(row) { table().set(id, structuredClone({ ...row, _id: id })); return {}; },
            async update(patch) { if (!table().has(id)) throw new Error("NOT_FOUND"); table().set(id, { ...table().get(id), ...structuredClone(patch) }); return { updated: 1 }; },
          }; },
          async add(row) { if (table().has(row._id)) throw new Error("DUPLICATE"); table().set(row._id, structuredClone(row)); return {}; },
        });
        return query();
      },
    };
  }
  const condition = fn => Object.assign(fn, { and: other => condition(value => fn(value) && other(value)) });
  return {
    collection: name => api(() => tables).collection(name),
    command: { gt: x => condition(y => y > x), lte: x => condition(y => y <= x) },
    async runTransaction(callback) {
      const run = tail.then(async () => {
        const snapshot = structuredClone(tables);
        const result = await callback(api(snapshot));
        tables = snapshot; return result;
      });
      tail = run.catch(() => {}); return run;
    },
  };
}
module.exports = { memoryDatabase };
