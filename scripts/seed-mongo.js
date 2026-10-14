// Sample data for the MongoDB test server on 127.0.0.1:57017, written in MQL and run through Foxlume Query's own shell:
//
//   .build/debug/fqprobe --kind mongodb --port 57017 --ssl disable --db foxlume query "$(cat scripts/seed-mongo.js)"
//
// On a fresh server (auth on, no users) the unauthenticated session may only create the first user (the
// localhost exception), so root is created first and the session then authenticates as root. Later runs
// work with or without --user root --password root. Only the foxlume and analytics databases are touched.

var admin = db.getSiblingDB("admin");
try {
  admin.createUser({ user: "root", pwd: "root", roles: ["root"], mechanisms: ["SCRAM-SHA-256", "SCRAM-SHA-1"] });
  print("created user root");
} catch (e) {
  // 51003: root already exists. 13: users exist, so the localhost exception no longer applies.
  if (e.code !== 51003 && e.code !== 13) throw e;
}
admin.auth("root", "root");

use foxlume

try {
  db.dropUser("reader");
} catch (e) {
  if (e.code !== 11) throw e;
}
db.createUser({ user: "reader", pwd: "readerpass", roles: [{ role: "read", db: "foxlume" }], mechanisms: ["SCRAM-SHA-1"] });

["users", "orders", "types_demo", "order_summary", "fq_test_edit"].forEach(function (name) { db.getCollection(name).drop(); });

// users: a $jsonSchema validator declares phone, which no sample document has, so the sampled columns include it.
db.createCollection("users", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["name", "email"],
      properties: {
        name: { bsonType: "string" },
        email: { bsonType: "string" },
        phone: { bsonType: "string" },
        age: { bsonType: ["int", "null"] }
      }
    }
  },
  validationLevel: "moderate"
});

db.users.insertMany([
  { _id: 1, name: "Zoë Müller", email: "zoe.muller@example.com", age: 34, address: { street: "12 Baker Street", district: "Marylebone", city: "London" }, tags: ["vip", "early-adopter"], location: { type: "Point", coordinates: [-0.1585, 51.5237] }, createdAt: ISODate("2024-01-15T08:30:00Z") },
  { _id: 2, name: "Björn Larsen", email: "bjorn.larsen@example.com", age: 28, address: { street: "45 Karl Johans gate", district: "Sentrum", city: "Oslo" }, tags: ["newsletter"], location: { type: "Point", coordinates: [10.7387, 59.9133] }, createdAt: ISODate("2024-02-03T14:05:00Z") },
  { _id: 3, name: "Carlos Mendes", email: "carlos.mendes@example.com", age: 41, address: { street: "7 Rua Augusta", district: "Baixa", city: "Lisbon" }, tags: [], location: { type: "Point", coordinates: [-9.1393, 38.7101] }, createdAt: ISODate("2024-03-21T09:00:00.500Z") },
  { _id: 4, name: "Dana Kim", email: "dana.kim@example.com", age: null, address: { street: "3 Main Street", city: "Boston" }, tags: ["vip"], location: { type: "Point", coordinates: [-71.0589, 42.3601] }, createdAt: ISODate("2024-04-30T23:59:59Z") },
  { _id: 5, name: "Ethan Wright", email: "ethan.wright@example.com", address: { street: "90 Pike Street", district: "Downtown", city: "Seattle" }, tags: ["wholesale", "vip", "late-payer"], location: { type: "Point", coordinates: [-122.3405, 47.6097] }, createdAt: ISODate("2024-06-12T06:45:00Z") }
]);
db.users.createIndex({ email: 1 }, { unique: true });
db.users.createIndex({ name: "text" }, { default_language: "none" });
db.users.createIndex({ location: "2dsphere" });

