const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const K = {};
new Function("exports", src + ";Object.assign(exports,{parseJson,groupByDay});")(K);

const nasty = JSON.stringify([{
  title: "Match" + String.fromCharCode(27) + "[31m red" + String.fromCharCode(10) + "second line",
  url: "x".repeat(900),
  calendar: "sports_pl"
}]);
const out = K.parseJson(nasty, []);
console.log("title:", JSON.stringify(out[0].title));
console.log("url capped to:", out[0].url.length);
console.log("oversize:", JSON.stringify(K.parseJson("x".repeat(5 * 1024 * 1024), [])));
console.log("garbage:", JSON.stringify(K.parseJson("not json", [])));

const evs = [
  { date: "2026-09-01", endDate: "2026-09-02", time: "23:10", title: "STL" },
  { date: "2026-08-31", endDate: "2026-09-13", time: "", title: "US Open" }
];
const g = K.groupByDay(evs, "2026-08-31", "2026-09-03");
console.log("grouping:", Object.keys(g).sort().map(k => k + "=" + g[k].length).join(" "));