// orders: 250 deterministic documents. Prices are in cents so the Decimal128 totals are exact.
var statuses = ["paid", "pending", "shipped", "cancelled", "refunded"];
var products = [
  { sku: "CF-001", name: "Iced latte", cents: 350 },
  { sku: "TR-002", name: "Peach iced tea", cents: 425 },
  { sku: "BM-003", name: "Grilled sandwich", cents: 299 },
  { sku: "PH-004", name: "Beef noodle soup", cents: 780 },
  { sku: "GC-005", name: "Spring rolls (6 pieces)", cents: 1299 },
  { sku: "BX-006", name: "Holiday gift box", cents: 2500 }
];
var orders = [];
for (var i = 0; i < 250; i++) {
  var items = [];
  var cents = 0;
  for (var j = 0; j < 1 + (i % 3); j++) {
    var product = products[(i + j * 2) % products.length];
    var qty = 1 + ((i + j) % 4);
    items.push({ sku: product.sku, name: product.name, qty: qty, price: NumberDecimal((product.cents / 100).toFixed(2)) });
    cents += qty * product.cents;
  }
  var order = {
    _id: ObjectId((0x65a00000 + i).toString(16) + "0000000000000000"),
    userId: 1 + (i % 5),
    status: statuses[(i * 7 + 3) % 5],
    total: NumberDecimal((cents / 100).toFixed(2)),
    items: items,
    createdAt: new Date(Date.UTC(2024, 0, 1) + i * 7 * 3600000)
  };
  if (order.status === "paid" || order.status === "shipped") order.paidAt = new Date(order.createdAt.getTime() + 30 * 60000);
  orders.push(order);
}
db.orders.insertMany(orders);
db.orders.createIndex({ status: 1, createdAt: -1 });
db.orders.createIndex({ userId: "hashed" });

// types_demo: one document per BSON type. Each has `value` plus a field named after its type, so the
// structure shows one typed column per BSON type; document 100 lacks nearly every field.
var typed = [
  ["double", 3.14159],
  ["string", "Grüße"],
  ["object", { a: 1, b: { c: "nested", d: NumberLong("5") } }],
  ["array", [1, "two", { three: 3 }]],
  ["binary", BinData(0, "AQIDBA==")],
  ["uuid", UUID("123e4567-e89b-42d3-a456-426614174000")],
  ["objectId", ObjectId("65a1b2c3d4e5f60718293a4b")],
  ["bool", true],
  ["date", ISODate("2024-05-01T09:30:00.250Z")],
  ["null", null],
  ["regex", /^m[uü]ller/i],
  ["javascript", Code("function () { return 1; }")],
  ["int32", NumberInt(42)],
  ["timestamp", Timestamp({ t: 1714555800, i: 7 })],
  ["int64", NumberLong("9007199254740993")],
  ["decimal128", NumberDecimal("1234567890.123456789")],
  ["minKey", MinKey()],
  ["maxKey", MaxKey()],
  ["nan", NaN],
  ["infinity", -Infinity],
  ["dbref", DBRef("users", 1)]
];
db.types_demo.insertMany(typed.map(function (t, i) {
  var doc = { _id: i + 1, type: t[0], value: t[1] };
  doc[t[0]] = t[1];
  return doc;
}));
db.types_demo.insertOne({ _id: 100, type: "sparse" });

db.createView("order_summary", "orders", [
  { $group: { _id: "$status", orders: { $sum: 1 }, revenue: { $sum: "$total" }, lastOrderAt: { $max: "$createdAt" } } },
  { $sort: { _id: 1 } }
]);

use analytics
db.events.drop();
db.events.insertMany([
  { event: "login", userId: 1, at: ISODate("2024-07-01T08:00:00Z"), device: { os: "iOS", version: "17.5" } },
  { event: "view", userId: 2, at: ISODate("2024-07-01T08:05:00Z"), path: "/san-pham/ca-phe" },
  { event: "purchase", userId: 1, at: ISODate("2024-07-01T08:07:30Z"), amount: NumberDecimal("12.75") },
  { event: "logout", userId: 1, at: ISODate("2024-07-01T08:30:00Z") }
]);

use foxlume
print("users=" + db.users.countDocuments() + " orders=" + db.orders.countDocuments() + " types_demo=" + db.types_demo.countDocuments() + " analytics.events=" + db.getSiblingDB("analytics").events.countDocuments())
